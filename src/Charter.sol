// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/hooks/base/BaseHook.sol";
import {CurrencySettler} from "@uniswap/hooks/utils/CurrencySettler.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/// @title Charter
/// @notice Liquidity managers lease depositor capital in one Uniswap v4 pool. Depositors are owed
/// the passive full-range return plus rent; managers bond, run their own ranges and keep or cover
/// the difference.
/// @dev Shares are pro-rata claims on a bundle: units of full-range liquidity plus idle tokens.
/// Deposits add a matching slice and withdrawals take one out, so share accounting never prices
/// anything and cannot be moved by pushing the pool price.
contract Charter is BaseHook, IUnlockCallback, ERC20 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    enum Action {
        Deposit,
        Withdraw
    }

    uint256 internal constant Q128 = 1 << 128;
    uint256 public constant DEAD_SHARES = 1000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Config {
        Currency currency0;
        Currency currency1;
        int24 tickSpacing;
        uint24 baseFee;
        uint16 clampSqrtBps;
    }

    Currency public immutable currency0;
    Currency public immutable currency1;
    int24 public immutable tickSpacing;
    uint24 public immutable baseFee;
    uint16 public immutable clampSqrtBps;
    int24 public immutable fullLower;
    int24 public immutable fullUpper;

    PoolKey internal _key;
    PoolId public poolId;
    bool public bound;

    uint64 public lastSwapBlock;
    uint160 public blockStartSqrt;

    uint128 public passiveLiquidity;
    uint256 public idle0;
    uint256 public idle1;

    error WrongPool();
    error AlreadyBound();
    error NotBound();
    error BadConfig();
    error ZeroShares();
    error Slippage();

    event Bound(PoolId indexed id, uint160 sqrtPriceX96);
    event Deposit(address indexed payer, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed owner, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);

    constructor(IPoolManager manager, Config memory cfg) BaseHook(manager) ERC20("Charter LP", "CHARTER-LP") {
        // native currency would need payable flows; not supported yet
        if (cfg.currency0.isAddressZero()) revert BadConfig();
        if (Currency.unwrap(cfg.currency0) >= Currency.unwrap(cfg.currency1)) revert BadConfig();
        if (cfg.baseFee > LPFeeLibrary.MAX_LP_FEE || cfg.clampSqrtBps == 0 || cfg.clampSqrtBps >= 10_000) {
            revert BadConfig();
        }
        currency0 = cfg.currency0;
        currency1 = cfg.currency1;
        tickSpacing = cfg.tickSpacing;
        baseFee = cfg.baseFee;
        clampSqrtBps = cfg.clampSqrtBps;
        fullLower = TickMath.minUsableTick(cfg.tickSpacing);
        fullUpper = TickMath.maxUsableTick(cfg.tickSpacing);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    // ------------------------------------------------------------------ deposits

    /// @notice Mint `shares` by adding the matching slice of the vault's bundle.
    function deposit(uint256 shares, uint256 max0, uint256 max1, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (!bound) revert NotBound();
        if (shares == 0) revert ZeroShares();
        (amount0, amount1) =
            abi.decode(poolManager.unlock(abi.encode(Action.Deposit, abi.encode(msg.sender, shares, to))), (uint256, uint256));
        if (amount0 > max0 || amount1 > max1) revert Slippage();
    }

    /// @notice Burn `shares` and receive the matching slice of the bundle.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroShares();
        (amount0, amount1) =
            abi.decode(poolManager.unlock(abi.encode(Action.Withdraw, abi.encode(msg.sender, shares, to))), (uint256, uint256));
        if (amount0 < min0 || amount1 < min1) revert Slippage();
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory args) = abi.decode(data, (Action, bytes));
        if (action == Action.Deposit) return _deposit(args);
        return _withdraw(args);
    }

    function _deposit(bytes memory args) internal returns (bytes memory) {
        (address payer, uint256 shares, address to) = abi.decode(args, (address, uint256, address));
        _collectPassive();

        uint256 supply = totalSupply();
        uint128 dl;
        uint256 extra0;
        uint256 extra1;
        if (supply == 0) {
            if (shares <= DEAD_SHARES) revert ZeroShares();
            dl = shares.toUint128();
        } else {
            dl = FullMath.mulDivRoundingUp(passiveLiquidity, shares, supply).toUint128();
            extra0 = FullMath.mulDivRoundingUp(idle0, shares, supply);
            extra1 = FullMath.mulDivRoundingUp(idle1, shares, supply);
        }

        (uint256 owe0, uint256 owe1) = _owed(_modifyPassive(int256(uint256(dl))));
        uint256 amount0 = owe0 + extra0;
        uint256 amount1 = owe1 + extra1;
        currency0.settle(poolManager, payer, amount0, false);
        currency1.settle(poolManager, payer, amount1, false);
        _toIdle(extra0, extra1);
        passiveLiquidity += dl;

        if (supply == 0) {
            _mint(DEAD, DEAD_SHARES);
            _mint(to, shares - DEAD_SHARES);
        } else {
            _mint(to, shares);
        }
        emit Deposit(payer, to, shares, amount0, amount1);
        return abi.encode(amount0, amount1);
    }

    function _withdraw(bytes memory args) internal returns (bytes memory) {
        (address owner, uint256 shares, address to) = abi.decode(args, (address, uint256, address));
        _collectPassive();

        uint256 supply = totalSupply();
        uint128 dl = FullMath.mulDiv(passiveLiquidity, shares, supply).toUint128();
        uint256 out0 = FullMath.mulDiv(idle0, shares, supply);
        uint256 out1 = FullMath.mulDiv(idle1, shares, supply);
        _burn(owner, shares);

        _fromIdle(out0, out1);
        if (dl > 0) {
            BalanceDelta d = _modifyPassive(-int256(uint256(dl)));
            out0 += uint128(d.amount0());
            out1 += uint128(d.amount1());
            passiveLiquidity -= dl;
        }
        currency0.take(poolManager, to, out0, false);
        currency1.take(poolManager, to, out1, false);
        emit Withdraw(owner, to, shares, out0, out1);
        return abi.encode(out0, out1);
    }

    // ------------------------------------------------------------------ views

    /// @notice What depositors collectively own right now: full-range liquidity units plus idle tokens,
    /// counting fees the passive position has earned but not yet collected.
    function bundle() public view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        (uint256 f0, uint256 f1) = _pendingPassiveFees();
        return (passiveLiquidity, idle0 + f0, idle1 + f1);
    }

    function previewDeposit(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = totalSupply();
        (uint128 l, uint256 b0, uint256 b1) = bundle();
        uint128 dl = supply == 0 ? shares.toUint128() : FullMath.mulDivRoundingUp(l, shares, supply).toUint128();
        (amount0, amount1) = _fullRangeAmounts(dl, true);
        if (supply != 0) {
            amount0 += FullMath.mulDivRoundingUp(b0, shares, supply);
            amount1 += FullMath.mulDivRoundingUp(b1, shares, supply);
        }
    }

    function previewWithdraw(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0);
        (uint128 l, uint256 b0, uint256 b1) = bundle();
        (amount0, amount1) = _fullRangeAmounts(FullMath.mulDiv(l, shares, supply).toUint128(), false);
        amount0 += FullMath.mulDiv(b0, shares, supply);
        amount1 += FullMath.mulDiv(b1, shares, supply);
    }

    // ------------------------------------------------------------------ position plumbing

    function _modifyPassive(int256 liquidityDelta) internal returns (BalanceDelta d) {
        (d,) = poolManager.modifyLiquidity(
            _key,
            ModifyLiquidityParams({tickLower: fullLower, tickUpper: fullUpper, liquidityDelta: liquidityDelta, salt: 0}),
            ""
        );
    }

    function _collectPassive() internal {
        if (passiveLiquidity == 0) return;
        BalanceDelta d = _modifyPassive(0);
        _toIdle(uint128(d.amount0()), uint128(d.amount1()));
    }

    function _toIdle(uint256 a0, uint256 a1) internal {
        if (a0 > 0) {
            poolManager.mint(address(this), currency0.toId(), a0);
            idle0 += a0;
        }
        if (a1 > 0) {
            poolManager.mint(address(this), currency1.toId(), a1);
            idle1 += a1;
        }
    }

    function _fromIdle(uint256 a0, uint256 a1) internal {
        if (a0 > 0) {
            idle0 -= a0;
            poolManager.burn(address(this), currency0.toId(), a0);
        }
        if (a1 > 0) {
            idle1 -= a1;
            poolManager.burn(address(this), currency1.toId(), a1);
        }
    }

    function _owed(BalanceDelta d) internal pure returns (uint256, uint256) {
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        return (a0 < 0 ? uint128(-a0) : 0, a1 < 0 ? uint128(-a1) : 0);
    }

    function _fullRangeAmounts(uint128 l, bool roundUp) internal view returns (uint256 a0, uint256 a1) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        a0 = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(fullUpper), l, roundUp);
        a1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(fullLower), sqrtP, l, roundUp);
    }

    function _pendingPassiveFees() internal view returns (uint256 f0, uint256 f1) {
        if (passiveLiquidity == 0) return (0, 0);
        (uint128 l, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(poolId, address(this), fullLower, fullUpper, bytes32(0));
        (uint256 g0, uint256 g1) = poolManager.getFeeGrowthInside(poolId, fullLower, fullUpper);
        unchecked {
            f0 = FullMath.mulDiv(g0 - last0, l, Q128);
            f1 = FullMath.mulDiv(g1 - last1, l, Q128);
        }
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4) {
        if (bound) revert AlreadyBound();
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(currency1) || key.tickSpacing != tickSpacing
                || !key.fee.isDynamicFee()
        ) revert WrongPool();
        _key = key;
        poolId = key.toId();
        bound = true;
        emit Bound(poolId, sqrtPriceX96);
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (lastSwapBlock != block.number) {
            (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
            lastSwapBlock = uint64(block.number);
            blockStartSqrt = sqrtP;
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        pure
        override
        returns (bytes4, int128)
    {
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Spot clamped to the block's opening price, so a price pushed inside the current
    /// block cannot move a settlement by more than the clamp.
    function settlementSqrtPrice() public view returns (uint160) {
        (uint160 spot,,,) = poolManager.getSlot0(poolId);
        if (lastSwapBlock != block.number) return spot;
        uint256 lo = uint256(blockStartSqrt) * (10_000 - clampSqrtBps) / 10_000;
        uint256 hi = uint256(blockStartSqrt) * (10_000 + clampSqrtBps) / 10_000;
        if (spot < lo) return uint160(lo);
        if (spot > hi) return uint160(hi);
        return spot;
    }
}
