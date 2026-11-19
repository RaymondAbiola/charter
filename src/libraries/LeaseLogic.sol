// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurrencySettler} from "@uniswap/hooks/utils/CurrencySettler.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {Book, Lease, Env} from "../types/CharterTypes.sol";
import {Positions} from "./Positions.sol";
import {LeaseMath} from "./LeaseMath.sol";

/// @notice Lease lifecycle. Runs by delegatecall, so the hook stays the owner of every position.
library LeaseLogic {
    using CurrencySettler for Currency;

    error RangeTooThin();

    event RentPaid(uint256 indexed slot, uint256 amount);

    uint256 internal constant YEAR = 365 days;

    /// @dev How a closed lease was split. Values in token1 at the settlement price.
    struct Settlement {
        address manager;
        uint256 owedValue;
        uint256 heldValue;
        uint256 bondUsed;
        uint256 uncovered;
        uint256 toManager0;
        uint256 toManager1;
    }

    struct OpenArgs {
        address manager;
        uint256 slot;
        uint128 units;
        uint32 rentPips;
        uint256 bond;
        int24 tickLower;
        int24 tickUpper;
    }

    function open(Book storage b, Lease storage l, Env memory env, OpenArgs memory a)
        external
        returns (uint128 liquidity)
    {
        env.key.currency1.settle(env.pm, a.manager, a.bond, false);
        env.pm.mint(address(this), env.key.currency1.toId(), a.bond);
        b.totalBond += a.bond;

        // fees earned so far belong to depositors, so collect before carving out the principal
        Positions.collectPassive(b, env);
        BalanceDelta d = Positions.modifyPassive(env, -int256(uint256(a.units)));
        b.passiveLiquidity -= a.units;
        b.leasedUnits += a.units;

        l.manager = a.manager;
        l.rentPips = a.rentPips;
        l.openedAt = uint64(block.timestamp);
        l.rentPaidAt = uint64(block.timestamp);
        l.units = a.units;
        l.growth0Start = b.passiveGrowth0X128;
        l.growth1Start = b.passiveGrowth1X128;
        l.bond = a.bond;
        Positions.credit(b, l, env, uint128(d.amount0()), uint128(d.amount1()));
        liquidity = _enter(b, l, env, a.slot, a.tickLower, a.tickUpper);
    }

    /// @notice Rent accrued and not yet paid on a lease worth `value` (token1).
    function rentDue(Lease storage l, uint256 value) internal view returns (uint256) {
        return _rentScaled(l, value) / (1e6 * YEAR);
    }

    function _rentScaled(Lease storage l, uint256 value) private view returns (uint256) {
        return value * l.rentPips * (block.timestamp - l.rentPaidAt) + l.rentCarry;
    }

    /// @notice Moves accrued rent from the bond to depositor idle. Bond and idle are both token1
    /// claims the hook already holds, so this is bookkeeping only.
    /// @dev The remainder is carried exactly, so neither rounding nor a short bond loses rent.
    function chargeRent(Book storage b, Lease storage l, uint256 value) external returns (uint256 paid) {
        return _chargeRent(b, l, value);
    }

    function _chargeRent(Book storage b, Lease storage l, uint256 value) internal returns (uint256 paid) {
        uint256 total = _rentScaled(l, value);
        l.rentPaidAt = uint64(block.timestamp);
        uint256 due = total / (1e6 * YEAR);
        uint256 bond = l.bond;
        paid = due <= bond ? due : bond;
        l.rentCarry = total - paid * (1e6 * YEAR);
        if (paid == 0) return 0;
        l.bond = bond - paid;
        b.totalBond -= paid;
        b.idle1 += paid;
    }

    /// @notice Ends a lease: collects rent, pulls its liquidity and settles it against what it owes.
    /// Liquidity is only removed here, never re-added, so a forced close cannot be sandwiched.
    /// @param sqrtV settlement price, clamped to the block's opening price
    /// @param value the leased units' value at that price, for rent
    function close(Book storage b, Lease storage l, Env memory env, uint256 slot, uint160 sqrtV, uint256 value)
        external
        returns (Settlement memory s)
    {
        uint256 rent = _chargeRent(b, l, value);
        if (rent > 0) emit RentPaid(slot, rent);
        _exit(b, l, env, slot);
        s.manager = l.manager;

        (uint256 o0, uint256 o1) = LeaseMath.owed(b, l, env, sqrtV);
        s.owedValue = Positions.valueAt(o0, o1, sqrtV) + rentDue(l, value);
        uint256 h0 = l.held0;
        uint256 h1 = l.held1;
        s.heldValue = Positions.valueAt(h0, h1, sqrtV);

        uint256 bond = l.bond;
        uint256 toDepositors0 = h0;
        uint256 toDepositors1 = h1;
        if (s.heldValue > s.owedValue) {
            // depositors take a slice of each token worth what they are owed, the manager keeps the rest
            toDepositors0 = FullMath.mulDivRoundingUp(h0, s.owedValue, s.heldValue);
            toDepositors1 = FullMath.mulDivRoundingUp(h1, s.owedValue, s.heldValue);
            if (toDepositors0 > h0) toDepositors0 = h0;
            if (toDepositors1 > h1) toDepositors1 = h1;
        } else {
            uint256 gap = s.owedValue - s.heldValue;
            s.bondUsed = gap < bond ? gap : bond;
            s.uncovered = gap - s.bondUsed;
        }
        s.toManager0 = h0 - toDepositors0;
        s.toManager1 = h1 - toDepositors1 + (bond - s.bondUsed);

        b.totalHeld0 -= h0;
        b.totalHeld1 -= h1;
        b.totalBond -= bond;
        b.idle0 += toDepositors0;
        b.idle1 += toDepositors1 + s.bondUsed;
        b.leasedUnits -= l.units;
        b.uncovered += s.uncovered;
        if (s.toManager0 > 0) env.pm.transfer(s.manager, env.key.currency0.toId(), s.toManager0);
        if (s.toManager1 > 0) env.pm.transfer(s.manager, env.key.currency1.toId(), s.toManager1);
        delete l.manager;
        delete l.rentPips;
        delete l.openedAt;
        delete l.tickLower;
        delete l.tickUpper;
        delete l.rentPaidAt;
        delete l.units;
        delete l.growth0Start;
        delete l.growth1Start;
        delete l.bond;
        delete l.held0;
        delete l.held1;
        delete l.rentCarry;
    }

    /// @notice Puts idle depositor tokens back into the passive full-range position.
    function repassivate(Book storage b, Env memory env) external returns (uint128 liq) {
        Positions.collectPassive(b, env);
        liq = LiquidityAmounts.getLiquidityForAmounts(
            Positions.spot(env),
            TickMath.getSqrtPriceAtTick(env.fullLower),
            TickMath.getSqrtPriceAtTick(env.fullUpper),
            b.idle0,
            b.idle1
        );
        liq = uint128(uint256(liq) * 999_999 / 1_000_000);
        if (liq == 0) return 0;
        (uint256 owe0, uint256 owe1) = Positions.owed(Positions.modifyPassive(env, int256(uint256(liq))));
        Positions.fromIdle(b, env, owe0, owe1);
        b.passiveLiquidity += liq;
    }

    function rebalance(Book storage b, Lease storage l, Env memory env, uint256 slot, int24 lo, int24 hi)
        external
        returns (uint128)
    {
        _exit(b, l, env, slot);
        return _enter(b, l, env, slot, lo, hi);
    }

    function _exit(Book storage b, Lease storage l, Env memory env, uint256 slot) internal {
        if (l.liquidity == 0) return;
        BalanceDelta d =
            Positions.modify(env, Positions.leaseSalt(slot), l.tickLower, l.tickUpper, -int256(uint256(l.liquidity)));
        l.liquidity = 0;
        Positions.credit(b, l, env, uint128(d.amount0()), uint128(d.amount1()));
    }

    function _enter(Book storage b, Lease storage l, Env memory env, uint256 slot, int24 lo, int24 hi)
        internal
        returns (uint128 liq)
    {
        liq = LiquidityAmounts.getLiquidityForAmounts(
            Positions.spot(env), TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), l.held0, l.held1
        );
        // leave a hair of slack so rounding up on the way in never overdraws the lease
        liq = uint128(uint256(liq) * 999_999 / 1_000_000);
        if (liq == 0) revert RangeTooThin();
        (uint256 owe0, uint256 owe1) =
            Positions.owed(Positions.modify(env, Positions.leaseSalt(slot), lo, hi, int256(uint256(liq))));
        Positions.debit(b, l, env, owe0, owe1);
        l.liquidity = liq;
        l.tickLower = lo;
        l.tickUpper = hi;
    }
}
