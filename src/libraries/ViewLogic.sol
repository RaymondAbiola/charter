// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Book, Lease, Env} from "../types/CharterTypes.sol";
import {Positions} from "./Positions.sol";
import {LeaseMath} from "./LeaseMath.sol";
import {LeaseLogic} from "./LeaseLogic.sol";

/// @notice Read-only views, kept out of the hook's bytecode. The hook forwards to these by
/// delegatecall, so callers still read everything from the hook's address.
library ViewLogic {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint256 internal constant Q128 = 1 << 128;

    function leaseAccount(Book storage b, Lease storage l, Env memory env, uint256 slot, uint160 sv)
        external
        view
        returns (LeaseMath.Account memory a, uint256 bond, uint256 rent, int256 equity)
    {
        if (l.manager == address(0)) return (a, 0, 0, 0);
        a = LeaseMath.account(b, l, env, slot, sv);
        bond = l.bond;
        rent = LeaseLogic.rentDue(l, unitsValue(env, l.units, sv));
        equity = LeaseMath.equity(a, bond) - int256(rent);
    }

    function rentDue(Lease storage l, Env memory env, uint160 sv) external view returns (uint256) {
        if (l.manager == address(0)) return 0;
        return LeaseLogic.rentDue(l, unitsValue(env, l.units, sv));
    }

    /// @notice token1 value of `units` at full range at `sv`.
    function unitsValue(Env memory env, uint128 units, uint160 sv) public pure returns (uint256) {
        (uint256 a0, uint256 a1) = Positions.fullRangeAmounts(env, sv, units, false);
        return Positions.valueAt(a0, a1, sv);
    }

    function minBond(Env memory env, uint128 units, uint160 sv, uint256 bps) external pure returns (uint256) {
        (uint256 a0, uint256 a1) = Positions.fullRangeAmounts(env, sv, units, true);
        return FullMath.mulDivRoundingUp(Positions.valueAt(a0, a1, sv), bps, 10_000);
    }

    function bundle(Book storage b, Env memory env) public view returns (uint128, uint256, uint256) {
        (uint256 f0, uint256 f1) = _pendingPassiveFees(b, env);
        return (b.passiveLiquidity, b.idle0 + f0, b.idle1 + f1);
    }

    function previewDeposit(Book storage b, Env memory env, uint256 shares, uint256 supply)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint128 l, uint256 b0, uint256 b1) = bundle(b, env);
        uint128 dl = supply == 0 ? shares.toUint128() : FullMath.mulDivRoundingUp(l, shares, supply).toUint128();
        (amount0, amount1) = Positions.fullRangeAmounts(env, Positions.spot(env), dl, true);
        if (supply != 0) {
            amount0 += FullMath.mulDivRoundingUp(b0, shares, supply);
            amount1 += FullMath.mulDivRoundingUp(b1, shares, supply);
        }
    }

    function previewWithdraw(Book storage b, Env memory env, uint256 shares, uint256 supply)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (supply == 0) return (0, 0);
        (uint128 l, uint256 b0, uint256 b1) = bundle(b, env);
        (amount0, amount1) =
            Positions.fullRangeAmounts(env, Positions.spot(env), FullMath.mulDiv(l, shares, supply).toUint128(), false);
        amount0 += FullMath.mulDiv(b0, shares, supply);
        amount1 += FullMath.mulDiv(b1, shares, supply);
    }

    function _pendingPassiveFees(Book storage b, Env memory env) private view returns (uint256 f0, uint256 f1) {
        if (b.passiveLiquidity == 0) return (0, 0);
        PoolId id = env.key.toId();
        (uint128 l, uint256 last0, uint256 last1) =
            env.pm.getPositionInfo(id, address(this), env.fullLower, env.fullUpper, bytes32(0));
        (uint256 g0, uint256 g1) = env.pm.getFeeGrowthInside(id, env.fullLower, env.fullUpper);
        unchecked {
            f0 = FullMath.mulDiv(g0 - last0, l, Q128);
            f1 = FullMath.mulDiv(g1 - last1, l, Q128);
        }
    }
}
