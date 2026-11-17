// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/hooks/base/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

/// @title Charter
/// @notice Liquidity managers lease depositor capital in one Uniswap v4 pool. Depositors are owed
/// the passive full-range return plus rent; managers bond, run their own ranges and keep or cover
/// the difference.
contract Charter is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

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

    error WrongPool();
    error AlreadyBound();
    error NotBound();
    error BadConfig();

    event Bound(PoolId indexed id, uint160 sqrtPriceX96);

    constructor(IPoolManager manager, Config memory cfg) BaseHook(manager) {
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

    function unlockCallback(bytes calldata) external view onlyPoolManager returns (bytes memory) {
        if (!bound) revert NotBound();
        return "";
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
