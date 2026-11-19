// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurrencySettler} from "@uniswap/hooks/utils/CurrencySettler.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {Book, Lease, Env} from "../types/CharterTypes.sol";
import {Positions} from "./Positions.sol";

/// @notice Lease lifecycle. Runs by delegatecall, so the hook stays the owner of every position.
library LeaseLogic {
    using CurrencySettler for Currency;

    error RangeTooThin();

    uint256 internal constant YEAR = 365 days;

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
