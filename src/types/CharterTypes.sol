// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @dev Depositor and lease totals. Claims held by the hook always equal
/// idle + held (+ bond for currency1).
struct Book {
    uint128 passiveLiquidity;
    uint128 leasedUnits;
    uint256 idle0;
    uint256 idle1;
    uint256 totalHeld0;
    uint256 totalHeld1;
    uint256 totalBond;
    uint256 passiveGrowth0X128;
    uint256 passiveGrowth1X128;
    // value (token1) depositors were owed on closed leases that neither the lease nor its bond covered
    uint256 uncovered;
}

/// @dev The first word after the manager word (liquidity and ticks) is all the swap path reads.
struct Lease {
    address manager;
    uint32 rentPips;
    uint64 openedAt;
    uint128 liquidity;
    int24 tickLower;
    int24 tickUpper;
    uint64 rentPaidAt;
    uint128 units;
    uint256 growth0Start;
    uint256 growth1Start;
    uint256 bond;
    uint256 held0;
    uint256 held1;
    // unpaid rent in value * pips * seconds, so no fraction is ever rounded away
    uint256 rentCarry;
}

struct Env {
    IPoolManager pm;
    PoolKey key;
    int24 fullLower;
    int24 fullUpper;
}
