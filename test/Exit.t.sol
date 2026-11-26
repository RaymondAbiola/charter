// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Charter} from "../src/Charter.sol";
import {Lease} from "../src/types/CharterTypes.sol";
import {LeaseMath} from "../src/libraries/LeaseMath.sol";
import {Fixture} from "./utils/Fixture.sol";

contract ExitTest is Fixture {
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

    function _value(uint256 a0, uint256 a1, uint160 s) internal pure returns (uint256) {
        return a1 + FullMath.mulDiv(FullMath.mulDiv(a0, s, 1 << 96), s, 1 << 96);
    }

    function _bobClaims() internal view returns (uint256, uint256) {
        return (manager.balanceOf(bob, currency0.toId()), manager.balanceOf(bob, currency1.toId()));
    }

    /// Everything all shares could redeem, valued at `s`. An exit should not change it: before,
    /// depositors hold a claim worth what the lease owes; after, they hold the payment.
    function _depositorValue(uint160 s) internal view returns (uint256) {
        (uint256 a0, uint256 a1) = charter.previewWithdraw(charter.totalSupply());
        return _value(a0, a1, s);
    }

    function _ledger() internal view {
        assertEq(
            manager.balanceOf(address(charter), currency0.toId()), charter.idle0() + charter.totalHeld0(), "claims0"
        );
        assertEq(
            manager.balanceOf(address(charter), currency1.toId()),
            charter.idle1() + charter.totalHeld1() + charter.totalBond(),
            "claims1"
        );
    }

    function test_profitableExitKeepsTheSurplus() public {
        for (uint256 i; i < 40; i++) {
            _nextBlock();
            _swapAs(mallory, true, -20e18);
            _swapAs(mallory, false, -20e18);
        }
        _nextBlock();
        (LeaseMath.Account memory a, uint256 bond, uint256 rent, int256 equity) = charter.leaseAccount(0);
        assertGt(equity, int256(bond), "ahead of passive");
        uint160 s = charter.settlementSqrtPrice();
        uint256 before = _depositorValue(s);
        (uint256 b0, uint256 b1) = _bobClaims();

        vm.recordLogs();
        vm.prank(bob);
        charter.exitLease(0);

        (uint256 c0, uint256 c1) = _bobClaims();
        uint256 toBob = _value(c0 - b0, c1 - b1, s);
        assertApproxEqRel(toBob, uint256(equity), 1e14, "manager leaves with bond plus surplus");
        assertGt(a.owedValue + rent, 0);
        assertApproxEqRel(_depositorValue(s), before, 1e14, "depositors were owed exactly what they got");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(charter) && logs[i].topics[0] == Charter.LeaseEnded.selector) found = true;
        }
        assertTrue(found, "LeaseEnded emitted");
        assertEq(charter.lease(0).manager, address(0));
        assertEq(charter.leasedUnits(), 0);
        _ledger();
    }

    function test_losingExitPaysFromTheBond() public {
        for (uint256 i; i < 6; i++) {
            _nextBlock();
            _swapAs(mallory, true, -15e18);
        }
        _nextBlock();
        (LeaseMath.Account memory a, uint256 bond,, int256 equity) = charter.leaseAccount(0);
        assertLt(a.heldValue, a.owedValue, "behind passive");
        assertGt(equity, 0);
        (uint256 b0, uint256 b1) = _bobClaims();
        vm.prank(bob);
        charter.exitLease(0);
        (uint256 c0, uint256 c1) = _bobClaims();
        assertEq(c0, b0, "nothing held left over for the manager");
        assertLt(c1 - b1, bond, "the shortfall came out of the bond");
        assertApproxEqRel(c1 - b1, uint256(equity), 1e14);
        assertEq(charter.uncovered(), 0);
        _ledger();
    }

    function test_onlyTheManagerCanExit() public {
        vm.prank(mallory);
        vm.expectRevert(Charter.NotManager.selector);
        charter.exitLease(0);
        vm.prank(bob);
        vm.expectRevert(Charter.NotManager.selector);
        charter.exitLease(1);
    }

    function test_exitCollectsRentFirst() public {
        _warp(90 days);
        uint256 due = charter.rentDue(0);
        assertGt(due, 0);
        vm.recordLogs();
        vm.prank(bob);
        charter.exitLease(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paid;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(charter) && logs[i].topics[0] == Charter.RentPaid.selector) {
                paid = abi.decode(logs[i].data, (uint256));
            }
        }
        assertEq(paid, due);
    }

    /// Pushing the price in the exit block moves the settlement at most to the clamp, and the push
    /// itself costs more than that.
    function test_pushingBeforeExitDoesNotPay() public {
        _nextBlock();
        uint160 ref = _sqrt();
        uint256 snap = vm.snapshotState();

        (uint256 b0, uint256 b1) = _bobClaims();
        uint256 t0 = currency0.balanceOf(bob);
        uint256 t1 = currency1.balanceOf(bob);
        vm.prank(bob);
        charter.exitLease(0);
        int256 honest = _pnl(b0, b1, t0, t1, ref);
        vm.revertToState(snap);

        (b0, b1) = _bobClaims();
        t0 = currency0.balanceOf(bob);
        t1 = currency1.balanceOf(bob);
        _swapAs(bob, false, -300e18);
        vm.prank(bob);
        charter.exitLease(0);
        _swapAs(bob, true, -300e18);
        int256 pushed = _pnl(b0, b1, t0, t1, ref);
        assertLt(pushed, honest);
    }

    function _pnl(uint256 b0, uint256 b1, uint256 t0, uint256 t1, uint160 s) internal view returns (int256) {
        (uint256 c0, uint256 c1) = _bobClaims();
        int256 d0 = int256(c0 + currency0.balanceOf(bob)) - int256(b0 + t0);
        int256 d1 = int256(c1 + currency1.balanceOf(bob)) - int256(b1 + t1);
        int256 v0 = d0 >= 0
            ? int256(FullMath.mulDiv(FullMath.mulDiv(uint256(d0), s, 1 << 96), s, 1 << 96))
            : -int256(FullMath.mulDiv(FullMath.mulDiv(uint256(-d0), s, 1 << 96), s, 1 << 96));
        return v0 + d1;
    }

    function test_depositsWorkBeforeAndAfterAnExit() public {
        vm.prank(carol);
        charter.deposit(1e18, type(uint256).max, type(uint256).max, carol);
        vm.prank(bob);
        charter.exitLease(0);
        vm.prank(carol);
        charter.deposit(1e18, type(uint256).max, type(uint256).max, carol);
        assertEq(charter.balanceOf(carol), 2e18);
    }
}
