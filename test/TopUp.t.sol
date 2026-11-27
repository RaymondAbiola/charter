// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Charter} from "../src/Charter.sol";
import {LeaseMath} from "../src/libraries/LeaseMath.sol";
import {Fixture} from "./utils/Fixture.sol";

contract TopUpTest is Fixture {
    uint128 constant UNITS = 300e18;

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 500e18);
        _lp(-1200, 1200, 1500e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);
        uint256 bond = charter.minBond(UNITS);
        vm.prank(bob);
        charter.openLease(0, UNITS, 50_000, bond, -600, 600);
    }

    function _ledger() internal view {
        assertEq(
            manager.balanceOf(address(charter), currency1.toId()),
            charter.idle1() + charter.totalHeld1() + charter.totalBond() + charter.totalEscrow(),
            "claims1"
        );
    }

    function test_topUpRaisesBondAndEquity() public {
        (,,, int256 e0) = charter.leaseAccount(0);
        uint256 bond = charter.lease(0).bond;
        uint256 paid = currency1.balanceOf(bob);

        vm.expectEmit(true, false, false, true, address(charter));
        emit Charter.BondToppedUp(0, 20e18);
        vm.prank(bob);
        charter.topUpBond(0, 20e18);

        assertEq(charter.lease(0).bond, bond + 20e18);
        assertEq(paid - currency1.balanceOf(bob), 20e18, "pulled from the manager");
        (,,, int256 e1) = charter.leaseAccount(0);
        assertEq(e1 - e0, 20e18);
        _ledger();
    }

    function test_onlyTheManagerAndNotZero() public {
        vm.prank(mallory);
        vm.expectRevert(Charter.NotManager.selector);
        charter.topUpBond(0, 1e18);
        vm.prank(bob);
        vm.expectRevert(Charter.ZeroAmount.selector);
        charter.topUpBond(0, 0);
        vm.prank(bob);
        vm.expectRevert(Charter.NotManager.selector);
        charter.topUpBond(1, 1e18);
    }

    function test_topUpClearsTheGuard() public {
        _nextBlock();
        _swapAs(mallory, true, -1e15);
        assertGt(charter.guard(0).validUntil, 0, "armed");
        vm.prank(bob);
        charter.topUpBond(0, 1e18);
        assertEq(charter.guard(0).validUntil, 0, "cleared");
    }

    /// From the same state, the same swap liquidates the lease unless the manager tops up first.
    function test_aTopUpRescuesALeaseFromLiquidation() public {
        // walk the price down until the lease is close to its margin
        for (uint256 i; i < 60; i++) {
            (LeaseMath.Account memory a,,, int256 equity) = charter.leaseAccount(0);
            if (equity < int256(a.owedValue * 250 / 10_000)) break;
            _nextBlock();
            _swapAs(mallory, true, -10e18);
        }
        assertEq(charter.lease(0).manager, bob, "still alive, but close");
        _nextBlock();
        uint256 snap = vm.snapshotState();

        _swapAs(mallory, true, -60e18);
        assertEq(charter.lease(0).manager, address(0), "without a top-up, liquidated");
        vm.revertToState(snap);

        uint256 extra = charter.minBond(UNITS);
        vm.prank(bob);
        charter.topUpBond(0, extra);
        _swapAs(mallory, true, -60e18);
        assertEq(charter.lease(0).manager, bob, "with a top-up, the lease survives");
        _ledger();
    }
}
