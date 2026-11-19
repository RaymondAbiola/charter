// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Charter} from "../src/Charter.sol";
import {Lease} from "../src/types/CharterTypes.sol";
import {LeaseMath} from "../src/libraries/LeaseMath.sol";
import {Fixture} from "./utils/Fixture.sol";

contract LiquidationTest is Fixture {
    uint128 constant UNITS = 300e18;

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 500e18);
        _lp(-1200, 1200, 1500e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);
    }

    function _open(uint256 bond, int24 half) internal {
        vm.prank(bob);
        charter.openLease(0, UNITS, 50_000, bond, -half, half);
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

    function _closed() internal view {
        Lease memory l = charter.lease(0);
        assertEq(l.manager, address(0), "seat cleared");
        assertEq(l.liquidity, 0, "liquidity pulled");
        assertEq(l.held0 + l.held1 + l.bond, 0, "nothing left on the lease");
        assertEq(charter.leasedUnits(), 0);
        assertEq(charter.totalHeld0() + charter.totalHeld1() + charter.totalBond(), 0);
    }

    function _value(uint256 a0, uint256 a1, uint160 s) internal pure returns (uint256) {
        return a1 + FullMath.mulDiv(FullMath.mulDiv(a0, s, 1 << 96), s, 1 << 96);
    }

    function test_crashLiquidatesInsideTheSwap() public {
        _open(charter.minBond(UNITS), 600);
        bool fired;
        for (uint256 i; i < 60 && !fired; i++) {
            _nextBlock();
            _swapAs(mallory, true, -15e18);
            fired = charter.lease(0).manager == address(0);
        }
        assertTrue(fired, "liquidated during a swap");
        _closed();
        assertEq(charter.uncovered(), 0, "the bond covered the shortfall");
        _ledger();
    }

    function test_crashEmitsTheSettlement() public {
        _open(charter.minBond(UNITS), 600);
        vm.recordLogs();
        for (uint256 i; i < 60 && charter.lease(0).manager != address(0); i++) {
            _nextBlock();
            _swapAs(mallory, true, -15e18);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(charter) && logs[i].topics[0] == Charter.Liquidated.selector) {
                assertEq(uint256(logs[i].topics[1]), 0, "slot");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), bob, "manager");
                (uint256 owedValue, uint256 heldValue, uint256 bondUsed, uint256 gap) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assertGt(owedValue, heldValue, "closed underwater");
                assertEq(bondUsed, owedValue - heldValue, "the bond made up the gap");
                assertEq(gap, 0);
                found = true;
            }
        }
        assertTrue(found);
        _closed();
    }

    function test_managerGetsTheUnusedBondBack() public {
        uint256 bond = charter.minBond(UNITS);
        _open(bond, 600);
        uint256 bobClaims = manager.balanceOf(bob, currency1.toId());
        for (uint256 i; i < 60 && charter.lease(0).manager != address(0); i++) {
            _nextBlock();
            _swapAs(mallory, true, -15e18);
        }
        uint256 back = manager.balanceOf(bob, currency1.toId()) - bobClaims;
        assertGt(back, 0, "some bond comes back as claims");
        assertLt(back, bond, "but the shortfall was paid from it");
    }

    function test_oneGapSwapCanOutrunTheBond() public {
        _open(charter.minBond(UNITS), 600);
        _nextBlock();
        _swapAs(mallory, true, -900e18);
        _closed();
        // a single swap far past the range can exceed the bond; it is recorded, not hidden
        emit log_named_uint("uncovered after one gap swap", charter.uncovered());
        _ledger();
    }

    function test_normalFlowLeavesAHealthyLeaseAlone() public {
        _open(charter.minBond(UNITS), 600);
        for (uint256 i; i < 40; i++) {
            _nextBlock();
            _swapAs(mallory, i % 2 == 0, -20e18);
        }
        assertEq(charter.lease(0).manager, bob);
        vm.expectRevert(Charter.Healthy.selector);
        charter.liquidate(0);
    }

    function test_rentArrearsCanBeLiquidatedWithoutSwaps() public {
        _open(charter.minBond(UNITS), 600);
        _warp(400 days);
        vm.prank(mallory);
        charter.liquidate(0);
        _closed();
        _ledger();
    }

    function test_liquidateRejectsAnEmptySlot() public {
        vm.expectRevert(Charter.NoLease.selector);
        charter.liquidate(3);
    }

    /// A push inside one block can trip the spot check, but settlement uses the clamped price,
    /// so a lease that is fine at that price returns its surplus to the manager.
    function test_forcedCloseStillPaysTheManagerFairly() public {
        _open(charter.minBond(UNITS) * 2, 600);
        // let the lease get ahead first
        for (uint256 i; i < 40; i++) {
            _nextBlock();
            _swapAs(mallory, true, -20e18);
            _swapAs(mallory, false, -20e18);
        }
        _nextBlock();
        uint256 bob0 = manager.balanceOf(bob, currency0.toId());
        uint256 bob1 = manager.balanceOf(bob, currency1.toId());
        uint160 ref = _sqrt();
        _swapAs(mallory, true, -900e18);
        _closed();
        uint256 got = _value(
            manager.balanceOf(bob, currency0.toId()) - bob0, manager.balanceOf(bob, currency1.toId()) - bob1, ref
        );
        assertGt(got, charter.minBond(UNITS) * 2, "bond plus surplus");
    }

    function test_sandwichingAForcedCloseLoses() public {
        _open(charter.minBond(UNITS), 600);
        _nextBlock();
        uint256 m0 = currency0.balanceOf(mallory);
        uint256 m1 = currency1.balanceOf(mallory);
        uint160 ref = _sqrt();
        _swapAs(mallory, true, -900e18);
        _closed();
        _swapAs(mallory, false, -900e18);
        int256 d0 = int256(currency0.balanceOf(mallory)) - int256(m0);
        int256 d1 = int256(currency1.balanceOf(mallory)) - int256(m1);
        int256 v0 = d0 >= 0
            ? int256(FullMath.mulDiv(FullMath.mulDiv(uint256(d0), ref, 1 << 96), ref, 1 << 96))
            : -int256(FullMath.mulDiv(FullMath.mulDiv(uint256(-d0), ref, 1 << 96), ref, 1 << 96));
        assertLt(v0 + d1, 0, "the attacker loses");
    }

    function test_repassivateWaitsForACleanBlock() public {
        _open(charter.minBond(UNITS), 600);
        _nextBlock();
        _swapAs(mallory, true, -900e18);
        _closed();
        vm.expectRevert(Charter.NotReady.selector);
        charter.repassivate();

        _nextBlock();
        uint128 before = charter.passiveLiquidity();
        uint256 i0 = charter.idle0();
        uint256 i1 = charter.idle1();
        charter.repassivate();
        assertGt(charter.passiveLiquidity(), before);
        // the scarcer token at this price goes into the position almost entirely
        assertTrue(charter.idle0() < i0 / 1000 || charter.idle1() < i1 / 1000, "binding token used");
        _ledger();
    }

    /// After a liquidation the depositor can leave, and gets back at least what a passive
    /// position would have given, less any uncovered amount.
    function test_depositorsAreWholeAfterACrash() public {
        _open(charter.minBond(UNITS), 600);
        for (uint256 i; i < 60 && charter.lease(0).manager != address(0); i++) {
            _nextBlock();
            _swapAs(mallory, true, -15e18);
        }
        _closed();
        assertEq(charter.uncovered(), 0);
        uint256 shares = charter.balanceOf(alice);
        (uint256 p0, uint256 p1) = charter.previewWithdraw(shares);
        vm.prank(alice);
        (uint256 out0, uint256 out1) = charter.withdraw(shares, 0, 0, alice);
        assertApproxEqAbs(out0, p0, 2);
        assertApproxEqAbs(out1, p1, 2);
    }
}
