// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Charter} from "../src/Charter.sol";
import {Lease} from "../src/types/CharterTypes.sol";
import {LeaseMath} from "../src/libraries/LeaseMath.sol";
import {Fixture} from "./utils/Fixture.sol";

/// Withdrawals that need leased capital pull it back, cheapest rent first.
contract RecallTest is Fixture {
    uint128 constant UNITS = 300e18;

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 1000e18);
        _lp(-1200, 1200, 3000e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);
    }

    function _open(address who, uint256 slot, uint128 units, uint32 rent, int24 lo, int24 hi) internal {
        uint256 bond = charter.minBond(units) * 2;
        vm.prank(who);
        charter.openLease(slot, units, rent, bond, lo, hi);
    }

    function _v(uint256 a0, uint256 a1) internal view returns (uint256) {
        uint160 s = _sqrt();
        return a1 + FullMath.mulDiv(FullMath.mulDiv(a0, s, 1 << 96), s, 1 << 96);
    }

    function _redeemable(address who) internal view returns (uint256) {
        (uint256 a0, uint256 a1) = charter.previewWithdraw(charter.balanceOf(who));
        return _v(a0, a1);
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

    function _has(Vm.Log[] memory logs, bytes32 topic) internal view returns (bool) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(charter) && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    function test_aFullWithdrawalRecallsEverything() public {
        _open(bob, 0, UNITS, 50_000, -600, 600);
        _nextBlock();
        uint256 expected = _redeemable(alice);
        uint256 bobClaims = manager.balanceOf(bob, currency1.toId());
        uint256 shares = charter.balanceOf(alice);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 o0, uint256 o1) = charter.withdraw(shares, 0, 0, alice);
        assertTrue(_has(vm.getRecordedLogs(), Charter.LeaseEnded.selector), "the lease was closed");

        assertEq(charter.lease(0).manager, address(0));
        assertEq(charter.leasedUnits(), 0);
        assertApproxEqRel(_v(o0, o1), expected, 1e14, "alice gets what she was shown");
        assertGt(manager.balanceOf(bob, currency1.toId()), bobClaims, "bob gets his bond back");
        _ledger();
    }

    function test_aPartialRecallShrinksTheLease() public {
        vm.prank(carol);
        charter.deposit(100e18, type(uint256).max, type(uint256).max, carol);
        _open(bob, 0, UNITS, 50_000, -600, 600);
        _nextBlock();
        // passive is about 800 of 1100 units, so withdrawing 90% of alice's 1000 needs about 100 back
        uint256 shares = charter.balanceOf(alice) * 9 / 10;
        uint256 carolBefore = _redeemable(carol);
        Lease memory before = charter.lease(0);

        vm.recordLogs();
        vm.prank(alice);
        charter.withdraw(shares, 0, 0, alice);
        assertTrue(_has(vm.getRecordedLogs(), Charter.LeaseRecalled.selector));

        Lease memory l = charter.lease(0);
        assertEq(l.manager, bob, "the lease survives");
        assertLt(l.units, before.units, "smaller");
        assertGt(l.units, 0);
        assertLt(l.liquidity, before.liquidity);
        assertEq(charter.leasedUnits(), l.units);
        assertGe(_redeemable(carol) + 2, carolBefore, "carol is not diluted");
        _ledger();
    }

    function test_theCheapestRentIsRecalledFirst() public {
        _open(bob, 0, 200e18, 80_000, -600, 600);
        _open(carol, 1, 200e18, 40_000, -600, 600);
        _nextBlock();
        // needs about 100 leased units back
        uint256 shares = charter.balanceOf(alice) * 70 / 100;
        vm.prank(alice);
        charter.withdraw(shares, 0, 0, alice);
        assertEq(charter.lease(0).units, 200e18, "the 8% lease is untouched");
        assertLt(charter.lease(1).units, 200e18, "the 4% lease gave capital back");
    }

    function test_recallWaitsForAQuietPrice() public {
        _open(bob, 0, UNITS, 50_000, -600, 600);
        _nextBlock();
        _swapAs(mallory, true, -400e18);
        uint256 all = charter.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(Charter.NotReady.selector);
        charter.withdraw(all, 0, 0, alice);

        // a withdrawal that fits in passive capital does not need a recall
        vm.prank(alice);
        charter.withdraw(all / 10, 0, 0, alice);

        _nextBlock();
        uint256 rest = charter.balanceOf(alice);
        vm.prank(alice);
        charter.withdraw(rest, 0, 0, alice);
        assertEq(charter.leasedUnits(), 0);
    }

    /// After a drop the lease is behind passive, so its slice is worth less than the units owe.
    /// The bond makes up the difference.
    function test_aPoorSliceIsToppedUpFromTheBond() public {
        _open(bob, 0, UNITS, 50_000, -600, 600);
        for (uint256 i; i < 4; i++) {
            _nextBlock();
            _swapAs(mallory, true, -60e18);
        }
        _nextBlock();
        (LeaseMath.Account memory a,,,) = charter.leaseAccount(0);
        assertLt(a.heldValue, a.owedValue, "the lease is behind");
        uint256 bond = charter.lease(0).bond;
        uint256 shares = charter.balanceOf(alice) * 85 / 100;
        (uint256 p0, uint256 p1) = charter.previewWithdraw(shares);
        vm.prank(alice);
        (uint256 o0, uint256 o1) = charter.withdraw(shares, 0, 0, alice);
        assertApproxEqRel(_v(o0, o1), _v(p0, p1), 1e14, "alice gets the value she was shown");
        assertLt(charter.lease(0).bond, bond, "the bond paid the gap");
        assertEq(charter.uncovered(), 0);
        _ledger();
    }

    /// Shrinking settles the recalled units at exactly what they owe, so a manager who is ahead
    /// keeps all of the surplus earned so far: recall neither rewards nor punishes him.
    function test_shrinkingLeavesTheManagersEquityAlone() public {
        _open(bob, 0, UNITS, 0, -600, 600);
        for (uint256 i; i < 20; i++) {
            _nextBlock();
            _swapAs(mallory, true, -20e18);
            _swapAs(mallory, false, -20e18);
        }
        _nextBlock();
        (,,, int256 e0) = charter.leaseAccount(0);
        uint256 u0 = charter.lease(0).units;
        uint256 shares = charter.balanceOf(alice) * 85 / 100;
        vm.prank(alice);
        charter.withdraw(shares, 0, 0, alice);
        (,,, int256 e1) = charter.leaseAccount(0);
        assertLt(charter.lease(0).units, u0, "it did shrink");
        assertGt(e0, int256(charter.lease(0).bond), "the manager was ahead");
        assertApproxEqRel(e1, e0, 1e14, "and still has the same equity");
    }
}
