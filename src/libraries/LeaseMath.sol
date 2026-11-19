// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Book, Lease, Env} from "../types/CharterTypes.sol";
import {Positions} from "./Positions.sol";

/// @notice What a lease owes depositors and what it holds. Token amounts are taken at spot and
/// valued in token1 at the settlement price the caller passes in.
library LeaseMath {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q128 = 1 << 128;

    struct Account {
        uint256 owed0;
        uint256 owed1;
        uint256 held0;
        uint256 held1;
        uint256 owedValue;
        uint256 heldValue;
    }

    function account(Book storage b, Lease storage l, Env memory env, uint256 slot, uint160 sqrtV)
        internal
        view
        returns (Account memory a)
    {
        uint160 sp = Positions.spot(env);
        (a.owed0, a.owed1) = owed(b, l, env, sp);
        (a.held0, a.held1) = held(l, env, slot, sp);
        a.owedValue = Positions.valueAt(a.owed0, a.owed1, sqrtV);
        a.heldValue = Positions.valueAt(a.held0, a.held1, sqrtV);
    }

    /// @dev The leased units at full range plus their passive fees since the lease opened. Rounds up.
    function owed(Book storage b, Lease storage l, Env memory env, uint160 sp)
        internal
        view
        returns (uint256 a0, uint256 a1)
    {
        (a0, a1) = Positions.fullRangeAmounts(env, sp, l.units, true);
        unchecked {
            a0 += FullMath.mulDivRoundingUp(b.passiveGrowth0X128 - l.growth0Start, l.units, Q128);
            a1 += FullMath.mulDivRoundingUp(b.passiveGrowth1X128 - l.growth1Start, l.units, Q128);
        }
    }

    /// @dev The lease's position at spot, its uncollected fees and its loose tokens. Rounds down.
    function held(Lease storage l, Env memory env, uint256 slot, uint160 sp)
        internal
        view
        returns (uint256 a0, uint256 a1)
    {
        a0 = l.held0;
        a1 = l.held1;
        uint128 liq = l.liquidity;
        if (liq == 0) return (a0, a1);
        (uint256 p0, uint256 p1) = positionAmounts(sp, l.tickLower, l.tickUpper, liq);
        (uint256 f0, uint256 f1) = pendingFees(env, l.tickLower, l.tickUpper, Positions.leaseSalt(slot));
        a0 += p0 + f0;
        a1 += p1 + f1;
    }

    function positionAmounts(uint160 sp, int24 lo, int24 hi, uint128 liq)
        internal
        pure
        returns (uint256 a0, uint256 a1)
    {
        uint160 sa = TickMath.getSqrtPriceAtTick(lo);
        uint160 sb = TickMath.getSqrtPriceAtTick(hi);
        if (sp <= sa) {
            a0 = SqrtPriceMath.getAmount0Delta(sa, sb, liq, false);
        } else if (sp < sb) {
            a0 = SqrtPriceMath.getAmount0Delta(sp, sb, liq, false);
            a1 = SqrtPriceMath.getAmount1Delta(sa, sp, liq, false);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sa, sb, liq, false);
        }
    }

    function pendingFees(Env memory env, int24 lo, int24 hi, bytes32 salt)
        internal
        view
        returns (uint256 f0, uint256 f1)
    {
        PoolId id = env.key.toId();
        (uint128 liq, uint256 last0, uint256 last1) = env.pm.getPositionInfo(id, address(this), lo, hi, salt);
        (uint256 g0, uint256 g1) = env.pm.getFeeGrowthInside(id, lo, hi);
        unchecked {
            f0 = FullMath.mulDiv(g0 - last0, liq, Q128);
            f1 = FullMath.mulDiv(g1 - last1, liq, Q128);
        }
    }

    function equity(Account memory a, uint256 bond) internal pure returns (int256) {
        return int256(bond + a.heldValue) - int256(a.owedValue);
    }
}
