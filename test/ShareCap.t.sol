// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Charter} from "../src/Charter.sol";
import {Fixture} from "./utils/Fixture.sol";

/// Managers may hold at most 5% of the pool's active liquidity. At ±600 ticks a unit of leased
/// capital becomes about 34 units of liquidity, so in this pool a lease of 5 units fits and 10 does not.
contract ShareCapTest is Fixture {
    function _shareCapBps() internal pure override returns (uint16) {
        return 500;
    }

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 1000e18);
        _lp(-1200, 1200, 3000e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);
    }

    function _open(address who, uint128 units, int24 half) internal {
        uint256 bond = charter.minBond(units);
        vm.prank(who);
        charter.openLease(0, units, 50_000, bond, -half, half);
    }

    function test_aSmallLeaseFits() public {
        _open(bob, 5e18, 600);
        assertEq(charter.lease(0).manager, bob);
        assertEq(charter.managedLiquidity(), charter.lease(0).liquidity);
    }

    function test_aLeaseTooBigForThePoolIsRejected() public {
        uint256 bond = charter.minBond(10e18);
        vm.prank(bob);
        vm.expectRevert(Charter.ShareCapExceeded.selector);
        charter.openLease(0, 10e18, 50_000, bond, -600, 600);
    }

    function test_rebalancingIntoATightRangeCanBreachTheCap() public {
        _open(bob, 5e18, 1200);
        uint128 before = charter.lease(0).liquidity;
        vm.prank(bob);
        vm.expectRevert(Charter.ShareCapExceeded.selector);
        charter.rebalance(0, -120, 120);
        assertEq(charter.lease(0).liquidity, before, "lease unchanged");
        assertEq(charter.lease(0).tickLower, -1200);
    }

    function test_aTakeoverThatWouldBreachTheCapRevertsAndTheBidderCanCancel() public {
        _open(bob, 5e18, 1200);
        uint256 bond = charter.minBond(5e18);
        vm.prank(carol);
        charter.bid(0, 5e18, 60_000, bond, -120, 120);

        vm.prank(carol);
        vm.expectRevert(Charter.NotReady.selector);
        charter.cancelBid(0);

        _warp(AUCTION_DELAY);
        _nextBlock();
        vm.expectRevert(Charter.ShareCapExceeded.selector);
        charter.activate(0);
        assertEq(charter.lease(0).manager, bob, "incumbent untouched");

        vm.prank(mallory);
        vm.expectRevert(Charter.NotReady.selector);
        charter.cancelBid(0);

        vm.prank(carol);
        charter.cancelBid(0);
        assertEq(manager.balanceOf(carol, currency1.toId()), bond, "escrow back as claims");
        assertEq(charter.totalEscrow(), 0);
        assertEq(charter.pendingBid(0).bidder, address(0));
    }

    function test_managedLiquidityFollowsTheLease() public {
        _open(bob, 5e18, 1200);
        assertEq(charter.managedLiquidity(), charter.lease(0).liquidity);
        vm.prank(bob);
        charter.rebalance(0, -2400, 2400);
        assertEq(charter.managedLiquidity(), charter.lease(0).liquidity);
        vm.prank(bob);
        charter.exitLease(0);
        assertEq(charter.managedLiquidity(), 0);
    }
}
