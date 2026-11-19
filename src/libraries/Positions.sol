// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurrencySettler} from "@uniswap/hooks/utils/CurrencySettler.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Book, Lease, Env} from "../types/CharterTypes.sol";

/// @notice Position and claims plumbing shared by the hook's logic libraries.
library Positions {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q128 = 1 << 128;

    function modify(Env memory env, bytes32 salt, int24 lo, int24 hi, int256 liquidityDelta)
        internal
        returns (BalanceDelta d)
    {
        (d,) = env.pm
            .modifyLiquidity(
                env.key,
                ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: liquidityDelta, salt: salt}),
                ""
            );
    }

    function modifyPassive(Env memory env, int256 liquidityDelta) internal returns (BalanceDelta) {
        return modify(env, bytes32(0), env.fullLower, env.fullUpper, liquidityDelta);
    }

    function leaseSalt(uint256 slot) internal pure returns (bytes32) {
        return bytes32(slot + 1);
    }

    /// @dev Pokes the passive position so its fees land in depositor idle.
    function collectPassive(Book storage b, Env memory env) internal {
        if (b.passiveLiquidity == 0) return;
        BalanceDelta d = modifyPassive(env, 0);
        toIdle(b, env, uint128(d.amount0()), uint128(d.amount1()));
    }

    function toIdle(Book storage b, Env memory env, uint256 a0, uint256 a1) internal {
        if (a0 > 0) {
            env.pm.mint(address(this), env.key.currency0.toId(), a0);
            b.idle0 += a0;
        }
        if (a1 > 0) {
            env.pm.mint(address(this), env.key.currency1.toId(), a1);
            b.idle1 += a1;
        }
    }

    function fromIdle(Book storage b, Env memory env, uint256 a0, uint256 a1) internal {
        if (a0 > 0) {
            b.idle0 -= a0;
            env.pm.burn(address(this), env.key.currency0.toId(), a0);
        }
        if (a1 > 0) {
            b.idle1 -= a1;
            env.pm.burn(address(this), env.key.currency1.toId(), a1);
        }
    }

    function credit(Book storage b, Lease storage l, Env memory env, uint256 a0, uint256 a1) internal {
        if (a0 > 0) {
            env.pm.mint(address(this), env.key.currency0.toId(), a0);
            l.held0 += a0;
            b.totalHeld0 += a0;
        }
        if (a1 > 0) {
            env.pm.mint(address(this), env.key.currency1.toId(), a1);
            l.held1 += a1;
            b.totalHeld1 += a1;
        }
    }

    function debit(Book storage b, Lease storage l, Env memory env, uint256 a0, uint256 a1) internal {
        if (a0 > 0) {
            l.held0 -= a0;
            b.totalHeld0 -= a0;
            env.pm.burn(address(this), env.key.currency0.toId(), a0);
        }
        if (a1 > 0) {
            l.held1 -= a1;
            b.totalHeld1 -= a1;
            env.pm.burn(address(this), env.key.currency1.toId(), a1);
        }
    }

    function owed(BalanceDelta d) internal pure returns (uint256, uint256) {
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        return (a0 < 0 ? uint128(-a0) : 0, a1 < 0 ? uint128(-a1) : 0);
    }

    function fullRangeAmounts(Env memory env, uint160 sqrtP, uint128 l, bool roundUp)
        internal
        pure
        returns (uint256 a0, uint256 a1)
    {
        a0 = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(env.fullUpper), l, roundUp);
        a1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(env.fullLower), sqrtP, l, roundUp);
    }

    /// @dev token1 value of a token pair at a sqrt price.
    function valueAt(uint256 a0, uint256 a1, uint160 sqrtP) internal pure returns (uint256) {
        return a1 + FullMath.mulDiv(FullMath.mulDiv(a0, sqrtP, 1 << 96), sqrtP, 1 << 96);
    }

    function spot(Env memory env) internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = env.pm.getSlot0(env.key.toId());
    }
}
