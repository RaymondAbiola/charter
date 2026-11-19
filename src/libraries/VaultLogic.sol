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

    /// @return amount0 pulled from the payer
    /// @return amount1 pulled from the payer
    function deposit(Book storage b, Env memory env, address payer, uint256 shares, uint256 supply, uint256 minFirst)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Positions.collectPassive(b, env);

        uint128 dl;
        uint256 extra0;
        uint256 extra1;
        if (supply == 0) {
            if (shares <= minFirst) revert ZeroShares();
            dl = shares.toUint128();
        } else {
            dl = FullMath.mulDivRoundingUp(b.passiveLiquidity, shares, supply).toUint128();
            extra0 = FullMath.mulDivRoundingUp(b.idle0, shares, supply);
            extra1 = FullMath.mulDivRoundingUp(b.idle1, shares, supply);
        }

        (uint256 owe0, uint256 owe1) = Positions.owed(Positions.modifyPassive(env, int256(uint256(dl))));
        amount0 = owe0 + extra0;
        amount1 = owe1 + extra1;
        env.key.currency0.settle(env.pm, payer, amount0, false);
        env.key.currency1.settle(env.pm, payer, amount1, false);
        Positions.toIdle(b, env, extra0, extra1);
        b.passiveLiquidity += dl;
    }

    /// @dev Call after burning the shares, passing the supply from before the burn.
    function withdraw(Book storage b, Env memory env, address to, uint256 shares, uint256 supply)
        external
        returns (uint256 out0, uint256 out1)
    {
        Positions.collectPassive(b, env);

        uint128 dl = FullMath.mulDiv(b.passiveLiquidity, shares, supply).toUint128();
        out0 = FullMath.mulDiv(b.idle0, shares, supply);
        out1 = FullMath.mulDiv(b.idle1, shares, supply);

        Positions.fromIdle(b, env, out0, out1);
        if (dl > 0) {
            BalanceDelta d = Positions.modifyPassive(env, -int256(uint256(dl)));
            out0 += uint128(d.amount0());
            out1 += uint128(d.amount1());
            b.passiveLiquidity -= dl;
        }
        env.key.currency0.take(env.pm, to, out0, false);
        env.key.currency1.take(env.pm, to, out1, false);
    }
}
