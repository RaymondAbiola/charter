// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/hooks/base/BaseHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Book, Lease, Env} from "./types/CharterTypes.sol";
import {PassiveMath} from "./libraries/PassiveMath.sol";
import {Positions} from "./libraries/Positions.sol";
import {VaultLogic} from "./libraries/VaultLogic.sol";
import {LeaseLogic} from "./libraries/LeaseLogic.sol";
import {LeaseMath} from "./libraries/LeaseMath.sol";

/// @title Charter
/// @notice Liquidity managers lease depositor capital in one Uniswap v4 pool. Depositors are owed
/// the passive full-range return plus rent; managers bond, run their own ranges and keep or cover
/// the difference.
/// @dev Shares are pro-rata claims on a bundle: units of full-range liquidity plus idle tokens.
/// Heavy flows live in external libraries called by delegatecall, so the hook stays the owner of
/// every position and the caller the PoolManager sees.
contract Charter is BaseHook, IUnlockCallback, ERC20 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using ProtocolFeeLibrary for uint24;

    enum Action {
        Deposit,
        Withdraw,
        Open,
        Rebalance
    }

    struct Config {
        Currency currency0;
        Currency currency1;
        int24 tickSpacing;
        uint24 baseFee;
        uint16 clampSqrtBps;
        uint8 maxLeases;
        uint16 minBondBps;
    }

    uint256 internal constant Q128 = 1 << 128;
    uint256 public constant DEAD_SHARES = 1000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // transient snapshot taken in beforeSwap
    uint256 internal constant T_FG0 = uint256(keccak256("charter.fg0")) - 1;
    uint256 internal constant T_FG1 = uint256(keccak256("charter.fg1")) - 1;
    uint256 internal constant T_SQRT = uint256(keccak256("charter.sqrt")) - 1;

    Currency public immutable currency0;
    Currency public immutable currency1;
    int24 public immutable tickSpacing;
    uint24 public immutable baseFee;
    uint16 public immutable clampSqrtBps;
    uint8 public immutable maxLeases;
    uint16 public immutable minBondBps;
    int24 public immutable fullLower;
    int24 public immutable fullUpper;

    PoolKey internal _key;
    PoolId public poolId;
    bool public bound;

    uint64 public lastSwapBlock;
    uint160 public blockStartSqrt;

    Book internal _book;
    mapping(uint256 slot => Lease) internal _leases;

    error WrongPool();
    error AlreadyBound();
    error NotBound();
    error BadConfig();
    error ZeroShares();
    error Slippage();
    error LeasesActive();
    error BadSlot();
    error SlotTaken();
    error NotManager();
    error BadRange();
    error NotEnoughCapital();
    error BondTooSmall();

    event Bound(PoolId indexed id, uint160 sqrtPriceX96);
    event Deposit(address indexed payer, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed owner, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event LeaseOpened(
        uint256 indexed slot,
        address indexed manager,
        uint128 units,
        uint32 rentPips,
        uint256 bond,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );
    event Rebalanced(uint256 indexed slot, int24 tickLower, int24 tickUpper, uint128 liquidity);

    constructor(IPoolManager manager, Config memory cfg) BaseHook(manager) ERC20("Charter LP", "CHARTER-LP") {
        // native currency would need payable flows; not supported yet
        if (cfg.currency0.isAddressZero()) revert BadConfig();
        if (Currency.unwrap(cfg.currency0) >= Currency.unwrap(cfg.currency1)) revert BadConfig();
        if (cfg.baseFee > LPFeeLibrary.MAX_LP_FEE || cfg.clampSqrtBps == 0 || cfg.clampSqrtBps >= 10_000) {
            revert BadConfig();
        }
        if (cfg.maxLeases == 0 || cfg.maxLeases > 16 || cfg.minBondBps == 0 || cfg.minBondBps > 10_000) {
            revert BadConfig();
        }
        currency0 = cfg.currency0;
        currency1 = cfg.currency1;
        tickSpacing = cfg.tickSpacing;
        baseFee = cfg.baseFee;
        clampSqrtBps = cfg.clampSqrtBps;
        maxLeases = cfg.maxLeases;
        minBondBps = cfg.minBondBps;
        fullLower = TickMath.minUsableTick(cfg.tickSpacing);
        fullUpper = TickMath.maxUsableTick(cfg.tickSpacing);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    // ------------------------------------------------------------------ depositors

    /// @notice Mint `shares` by adding the matching slice of the vault's bundle.
    function deposit(uint256 shares, uint256 max0, uint256 max1, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (!bound) revert NotBound();
        if (shares == 0) revert ZeroShares();
        if (_book.leasedUnits != 0) revert LeasesActive();
        (amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Deposit, abi.encode(msg.sender, shares, to))), (uint256, uint256)
        );
        if (amount0 > max0 || amount1 > max1) revert Slippage();
    }

    /// @notice Burn `shares` and receive the matching slice of the bundle.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroShares();
        if (_book.leasedUnits != 0) revert LeasesActive();
        (amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Withdraw, abi.encode(msg.sender, shares, to))), (uint256, uint256)
        );
        if (amount0 < min0 || amount1 < min1) revert Slippage();
    }

    // ------------------------------------------------------------------ managers

    /// @notice Lease `units` of depositor liquidity into `slot` and run it in `[tickLower, tickUpper)`.
    /// @param rentPips annual rent as millionths of the leased value
    /// @param bond token1 posted as security, at least `minBondBps` of the leased value
    function openLease(uint256 slot, uint128 units, uint32 rentPips, uint256 bond, int24 tickLower, int24 tickUpper)
        external
    {
        if (!bound) revert NotBound();
        if (slot >= maxLeases) revert BadSlot();
        if (_leases[slot].manager != address(0)) revert SlotTaken();
        if (units == 0 || units > _book.passiveLiquidity) revert NotEnoughCapital();
        _checkRange(tickLower, tickUpper);
        if (bond < minBond(units)) revert BondTooSmall();
        LeaseLogic.OpenArgs memory a = LeaseLogic.OpenArgs({
            manager: msg.sender,
            slot: slot,
            units: units,
            rentPips: rentPips,
            bond: bond,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
        poolManager.unlock(abi.encode(Action.Open, abi.encode(a)));
    }

    function rebalance(uint256 slot, int24 tickLower, int24 tickUpper) external {
        if (_leases[slot].manager != msg.sender) revert NotManager();
        _checkRange(tickLower, tickUpper);
        poolManager.unlock(abi.encode(Action.Rebalance, abi.encode(slot, tickLower, tickUpper)));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory args) = abi.decode(data, (Action, bytes));
        if (action == Action.Deposit) return _deposit(args);
        if (action == Action.Withdraw) return _withdraw(args);
        if (action == Action.Open) return _open(args);
        return _rebalance(args);
    }

    function _deposit(bytes memory args) internal returns (bytes memory) {
        (address payer, uint256 shares, address to) = abi.decode(args, (address, uint256, address));
        uint256 supply = totalSupply();
        (uint256 amount0, uint256 amount1) = VaultLogic.deposit(_book, _env(), payer, shares, supply, DEAD_SHARES);
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
        uint256 supply = totalSupply();
        _burn(owner, shares);
        (uint256 out0, uint256 out1) = VaultLogic.withdraw(_book, _env(), to, shares, supply);
        emit Withdraw(owner, to, shares, out0, out1);
        return abi.encode(out0, out1);
    }

    function _open(bytes memory args) internal returns (bytes memory) {
        LeaseLogic.OpenArgs memory a = abi.decode(args, (LeaseLogic.OpenArgs));
        uint128 liq = LeaseLogic.open(_book, _leases[a.slot], _env(), a);
        emit LeaseOpened(a.slot, a.manager, a.units, a.rentPips, a.bond, a.tickLower, a.tickUpper, liq);
        return "";
    }

    function _rebalance(bytes memory args) internal returns (bytes memory) {
        (uint256 slot, int24 lo, int24 hi) = abi.decode(args, (uint256, int24, int24));
        uint128 liq = LeaseLogic.rebalance(_book, _leases[slot], _env(), slot, lo, hi);
        emit Rebalanced(slot, lo, hi, liq);
        return "";
    }

    function _checkRange(int24 lo, int24 hi) internal view {
        if (lo >= hi || lo < fullLower || hi > fullUpper || lo % tickSpacing != 0 || hi % tickSpacing != 0) {
            revert BadRange();
        }
    }

    function _env() internal view returns (Env memory) {
        return Env({pm: poolManager, key: _key, fullLower: fullLower, fullUpper: fullUpper});
    }

    // ------------------------------------------------------------------ views

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function passiveLiquidity() external view returns (uint128) {
        return _book.passiveLiquidity;
    }

    function leasedUnits() external view returns (uint128) {
        return _book.leasedUnits;
    }

    function idle0() external view returns (uint256) {
        return _book.idle0;
    }

    function idle1() external view returns (uint256) {
        return _book.idle1;
    }

    function totalHeld0() external view returns (uint256) {
        return _book.totalHeld0;
    }

    function totalHeld1() external view returns (uint256) {
        return _book.totalHeld1;
    }

    function totalBond() external view returns (uint256) {
        return _book.totalBond;
    }

    /// @notice Fees one unit of depositor liquidity would have earned at full range, Q128, wrapping
    /// like the pool's own fee growth. A lease owes the growth of these over its life.
    function passiveGrowth0X128() external view returns (uint256) {
        return _book.passiveGrowth0X128;
    }

    function passiveGrowth1X128() external view returns (uint256) {
        return _book.passiveGrowth1X128;
    }

    function lease(uint256 slot) external view returns (Lease memory) {
        return _leases[slot];
    }

    /// @notice A lease's books at the settlement price: what it owes depositors, what it holds,
    /// and the equity left once its bond is counted. Values are in token1.
    function leaseAccount(uint256 slot) public view returns (LeaseMath.Account memory a, uint256 bond, int256 equity) {
        Lease storage l = _leases[slot];
        if (l.manager == address(0)) return (a, 0, 0);
        a = LeaseMath.account(_book, l, _env(), slot, settlementSqrtPrice());
        bond = l.bond;
        equity = LeaseMath.equity(a, bond);
    }

    /// @notice What depositors collectively own right now: full-range liquidity units plus idle tokens,
    /// counting fees the passive position has earned but not yet collected.
    function bundle() public view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        (uint256 f0, uint256 f1) = _pendingPassiveFees();
        return (_book.passiveLiquidity, _book.idle0 + f0, _book.idle1 + f1);
    }

    function previewDeposit(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = totalSupply();
        (uint128 l, uint256 b0, uint256 b1) = bundle();
        uint128 dl = supply == 0 ? shares.toUint128() : FullMath.mulDivRoundingUp(l, shares, supply).toUint128();
        (amount0, amount1) = Positions.fullRangeAmounts(_env(), _spot(), dl, true);
        if (supply != 0) {
            amount0 += FullMath.mulDivRoundingUp(b0, shares, supply);
            amount1 += FullMath.mulDivRoundingUp(b1, shares, supply);
        }
    }

    function previewWithdraw(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0);
        (uint128 l, uint256 b0, uint256 b1) = bundle();
        (amount0, amount1) =
            Positions.fullRangeAmounts(_env(), _spot(), FullMath.mulDiv(l, shares, supply).toUint128(), false);
        amount0 += FullMath.mulDiv(b0, shares, supply);
        amount1 += FullMath.mulDiv(b1, shares, supply);
    }

    /// @notice Smallest bond for leasing `units`: `minBondBps` of their full-range value at the settlement price.
    function minBond(uint128 units) public view returns (uint256) {
        uint160 s = settlementSqrtPrice();
        (uint256 a0, uint256 a1) = Positions.fullRangeAmounts(_env(), s, units, true);
        return FullMath.mulDivRoundingUp(Positions.valueAt(a0, a1, s), minBondBps, 10_000);
    }

    /// @notice Spot clamped to the block's opening price, so a price pushed inside the current
    /// block cannot move a settlement by more than the clamp.
    function settlementSqrtPrice() public view returns (uint160) {
        uint160 spot = _spot();
        if (lastSwapBlock != block.number) return spot;
        uint256 lo = uint256(blockStartSqrt) * (10_000 - clampSqrtBps) / 10_000;
        uint256 hi = uint256(blockStartSqrt) * (10_000 + clampSqrtBps) / 10_000;
        if (spot < lo) return uint160(lo);
        if (spot > hi) return uint160(hi);
        return spot;
    }

    function _spot() internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = poolManager.getSlot0(poolId);
    }

    function _pendingPassiveFees() internal view returns (uint256 f0, uint256 f1) {
        if (_book.passiveLiquidity == 0) return (0, 0);
        (uint128 l, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(poolId, address(this), fullLower, fullUpper, bytes32(0));
        (uint256 g0, uint256 g1) = poolManager.getFeeGrowthInside(poolId, fullLower, fullUpper);
        unchecked {
            f0 = FullMath.mulDiv(g0 - last0, l, Q128);
            f1 = FullMath.mulDiv(g1 - last1, l, Q128);
        }
    }

    // ------------------------------------------------------------------ hook callbacks

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
        uint160 sqrtP = _spot();
        if (lastSwapBlock != block.number) {
            lastSwapBlock = uint64(block.number);
            blockStartSqrt = sqrtP;
        }
        if (_book.passiveLiquidity + _book.leasedUnits != 0) {
            (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthGlobals(poolId);
            uint256 t0 = T_FG0;
            uint256 t1 = T_FG1;
            uint256 ts = T_SQRT;
            assembly ("memory-safe") {
                tstore(t0, fg0)
                tstore(t1, fg1)
                tstore(ts, sqrtP)
            }
        }
        return
            (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (_book.passiveLiquidity + _book.leasedUnits != 0) _accruePassive(params.zeroForOne, delta);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _accruePassive(bool zeroForOne, BalanceDelta delta) internal {
        uint256 fgBefore;
        uint256 sqrtBefore;
        uint256 slot = zeroForOne ? T_FG0 : T_FG1;
        uint256 ts = T_SQRT;
        assembly ("memory-safe") {
            fgBefore := tload(slot)
            sqrtBefore := tload(ts)
        }
        (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthGlobals(poolId);
        uint256 dfg;
        unchecked {
            dfg = (zeroForOne ? fg0 : fg1) - fgBefore;
        }
        if (dfg == 0) return;

        uint128 passive = _book.passiveLiquidity;
        uint128 leased = _book.leasedUnits;
        uint256 g;
        if (leased == 0) {
            // with nothing leased the counterfactual is what actually happened
            g = dfg;
        } else {
            int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
            if (paid >= 0) return;
            (uint160 sqrtAfter,, uint24 protocolFee,) = poolManager.getSlot0(poolId);
            uint16 pf = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
            uint256 fee = PassiveMath.lpFee(uint128(-paid), baseFee, pf);
            g = PassiveMath.growth(
                fee, dfg, _managedInRange(uint160(sqrtBefore), sqrtAfter), passive, uint256(passive) + leased
            );
        }
        unchecked {
            if (zeroForOne) _book.passiveGrowth0X128 += g;
            else _book.passiveGrowth1X128 += g;
        }
    }

    /// @dev Sum over leases of their liquidity weighted by how much of the swap's path fell in range.
    function _managedInRange(uint160 sqrtBefore, uint160 sqrtAfter) internal view returns (uint256 managed) {
        for (uint256 slot; slot < maxLeases; ++slot) {
            Lease storage l = _leases[slot];
            uint128 liq = l.liquidity;
            if (liq == 0) continue;
            uint256 f = PassiveMath.overlap(
                sqrtBefore,
                sqrtAfter,
                TickMath.getSqrtPriceAtTick(l.tickLower),
                TickMath.getSqrtPriceAtTick(l.tickUpper)
            );
            managed += uint256(liq) * f / 1e18;
        }
    }
}
