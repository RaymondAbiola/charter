// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @notice A tick band around the current price inside which a lease cannot reach its
/// maintenance margin, so swaps in the same block can skip its full valuation.
/// @dev Only half the spare equity is spent on price, and the bounds are deliberately loose:
/// falling, equity can drop no faster than the most token0 the lease could ever hold; rising, no
/// faster than the token0 it owes at today's price, which only shrinks as the price climbs.
library GuardMath {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant WAD = 1e18;

    /// @param buffer equity above the maintenance margin, token1
    /// @param maxToken0 most token0 the lease could hold anywhere in its range
    /// @param owedToken0 token0 the lease owes at the current price
    /// @return lo the band holds while tick >= lo
    /// @return hi the band holds while tick < hi
    function band(uint160 sqrtP, uint256 buffer, uint256 maxToken0, uint256 owedToken0)
        internal
        pure
        returns (int24 lo, int24 hi)
    {
        uint256 budget = buffer / 2;
        uint256 price = FullMath.mulDiv(sqrtP, sqrtP, Q96);

        lo = TickMath.MIN_TICK;
        if (maxToken0 != 0) {
            uint256 drop = FullMath.mulDiv(budget, Q96, maxToken0);
            if (drop < price) {
                uint256 root = Math.sqrt(FullMath.mulDiv(price - drop, WAD * WAD, price), Math.Rounding.Ceil);
                uint256 sqrtLo = FullMath.mulDivRoundingUp(sqrtP, root, WAD);
                if (sqrtLo > TickMath.MIN_SQRT_PRICE) lo = TickMath.getTickAtSqrtPrice(uint160(sqrtLo)) + 1;
            }
        }

        hi = TickMath.MAX_TICK;
        if (owedToken0 != 0) {
            uint256 rise = FullMath.mulDiv(budget, Q96, owedToken0);
            // past 10^12x the band is wide enough to treat as open
            if (rise / 1e12 < price) {
                uint256 root = Math.sqrt(FullMath.mulDiv(price + rise, WAD * WAD, price), Math.Rounding.Floor);
                uint256 sqrtHi = FullMath.mulDiv(sqrtP, root, WAD);
                if (sqrtHi < TickMath.MAX_SQRT_PRICE) hi = TickMath.getTickAtSqrtPrice(uint160(sqrtHi));
            }
        }
    }
}
