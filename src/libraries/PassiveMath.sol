// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";

/// @notice What one unit of depositor liquidity would have earned if all depositor capital sat
/// at full range. Managed ranges take fee share from the passive leg they are measured against,
/// so the managed liquidity that was in range is swapped back out of the denominator.
/// @dev The exact counterfactual depends on whether a swap was arbitrage (volume scales with
/// liquidity) or retail (it does not). This is the retail-side estimate, which is the higher of
/// the two, so it errs toward depositors.
library PassiveMath {
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant WAD = 1e18;

    /// @param fee LP fee paid by the swap, in the input token
    /// @param dfg the pool's real fee growth for the input token over the swap, Q128
    /// @param managed managed liquidity that was in range during the swap
    /// @param passive depositor liquidity really sitting at full range
    /// @param units all depositor units, leased or not
    function growth(uint256 fee, uint256 dfg, uint256 managed, uint256 passive, uint256 units)
        internal
        pure
        returns (uint256)
    {
        if (dfg == 0 || units == 0) return 0;
        uint256 effective = FullMath.mulDiv(fee, Q128, dfg);
        uint256 ours = managed + passive;
        uint256 others = effective > ours ? effective - ours : 0;
        return FullMath.mulDiv(fee, Q128, others + units);
    }

    /// @notice LP share of the fee on `amountIn`, given the LP fee and the protocol fee for that direction.
    /// @dev Mirrors the pool: the combined fee rounds the cross term down, then the protocol takes its cut.
    function lpFee(uint256 amountIn, uint24 fee, uint16 protocolFee) internal pure returns (uint256) {
        if (protocolFee == 0) return FullMath.mulDiv(amountIn, fee, 1e6);
        uint24 swapFee = ProtocolFeeLibrary.calculateSwapFee(protocolFee, fee);
        return FullMath.mulDiv(amountIn, swapFee - protocolFee, 1e6);
    }

    /// @notice Share of a price path from `s0` to `s1` that lies inside `[a, b)`, in WAD.
    function overlap(uint160 s0, uint160 s1, uint160 a, uint160 b) internal pure returns (uint256) {
        (uint160 lo, uint160 hi) = s0 < s1 ? (s0, s1) : (s1, s0);
        if (hi == lo) return (lo >= a && lo < b) ? WAD : 0;
        uint160 from = lo > a ? lo : a;
        uint160 to = hi < b ? hi : b;
        if (to <= from) return 0;
        return uint256(to - from) * WAD / (hi - lo);
    }
}
