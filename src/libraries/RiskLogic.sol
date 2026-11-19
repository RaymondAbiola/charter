// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Book, Lease, Guard, Env} from "../types/CharterTypes.sol";
import {Positions} from "./Positions.sol";
import {LeaseMath} from "./LeaseMath.sol";
import {LeaseLogic} from "./LeaseLogic.sol";
import {GuardMath} from "./GuardMath.sol";

/// @notice Per-swap health checks and liquidation. A full valuation costs about 30k gas a lease,
/// so each healthy check leaves budgets behind and later swaps skip the lease until one is spent.
library RiskLogic {
    using PoolIdLibrary for PoolKey;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MAX_GUARD = 1 days;

    struct Params {
        uint256 maxLeases;
        uint256 maintenanceBps;
        uint160 settleSqrt;
    }

    event Liquidated(
        uint256 indexed slot,
        address indexed manager,
        uint256 owedValue,
        uint256 heldValue,
        uint256 bondUsed,
        uint256 uncovered
    );

    /// @notice Run after every swap: skip leases whose budgets still hold, fully check the rest,
    /// close any below the margin and leave fresh budgets on the healthy ones.
    function check(
        Book storage b,
        mapping(uint256 => Lease) storage leases,
        mapping(uint256 => Guard) storage guards,
        Env memory env,
        Params memory p
    ) external {
        (uint160 sp, int24 tick) = _slot0(env);
        for (uint256 slot; slot < p.maxLeases; ++slot) {
            Lease storage l = leases[slot];
            if (l.manager == address(0)) continue;
            Guard storage g = guards[slot];
            if (_guarded(b, l, g, sp, tick)) continue;
            (bool under, LeaseMath.Account memory a, uint256 spare) = _assess(b, l, env, slot, sp, p.maintenanceBps);
            if (under) {
                _close(b, l, env, slot, p.settleSqrt);
                delete guards[slot];
            } else {
                _arm(b, l, g, a, sp, spare);
            }
        }
    }

    /// @notice Full check of one lease at `sqrtP`.
    function underwater(
        Book storage b,
        Lease storage l,
        Env memory env,
        uint256 slot,
        uint160 sqrtP,
        uint256 maintenanceBps
    ) external view returns (bool under) {
        (under,,) = _assess(b, l, env, slot, sqrtP, maintenanceBps);
    }

    function liquidate(Book storage b, Lease storage l, Env memory env, uint256 slot, uint160 settleSqrt) external {
        _close(b, l, env, slot, settleSqrt);
    }

    function _guarded(Book storage b, Lease storage l, Guard storage g, uint160 sp, int24 tick)
        private
        view
        returns (bool)
    {
        if (block.timestamp > g.validUntil || tick < g.lo || tick >= g.hi) return false;
        uint256 d0;
        uint256 d1;
        unchecked {
            d0 = b.passiveGrowth0X128 - g.growth0At;
            d1 = b.passiveGrowth1X128 - g.growth1At;
        }
        uint256 perUnit = FullMath.mulDiv(FullMath.mulDiv(d0, sp, Q96), sp, Q96) + d1;
        return FullMath.mulDiv(perUnit, l.units, Q128) <= g.feeBudget;
    }

    function _assess(
        Book storage b,
        Lease storage l,
        Env memory env,
        uint256 slot,
        uint160 sqrtP,
        uint256 maintenanceBps
    ) private view returns (bool under, LeaseMath.Account memory a, uint256 spare) {
        a = LeaseMath.account(b, l, env, slot, sqrtP);
        int256 s = LeaseMath.equity(a, l.bond) - int256(LeaseLogic.rentDue(l, _unitsValue(l, env, sqrtP)))
            - int256(a.owedValue * maintenanceBps / 10_000);
        if (s < 0) return (true, a, 0);
        spare = uint256(s);
    }

    /// @dev Half the spare equity goes to price, a quarter to rent over time, a quarter to fees owed.
    function _arm(
        Book storage b,
        Lease storage l,
        Guard storage g,
        LeaseMath.Account memory a,
        uint160 sp,
        uint256 spare
    ) private {
        uint256 maxToken0 = a.held0
            + SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtPriceAtTick(l.tickLower), TickMath.getSqrtPriceAtTick(l.tickUpper), l.liquidity, true
            );
        (int24 lo, int24 hi) = GuardMath.band(sp, spare, maxToken0, a.owed0);

        uint256 horizon = MAX_GUARD;
        if (l.rentPips != 0) {
            uint256 perSecond = a.owedValue * l.rentPips / (1e6 * YEAR);
            if (perSecond != 0 && spare / 4 / perSecond < horizon) horizon = spare / 4 / perSecond;
        }
        uint256 fees = spare / 4;
        g.lo = lo;
        g.hi = hi;
        g.validUntil = uint64(block.timestamp + horizon);
        g.feeBudget = fees > type(uint128).max ? type(uint128).max : uint128(fees);
        g.growth0At = b.passiveGrowth0X128;
        g.growth1At = b.passiveGrowth1X128;
    }

    function _close(Book storage b, Lease storage l, Env memory env, uint256 slot, uint160 settleSqrt) private {
        LeaseLogic.Settlement memory s = LeaseLogic.close(b, l, env, slot, settleSqrt, _unitsValue(l, env, settleSqrt));
        emit Liquidated(slot, s.manager, s.owedValue, s.heldValue, s.bondUsed, s.uncovered);
    }

    function _unitsValue(Lease storage l, Env memory env, uint160 sqrtP) private view returns (uint256) {
        (uint256 a0, uint256 a1) = Positions.fullRangeAmounts(env, sqrtP, l.units, false);
        return Positions.valueAt(a0, a1, sqrtP);
    }

    function _slot0(Env memory env) private view returns (uint160 sp, int24 tick) {
        (sp, tick,,) = StateLibrary.getSlot0(env.pm, env.key.toId());
    }
}
