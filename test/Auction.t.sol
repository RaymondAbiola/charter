// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Charter} from "../src/Charter.sol";
import {Lease, Bid} from "../src/types/CharterTypes.sol";
import {Fixture} from "./utils/Fixture.sol";

contract AuctionTest is Fixture {
    uint128 constant UNITS = 300e18;
    uint32 constant RENT = 50_000;

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 500e18);
        _lp(-1200, 1200, 1500e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);
        uint256 bond = charter.minBond(UNITS);
        vm.prank(bob);
        charter.openLease(0, UNITS, RENT, bond, -600, 600);
    }

    function _bid(address who, uint32 rent, uint256 bond) internal {
        vm.prank(who);
        charter.bid(0, UNITS, rent, bond, -1200, 1200);
    }

    function _ledger() internal view {
        assertEq(
            manager.balanceOf(address(charter), currency0.toId()), charter.idle0() + charter.totalHeld0(), "claims0"
        );
        assertEq(
            manager.balanceOf(address(charter), currency1.toId()),
            charter.idle1() + charter.totalHeld1() + charter.totalBond() + charter.totalEscrow(),
            "claims1"
        );
    }

    function _ready() internal {
        _warp(AUCTION_DELAY);
        _nextBlock();
    }

    function _hasLog(Vm.Log[] memory logs, bytes32 topic) internal view returns (bool) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(charter) && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    function test_bidEscrowsTheBond() public {
        uint256 bond = charter.minBond(UNITS);
        uint256 before = currency1.balanceOf(carol);
        vm.expectEmit(true, true, false, true, address(charter));
        emit Charter.BidPlaced(0, carol, UNITS, 60_000, bond, -1200, 1200, uint64(block.timestamp + AUCTION_DELAY));
        _bid(carol, 60_000, bond);

        assertEq(before - currency1.balanceOf(carol), bond);
        assertEq(charter.totalEscrow(), bond);
        Bid memory b = charter.pendingBid(0);
        assertEq(b.bidder, carol);
        assertEq(b.rentPips, 60_000);
        assertEq(b.units, UNITS);
        assertEq(b.readyAt, block.timestamp + AUCTION_DELAY);
        _ledger();
    }

    function test_bidRejections() public {
        uint256 bond = charter.minBond(UNITS);
        vm.startPrank(carol);
        vm.expectRevert(Charter.BadSlot.selector);
        charter.bid(MAX_LEASES, UNITS, 60_000, bond, -1200, 1200);
        vm.expectRevert(Charter.NoLease.selector);
        charter.bid(1, UNITS, 60_000, bond, -1200, 1200);
        vm.expectRevert(Charter.BidTooLow.selector);
        charter.bid(0, UNITS, RENT, bond, -1200, 1200);
        vm.expectRevert(Charter.BidTooLow.selector);
        charter.bid(0, UNITS, 52_499, bond, -1200, 1200);
        vm.expectRevert(Charter.BondTooSmall.selector);
        charter.bid(0, UNITS, 60_000, bond - 1, -1200, 1200);
        vm.expectRevert(Charter.BadRange.selector);
        charter.bid(0, UNITS, 60_000, bond, -1190, 1200);
        vm.expectRevert(Charter.NotEnoughCapital.selector);
        charter.bid(0, 1001e18, 60_000, type(uint128).max, -1200, 1200);
        charter.bid(0, UNITS, 52_500, bond, -1200, 1200);
        vm.stopPrank();
    }

    function test_outbidRefundsThePreviousBidder() public {
        uint256 bond = charter.minBond(UNITS);
        _bid(carol, 60_000, bond);

        vm.prank(mallory);
        vm.expectRevert(Charter.BidTooLow.selector);
        charter.bid(0, UNITS, 62_999, bond, -1200, 1200);

        vm.expectEmit(true, true, false, true, address(charter));
        emit Charter.BidRefunded(0, carol, bond);
        _bid(mallory, 63_000, bond * 2);

        assertEq(manager.balanceOf(carol, currency1.toId()), bond, "refunded as claims");
        assertEq(charter.pendingBid(0).bidder, mallory);
        assertEq(charter.totalEscrow(), bond * 2);
        _ledger();
    }

    function test_activateWaitsForTheDelayAndACleanBlock() public {
        vm.expectRevert(Charter.NoBid.selector);
        charter.activate(0);

        _bid(carol, 60_000, charter.minBond(UNITS));
        vm.expectRevert(Charter.NotReady.selector);
        charter.activate(0);

        _warp(AUCTION_DELAY);
        _nextBlock();
        _swapAs(mallory, true, -400e18);
        vm.expectRevert(Charter.NotReady.selector);
        charter.activate(0);

        _nextBlock();
        charter.activate(0);
        assertEq(charter.lease(0).manager, carol);
    }

    function test_takeoverHandsTheSlotOver() public {
        uint256 bond = charter.minBond(UNITS) * 2;
        _bid(carol, 60_000, bond);
        _ready();
        uint256 bobClaims = manager.balanceOf(bob, currency1.toId());

        vm.recordLogs();
        vm.prank(alice);
        charter.activate(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasLog(logs, Charter.LeaseEnded.selector), "old lease settled");
        assertTrue(_hasLog(logs, Charter.LeaseOpened.selector), "new lease opened");
        assertTrue(_hasLog(logs, Charter.TakenOver.selector));
        assertGt(manager.balanceOf(bob, currency1.toId()), bobClaims, "bob gets his bond back");

        Lease memory l = charter.lease(0);
        assertEq(l.manager, carol);
        assertEq(l.rentPips, 60_000);
        assertEq(l.bond, bond, "bond moved from escrow");
        assertEq(l.tickLower, -1200);
        assertEq(charter.totalEscrow(), 0);
        assertEq(charter.pendingBid(0).bidder, address(0));
        assertApproxEqRel(charter.leasedUnits(), UNITS, 1e15);
        _ledger();

        _warp(365 days);
        uint256 due = charter.rentDue(0);
        assertApproxEqRel(
            due, uint256(charter.lease(0).units) * 2 * 60_000 / 1e6, 1e12, "depositors earn the higher rent"
        );
    }

    function test_incumbentCanDefendTheSeat() public {
        _bid(carol, 60_000, charter.minBond(UNITS));
        uint256 bond = charter.minBond(UNITS);
        vm.prank(bob);
        charter.bid(0, UNITS, 63_000, bond, -600, 600);
        assertEq(manager.balanceOf(carol, currency1.toId()), charter.minBond(UNITS), "carol refunded");
        _ready();
        charter.activate(0);
        Lease memory l = charter.lease(0);
        assertEq(l.manager, bob);
        assertEq(l.rentPips, 63_000);
    }

    /// If the bond no longer covers the minimum at activation, the bid is refunded and the
    /// incumbent keeps the seat.
    function test_aBidThatStopsFittingLeavesTheIncumbentAlone() public {
        uint256 bond = charter.minBond(UNITS);
        _bid(carol, 60_000, bond);
        // a big move up raises what the leased units are worth, and with it the minimum bond
        for (uint256 i; i < 4; i++) {
            _nextBlock();
            _swapAs(mallory, false, -40e18);
        }
        _ready();
        assertGt(charter.minBond(UNITS), bond);
        address manager0 = charter.lease(0).manager;

        vm.expectEmit(true, true, false, false, address(charter));
        emit Charter.BidVoided(0, carol);
        charter.activate(0);
        assertEq(charter.lease(0).manager, manager0, "incumbent untouched");
        assertEq(manager.balanceOf(carol, currency1.toId()), bond, "carol refunded");
        assertEq(charter.totalEscrow(), 0);
        _ledger();
    }

    function test_takeoverAfterTheIncumbentWasLiquidated() public {
        _bid(carol, 60_000, charter.minBond(UNITS) * 3);
        for (uint256 i; i < 60 && charter.lease(0).manager == bob; i++) {
            _nextBlock();
            _swapAs(mallory, true, -15e18);
        }
        assertEq(charter.lease(0).manager, address(0), "bob was liquidated");
        _ready();
        vm.recordLogs();
        charter.activate(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(_hasLog(logs, Charter.LeaseEnded.selector), "nothing to end");
        assertEq(charter.lease(0).manager, carol);
        _ledger();
    }

    /// The slot changed hands after the bid: bob left and mallory took it at 10%. carol's 6% bid
    /// was placed against bob's 5% and must not displace the better-paying lease.
    function test_aStaleBidCannotDisplaceABetterPayingLease() public {
        uint256 bond = charter.minBond(UNITS);
        _bid(carol, 60_000, bond);
        vm.prank(bob);
        charter.exitLease(0);
        _nextBlock();
        uint256 mbond = charter.minBond(UNITS);
        vm.prank(mallory);
        charter.openLease(0, UNITS, 100_000, mbond, -600, 600);
        _ready();

        vm.expectEmit(true, true, false, false, address(charter));
        emit Charter.BidVoided(0, carol);
        charter.activate(0);
        assertEq(charter.lease(0).manager, mallory, "the 10% lease keeps the slot");
        assertEq(charter.lease(0).rentPips, 100_000);
        assertEq(manager.balanceOf(carol, currency1.toId()), bond, "carol refunded");
        _ledger();
    }

    function test_aDustSwapCannotStallATakeover() public {
        _bid(carol, 60_000, charter.minBond(UNITS));
        _ready();
        _swapAs(mallory, true, -1);
        charter.activate(0);
        assertEq(charter.lease(0).manager, carol);
    }
}
