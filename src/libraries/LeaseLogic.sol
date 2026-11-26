// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurrencySettler} from "@uniswap/hooks/utils/CurrencySettler.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {Book, Lease, Guard, Bid, Env} from "../types/CharterTypes.sol";
import {Positions} from "./Positions.sol";
import {LeaseMath} from "./LeaseMath.sol";

/// @notice Lease lifecycle: checks, state changes and events. Runs by delegatecall, so the hook
/// stays the owner of every position and the emitter of every event.
library LeaseLogic {
    using CurrencySettler for Currency;

    uint256 internal constant YEAR = 365 days;
    uint256 internal constant Q128 = 1 << 128;

    error RangeTooThin();
    error SlotTaken();
    error NotEnoughCapital();
    error BadRange();
    error BondTooSmall();
    error BidTooLow();
    error NoLease();

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
    event RentPaid(uint256 indexed slot, uint256 amount);
    event LeaseEnded(
        uint256 indexed slot,
        address indexed manager,
        uint256 owedValue,
        uint256 heldValue,
        uint256 bondUsed,
        uint256 uncovered,
        uint256 toManager0,
        uint256 toManager1
    );
    event BidPlaced(
        uint256 indexed slot,
        address indexed bidder,
        uint128 units,
        uint32 rentPips,
        uint256 bond,
        int24 tickLower,
        int24 tickUpper,
        uint64 readyAt
    );
    event BidRefunded(uint256 indexed slot, address indexed bidder, uint256 bond);
    event BidVoided(uint256 indexed slot, address indexed bidder);
    event TakenOver(uint256 indexed slot, address indexed from, address indexed to);
    event Repassivated(uint128 liquidity);

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

    /// @dev A lease order, used to open a lease directly or to bid for one.
    struct Order {
        address manager;
        uint256 slot;
        uint128 units;
        uint32 rentPips;
        uint256 bond;
        int24 tickLower;
        int24 tickUpper;
        bool fromEscrow;
    }

    struct Rules {
        uint160 settleSqrt;
        uint256 minBondBps;
        uint256 minRaiseBps;
        uint256 auctionDelay;
    }

    // ------------------------------------------------------------------ entry points

    function open(Book storage b, Lease storage l, Guard storage g, Env memory env, Rules memory r, Order memory o)
        external
    {
        if (l.manager != address(0)) revert SlotTaken();
        if (o.units == 0 || o.units > b.passiveLiquidity) revert NotEnoughCapital();
        _checkRange(env, o.tickLower, o.tickUpper);
        if (o.bond < _minBond(env, o.units, r)) revert BondTooSmall();
        g.validUntil = 0;
        _open(b, l, env, o);
    }

    function rebalance(
        Book storage b,
        Lease storage l,
        Guard storage g,
        Env memory env,
        Rules memory r,
        uint256 slot,
        int24 lo,
        int24 hi
    ) external {
        _checkRange(env, lo, hi);
        _chargeRent(b, l, slot, _unitsValue(env, l.units, r.settleSqrt));
        g.validUntil = 0;
        _exit(b, l, env, slot);
        uint128 liq = _enter(b, l, env, slot, lo, hi);
        emit Rebalanced(slot, lo, hi, liq);
    }

    /// @notice Moves accrued rent from the bond to depositor idle. Bond and idle are both token1
    /// claims the hook already holds, so this is bookkeeping only.
    function chargeRent(
        Book storage b,
        Lease storage l,
        Guard storage g,
        Env memory env,
        uint256 slot,
        uint160 settleSqrt
    ) external returns (uint256) {
        if (l.manager == address(0)) revert NoLease();
        g.validUntil = 0;
        return _chargeRent(b, l, slot, _unitsValue(env, l.units, settleSqrt));
    }

    /// @notice The manager ends their own lease. It settles exactly like a liquidation.
    function exit(Book storage b, Lease storage l, Guard storage g, Env memory env, uint256 slot, uint160 settleSqrt)
        external
    {
        g.validUntil = 0;
        _emitEnded(slot, _close(b, l, env, slot, settleSqrt, _unitsValue(env, l.units, settleSqrt)));
    }

    /// @notice Ends a lease and returns the split, for a caller that reports it its own way.
    function close(Book storage b, Lease storage l, Env memory env, uint256 slot, uint160 sqrtV, uint256 value)
        external
        returns (Settlement memory)
    {
        return _close(b, l, env, slot, sqrtV, value);
    }

    /// @notice Bid for an occupied slot. Rent must beat both the lease and any pending bid by
    /// `minRaiseBps`. The bond is escrowed now and the bid it replaces is refunded.
    function bid(Book storage b, Lease storage l, Bid storage pending, Env memory env, Rules memory r, Order memory o)
        external
    {
        if (l.manager == address(0)) revert NoLease();
        _checkRange(env, o.tickLower, o.tickUpper);
        if (o.units == 0 || o.units > l.units + b.passiveLiquidity) revert NotEnoughCapital();
        if (o.bond < _minBond(env, o.units, r)) revert BondTooSmall();
        uint256 floor = l.rentPips > pending.rentPips ? l.rentPips : pending.rentPips;
        if (o.rentPips <= floor || o.rentPips < floor * (10_000 + r.minRaiseBps) / 10_000) revert BidTooLow();

        env.key.currency1.settle(env.pm, o.manager, o.bond, false);
        env.pm.mint(address(this), env.key.currency1.toId(), o.bond);
        b.totalEscrow += o.bond;
        _refund(b, pending, env, o.slot);

        uint64 readyAt = uint64(block.timestamp + r.auctionDelay);
        pending.bidder = o.manager;
        pending.rentPips = o.rentPips;
        pending.readyAt = readyAt;
        pending.units = o.units;
        pending.tickLower = o.tickLower;
        pending.tickUpper = o.tickUpper;
        pending.bond = o.bond;
        emit BidPlaced(o.slot, o.manager, o.units, o.rentPips, o.bond, o.tickLower, o.tickUpper, readyAt);
    }

    /// @notice Hands a slot to its pending bid: ends the current lease, puts the freed capital back
    /// to full range, then opens the bid from its escrowed bond, or refunds it if it no longer fits.
    /// @dev Only called in a block with no swap yet, so spot is also the settlement price.
    function activate(
        Book storage b,
        Lease storage l,
        Bid storage pending,
        Guard storage g,
        Env memory env,
        Rules memory r,
        uint256 slot
    ) external {
        address to = pending.bidder;
        // the slot may have changed hands since the bid, so it has to beat whoever holds it now;
        // a bid that fails that, or no longer covers its bond, leaves the incumbent untouched
        uint256 current = l.manager == address(0) ? 0 : l.rentPips;
        bool outbids = current == 0
            || (pending.rentPips > current && pending.rentPips >= current * (10_000 + r.minRaiseBps) / 10_000);
        if (!outbids || pending.bond < _minBond(env, pending.units, r)) {
            _refund(b, pending, env, slot);
            emit BidVoided(slot, to);
            return;
        }
        g.validUntil = 0;
        address from = l.manager;
        if (from != address(0)) {
            _emitEnded(slot, _close(b, l, env, slot, r.settleSqrt, _unitsValue(env, l.units, r.settleSqrt)));
        }
        uint128 freed = _repassivate(b, env);
        if (freed > 0) emit Repassivated(freed);

        // the freed capital can come back a little short if the old lease lost value, so take what is there
        uint128 units = pending.units > b.passiveLiquidity ? b.passiveLiquidity : pending.units;
        if (units == 0) {
            _refund(b, pending, env, slot);
            emit BidVoided(slot, to);
            return;
        }
        Order memory o = Order({
            manager: to,
            slot: slot,
            units: units,
            rentPips: pending.rentPips,
            bond: pending.bond,
            tickLower: pending.tickLower,
            tickUpper: pending.tickUpper,
            fromEscrow: true
        });
        _clearBid(pending);
        _open(b, l, env, o);
        emit TakenOver(slot, from, to);
    }

    /// @notice Before depositors come or go: collect each lease's rent, pull its position fees into
    /// its loose balance and pay as much of its passive fee debt as that balance covers. Equity
    /// does not move, because what the lease holds and what it owes drop by the same amount.
    /// @return r0 fee debt still owed in token0 after paying what could be paid
    /// @return r1 fee debt still owed in token1
    function settleAll(
        Book storage b,
        mapping(uint256 => Lease) storage leases,
        Env memory env,
        uint256 maxLeases,
        uint160 settleSqrt
    ) external returns (uint256 r0, uint256 r1) {
        for (uint256 slot; slot < maxLeases; ++slot) {
            Lease storage l = leases[slot];
            if (l.manager == address(0)) continue;
            _chargeRent(b, l, slot, _unitsValue(env, l.units, settleSqrt));
            if (l.liquidity > 0) {
                BalanceDelta d = Positions.modify(env, Positions.leaseSalt(slot), l.tickLower, l.tickUpper, 0);
                Positions.credit(b, l, env, uint128(d.amount0()), uint128(d.amount1()));
            }
            (uint256 o0, uint256 o1) = LeaseMath.feeDebt(b, l);
            uint256 p0 = o0 < l.held0 ? o0 : l.held0;
            uint256 p1 = o1 < l.held1 ? o1 : l.held1;
            // held and idle are both claims the hook already holds, so paying is bookkeeping
            l.held0 -= p0;
            l.held1 -= p1;
            b.totalHeld0 -= p0;
            b.totalHeld1 -= p1;
            b.idle0 += p0;
            b.idle1 += p1;
            unchecked {
                l.growth0Start += FullMath.mulDiv(p0, Q128, l.units);
                l.growth1Start += FullMath.mulDiv(p1, Q128, l.units);
            }
            (o0, o1) = LeaseMath.feeDebt(b, l);
            r0 += o0;
            r1 += o1;
        }
    }

    /// @notice Puts idle depositor tokens back into the passive full-range position.
    function repassivate(Book storage b, Env memory env) external {
        uint128 liq = _repassivate(b, env);
        if (liq > 0) emit Repassivated(liq);
    }

    // ------------------------------------------------------------------ rent

    /// @notice Rent accrued and not yet paid on a lease worth `value` (token1).
    function rentDue(Lease storage l, uint256 value) internal view returns (uint256) {
        return _rentScaled(l, value) / (1e6 * YEAR);
    }

    function _rentScaled(Lease storage l, uint256 value) private view returns (uint256) {
        return value * l.rentPips * (block.timestamp - l.rentPaidAt) + l.rentCarry;
    }

    /// @dev The remainder is carried exactly, so neither rounding nor a short bond loses rent.
    function _chargeRent(Book storage b, Lease storage l, uint256 slot, uint256 value) private returns (uint256 paid) {
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
        emit RentPaid(slot, paid);
    }

    // ------------------------------------------------------------------ internals

    function _open(Book storage b, Lease storage l, Env memory env, Order memory o) private {
        if (o.fromEscrow) {
            b.totalEscrow -= o.bond;
        } else {
            env.key.currency1.settle(env.pm, o.manager, o.bond, false);
            env.pm.mint(address(this), env.key.currency1.toId(), o.bond);
        }
        b.totalBond += o.bond;

        // fees earned so far belong to depositors, so collect before carving out the principal
        Positions.collectPassive(b, env);
        BalanceDelta d = Positions.modifyPassive(env, -int256(uint256(o.units)));
        b.passiveLiquidity -= o.units;
        b.leasedUnits += o.units;

        l.manager = o.manager;
        l.rentPips = o.rentPips;
        l.openedAt = uint64(block.timestamp);
        l.rentPaidAt = uint64(block.timestamp);
        l.units = o.units;
        l.growth0Start = b.passiveGrowth0X128;
        l.growth1Start = b.passiveGrowth1X128;
        l.bond = o.bond;
        Positions.credit(b, l, env, uint128(d.amount0()), uint128(d.amount1()));
        uint128 liq = _enter(b, l, env, o.slot, o.tickLower, o.tickUpper);
        emit LeaseOpened(o.slot, o.manager, o.units, o.rentPips, o.bond, o.tickLower, o.tickUpper, liq);
    }

    /// @dev Collects rent, pulls the liquidity (never re-adds it, so a forced close cannot be
    /// sandwiched) and settles at `sqrtV`: depositors take what they are owed, the bond covers a
    /// shortfall, the manager keeps any surplus as claims.
    function _close(Book storage b, Lease storage l, Env memory env, uint256 slot, uint160 sqrtV, uint256 value)
        private
        returns (Settlement memory s)
    {
        _chargeRent(b, l, slot, value);
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

    function _emitEnded(uint256 slot, Settlement memory s) private {
        emit LeaseEnded(slot, s.manager, s.owedValue, s.heldValue, s.bondUsed, s.uncovered, s.toManager0, s.toManager1);
    }

    function _refund(Book storage b, Bid storage pending, Env memory env, uint256 slot) private {
        address bidder = pending.bidder;
        if (bidder == address(0)) return;
        uint256 bond = pending.bond;
        b.totalEscrow -= bond;
        env.pm.transfer(bidder, env.key.currency1.toId(), bond);
        emit BidRefunded(slot, bidder, bond);
        _clearBid(pending);
    }

    function _clearBid(Bid storage pending) private {
        delete pending.bidder;
        delete pending.rentPips;
        delete pending.readyAt;
        delete pending.units;
        delete pending.tickLower;
        delete pending.tickUpper;
        delete pending.bond;
    }

    function _repassivate(Book storage b, Env memory env) private returns (uint128 liq) {
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

    function _exit(Book storage b, Lease storage l, Env memory env, uint256 slot) private {
        if (l.liquidity == 0) return;
        BalanceDelta d =
            Positions.modify(env, Positions.leaseSalt(slot), l.tickLower, l.tickUpper, -int256(uint256(l.liquidity)));
        l.liquidity = 0;
        Positions.credit(b, l, env, uint128(d.amount0()), uint128(d.amount1()));
    }

    function _enter(Book storage b, Lease storage l, Env memory env, uint256 slot, int24 lo, int24 hi)
        private
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

    function _checkRange(Env memory env, int24 lo, int24 hi) private pure {
        int24 spacing = env.key.tickSpacing;
        if (lo >= hi || lo < env.fullLower || hi > env.fullUpper || lo % spacing != 0 || hi % spacing != 0) {
            revert BadRange();
        }
    }

    function _unitsValue(Env memory env, uint128 units, uint160 sqrtP) private pure returns (uint256) {
        (uint256 a0, uint256 a1) = Positions.fullRangeAmounts(env, sqrtP, units, false);
        return Positions.valueAt(a0, a1, sqrtP);
    }

    function _minBond(Env memory env, uint128 units, Rules memory r) private pure returns (uint256) {
        (uint256 a0, uint256 a1) = Positions.fullRangeAmounts(env, r.settleSqrt, units, true);
        return FullMath.mulDivRoundingUp(Positions.valueAt(a0, a1, r.settleSqrt), r.minBondBps, 10_000);
    }
}
