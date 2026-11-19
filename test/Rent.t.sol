// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Charter} from "../src/Charter.sol";
import {Lease} from "../src/types/CharterTypes.sol";
import {LeaseMath} from "../src/libraries/LeaseMath.sol";
import {Fixture} from "./utils/Fixture.sol";

contract RentTest is Fixture {
    uint128 constant UNITS = 300e18;
    uint32 constant RENT = 50_000; // 5% a year

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 500e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);
    }

    function _open(uint32 rent, uint256 bond) internal {
        vm.prank(bob);
        charter.openLease(0, UNITS, rent, bond, -600, 600);
    }

    function _ledger() internal view {
        assertEq(
            manager.balanceOf(address(charter), currency1.toId()),
            charter.idle1() + charter.totalHeld1() + charter.totalBond(),
            "claims1"
        );
    }

    // full range at 1:1 holds about L of each token, so the leased value is about 2 * UNITS
    function _yearly() internal pure returns (uint256) {
        return uint256(UNITS) * 2 * RENT / 1e6;
    }

    function test_rentAccruesWithTime() public {
        _open(RENT, charter.minBond(UNITS));
        assertEq(charter.rentDue(0), 0);
        _warp(30 days);
        assertApproxEqRel(charter.rentDue(0), _yearly() * 30 / 365, 1e12);
        _warp(30 days);
        assertApproxEqRel(charter.rentDue(0), _yearly() * 60 / 365, 1e12);
    }

    function test_collectMovesRentFromBondToDepositors() public {
        _open(RENT, charter.minBond(UNITS));
        uint256 bond = charter.lease(0).bond;
        uint256 idle = charter.idle1();
        _warp(90 days);
        uint256 due = charter.rentDue(0);

        vm.expectEmit(true, false, false, true, address(charter));
        emit Charter.RentPaid(0, due);
        vm.prank(mallory);
        uint256 paid = charter.collectRent(0);

        assertEq(paid, due);
        assertEq(charter.lease(0).bond, bond - due);
        assertEq(charter.idle1(), idle + due, "rent reaches depositor idle");
        assertEq(charter.rentDue(0), 0);
        _ledger();
        assertEq(charter.collectRent(0), 0, "nothing left to collect this second");
    }

    function test_pokingEveryBlockPaysTheSameRent() public {
        _open(RENT, charter.minBond(UNITS));
        uint256 snap = vm.snapshotState();
        _warp(1 days);
        uint256 once = charter.collectRent(0);
        vm.revertToState(snap);

        uint256 total;
        for (uint256 i; i < 7200; i++) {
            _warp(12);
            total += charter.collectRent(0);
        }
        assertApproxEqAbs(total, once, 1);
    }

    /// Rent on a small lease rounds to zero every block. Poking every block must not erase it.
    function test_dustRentIsNotLostToPoking() public {
        uint128 tiny = 1e7;
        uint256 bond = charter.minBond(tiny);
        vm.prank(bob);
        charter.openLease(0, tiny, RENT, bond, -600, 600);

        uint256 snap = vm.snapshotState();
        _warp(1 days);
        uint256 once = charter.collectRent(0);
        assertGt(once, 0);
        vm.revertToState(snap);

        uint256 total;
        for (uint256 i; i < 7200; i++) {
            _warp(12);
            total += charter.collectRent(0);
        }
        assertApproxEqAbs(total, once, 1);
    }

    function test_unpaidRentStaysDueWhenTheBondRunsOut() public {
        uint256 bond = charter.minBond(UNITS);
        _open(RENT, bond);
        // a 5% bond against 5% a year lasts about a year
        _warp(730 days);
        uint256 due = charter.rentDue(0);
        uint256 paid = charter.collectRent(0);
        assertEq(paid, bond, "the whole bond goes to depositors");
        assertEq(charter.lease(0).bond, 0);
        assertApproxEqRel(charter.rentDue(0), due - paid, 1e12, "the rest stays due");
        _ledger();
    }

    function test_equityCountsUnpaidRent() public {
        _open(RENT, charter.minBond(UNITS));
        (,,, int256 e0) = charter.leaseAccount(0);
        _warp(180 days);
        (LeaseMath.Account memory a, uint256 bond, uint256 rent, int256 e1) = charter.leaseAccount(0);
        assertGt(rent, 0);
        assertEq(e1, int256(bond + a.heldValue) - int256(a.owedValue) - int256(rent));
        assertApproxEqAbs(e0 - e1, int256(rent), 1e9);
    }

    function test_rebalanceCollectsRentFirst() public {
        _open(RENT, charter.minBond(UNITS));
        _warp(60 days);
        uint256 due = charter.rentDue(0);
        uint256 idle = charter.idle1();
        vm.prank(bob);
        charter.rebalance(0, -1200, 1200);
        assertEq(charter.rentDue(0), 0);
        assertEq(charter.idle1(), idle + due);
    }

    function test_zeroRentLeasePaysNothing() public {
        _open(0, charter.minBond(UNITS));
        _warp(365 days);
        assertEq(charter.rentDue(0), 0);
        assertEq(charter.collectRent(0), 0);
    }

    function test_rentScalesWithLeasedValue() public {
        _open(RENT, charter.minBond(UNITS));
        uint256 bond = charter.minBond(2 * UNITS);
        vm.prank(carol);
        charter.openLease(1, 2 * UNITS, RENT, bond, -600, 600);
        _warp(100 days);
        assertApproxEqRel(charter.rentDue(1), 2 * charter.rentDue(0), 1e12);
    }

    function test_collectOnEmptySlotReverts() public {
        vm.expectRevert(Charter.NoLease.selector);
        charter.collectRent(2);
    }
}
