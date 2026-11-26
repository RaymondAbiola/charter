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

    /// @dev Call after burning the shares, passing the supply from before the burn. The share of
    /// what leases still owe is paid from idle; where idle is short, the same value comes out of
    /// the passive position at the settlement price. Leased capital itself cannot leave yet.
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

        uint256 units = uint256(b.passiveLiquidity) + b.leasedUnits;
        uint256 dl = FullMath.mulDiv(units, shares, supply);
        uint256 want0 = FullMath.mulDiv(b.idle0 + r0, shares, supply);
        uint256 want1 = FullMath.mulDiv(b.idle1 + r1, shares, supply);
        out0 = want0 < b.idle0 ? want0 : b.idle0;
        out1 = want1 < b.idle1 ? want1 : b.idle1;
        uint256 short = Positions.valueAt(want0 - out0, want1 - out1, settleSqrt);
        if (short > 0) {
            (uint256 u0, uint256 u1) = Positions.fullRangeAmounts(env, settleSqrt, 1e18, true);
            dl += FullMath.mulDiv(short, 1e18, Positions.valueAt(u0, u1, settleSqrt));
        }
        if (dl > b.passiveLiquidity) revert NotEnoughPassive();

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
}
