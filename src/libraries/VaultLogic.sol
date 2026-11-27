// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurrencySettler} from "@uniswap/hooks/utils/CurrencySettler.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Book, Env} from "../types/CharterTypes.sol";
import {Positions} from "./Positions.sol";

/// @notice Depositor flows. Shares are a pro-rata slice of a bundle of full-range liquidity units
/// and idle tokens, so nothing here is priced.
library VaultLogic {
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    error ZeroShares();
    error NotEnoughPassive();

    /// @param r0 fee debt leases still owe depositors in token0
    /// @param r1 fee debt leases still owe depositors in token1
    /// @return amount0 pulled from the payer
    /// @return amount1 pulled from the payer
    function deposit(
        Book storage b,
        Env memory env,
        address payer,
        uint256 shares,
        uint256 supply,
        uint256 minFirst,
        uint256 r0,
        uint256 r1
    ) external returns (uint256 amount0, uint256 amount1) {
        Positions.collectPassive(b, env);

        uint128 dl;
        uint256 extra0;
        uint256 extra1;
        if (supply == 0) {
            if (shares <= minFirst) revert ZeroShares();
            dl = shares.toUint128();
        } else {
            // leased units are owed back as full-range units, so a newcomer buys into them as passive
            uint256 units = uint256(b.passiveLiquidity) + b.leasedUnits;
            dl = FullMath.mulDivRoundingUp(units, shares, supply).toUint128();
            extra0 = FullMath.mulDivRoundingUp(b.idle0 + r0, shares, supply);
            extra1 = FullMath.mulDivRoundingUp(b.idle1 + r1, shares, supply);
        }

        (uint256 owe0, uint256 owe1) = Positions.owed(Positions.modifyPassive(env, int256(uint256(dl))));
        amount0 = owe0 + extra0;
        amount1 = owe1 + extra1;
        env.key.currency0.settle(env.pm, payer, amount0, false);
        env.key.currency1.settle(env.pm, payer, amount1, false);
        Positions.toIdle(b, env, extra0, extra1);
        b.passiveLiquidity += dl;
    }

    /// @dev Call after burning the shares, passing the supply from before the burn. Pays by value,
    /// at the settlement price: the token share from idle, the unit share as passive liquidity, then
    /// anything still owed (idle short of a token, or units the passive position cannot cover after a
    /// recall) first as more passive liquidity and last from whatever idle is left.
    function withdraw(
        Book storage b,
        Env memory env,
        address to,
        uint256 shares,
        uint256 supply,
        uint256 r0,
        uint256 r1,
        uint160 settleSqrt
    ) external returns (uint256 out0, uint256 out1) {
        Positions.collectPassive(b, env);

        uint256 dl = FullMath.mulDiv(uint256(b.passiveLiquidity) + b.leasedUnits, shares, supply);
        uint256 want0 = FullMath.mulDiv(b.idle0 + r0, shares, supply);
        uint256 want1 = FullMath.mulDiv(b.idle1 + r1, shares, supply);
        out0 = want0 < b.idle0 ? want0 : b.idle0;
        out1 = want1 < b.idle1 ? want1 : b.idle1;

        uint256 perUnit = _valueOfUnits(env, settleSqrt);
        uint256 short = Positions.valueAt(want0 - out0, want1 - out1, settleSqrt);
        uint256 passive = b.passiveLiquidity;
        if (dl > passive) {
            short += FullMath.mulDivRoundingUp(dl - passive, perUnit, 1e18);
            dl = passive;
        }
        if (short > 0 && dl < passive) {
            uint256 extra = FullMath.mulDiv(short, 1e18, perUnit);
            if (extra > passive - dl) extra = passive - dl;
            dl += extra;
            uint256 covered = FullMath.mulDiv(extra, perUnit, 1e18);
            short = short > covered ? short - covered : 0;
        }
        // a couple of wei of rounding is not worth reverting over
        if (short > 2) {
            (uint256 add0, uint256 add1) = _fromLeftovers(b.idle0 - out0, b.idle1 - out1, short, settleSqrt);
            out0 += add0;
            out1 += add1;
        }

        Positions.fromIdle(b, env, out0, out1);
        if (dl > 0) {
            BalanceDelta d = Positions.modifyPassive(env, -int256(dl));
            out0 += uint128(d.amount0());
            out1 += uint128(d.amount1());
            b.passiveLiquidity -= uint128(dl);
        }
        env.key.currency0.take(env.pm, to, out0, false);
        env.key.currency1.take(env.pm, to, out1, false);
    }

    /// @dev token1 value of 1e18 full-range units at `sqrtP`.
    function _valueOfUnits(Env memory env, uint160 sqrtP) private pure returns (uint256) {
        (uint256 u0, uint256 u1) = Positions.fullRangeAmounts(env, sqrtP, 1e18, false);
        return Positions.valueAt(u0, u1, sqrtP);
    }

    /// @dev Pays `value` (token1) out of spare idle: token1 first, then token0 at `sqrtP`.
    function _fromLeftovers(uint256 spare0, uint256 spare1, uint256 value, uint160 sqrtP)
        private
        pure
        returns (uint256 a0, uint256 a1)
    {
        a1 = value < spare1 ? value : spare1;
        value -= a1;
        if (value == 0) return (0, a1);
        a0 = FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(value, 1 << 96, sqrtP), 1 << 96, sqrtP);
        if (a0 > spare0) revert NotEnoughPassive();
    }
}
