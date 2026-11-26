// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {VaultLogic} from "../src/libraries/VaultLogic.sol";
import {Lease} from "../src/types/CharterTypes.sol";
import {Fixture} from "./utils/Fixture.sol";

/// Depositors come and go while a lease is running.
contract LeasedDepositsTest is Fixture {
    uint128 constant UNITS = 300e18;

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 500e18);
        _lp(-1200, 1200, 1500e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);
    }

    function _open(int24 lo, int24 hi) internal {
        uint256 bond = charter.minBond(UNITS) * 2;
        vm.prank(bob);
        charter.openLease(0, UNITS, 50_000, bond, lo, hi);
    }

    function _trade(uint256 rounds) internal {
        for (uint256 i; i < rounds; i++) {
            _nextBlock();
            _swapAs(mallory, i % 2 == 0, -25e18);
        }
        _warp(30 days);
        _nextBlock();
    }

    function _value(uint256 a0, uint256 a1) internal view returns (uint256) {
        uint160 s = _sqrt();
        return a1 + FullMath.mulDiv(FullMath.mulDiv(a0, s, 1 << 96), s, 1 << 96);
    }

    function _totalValue() internal view returns (uint256) {
        (uint256 a0, uint256 a1) = charter.previewWithdraw(charter.totalSupply());
        return _value(a0, a1);
    }

    function _redeemable(address who) internal view returns (uint256) {
        (uint256 a0, uint256 a1) = charter.previewWithdraw(charter.balanceOf(who));
        return _value(a0, a1);
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

    function test_aNewcomerDoesNotDiluteExistingDepositors() public {
        _open(-600, 600);
        _trade(20);
        uint256 aliceBefore = _redeemable(alice);

        (uint256 p0, uint256 p1) = charter.previewDeposit(200e18);
        vm.prank(carol);
        (uint256 a0, uint256 a1) = charter.deposit(200e18, type(uint256).max, type(uint256).max, carol);
        assertApproxEqRel(a0, p0, 1e12);
        assertApproxEqRel(a1, p1, 1e12);

        assertGe(_redeemable(alice) + 2, aliceBefore, "alice is not diluted");
        assertApproxEqRel(_redeemable(carol), _value(a0, a1), 1e14, "carol gets what she paid for");
        _ledger();
    }

    function test_settlingMovesFeeDebtAndRentIntoIdleWithoutTouchingEquity() public {
        _open(-600, 600);
        _trade(20);
        (,,, int256 equityBefore) = charter.leaseAccount(0);
        uint256 idle1 = charter.idle1();
        Lease memory before = charter.lease(0);

        vm.prank(carol);
        charter.deposit(1e18, type(uint256).max, type(uint256).max, carol);

        Lease memory l = charter.lease(0);
        assertTrue(l.growth0Start != before.growth0Start || l.growth1Start != before.growth1Start, "debt paid down");
        assertLt(l.bond, before.bond, "rent collected");
        assertGt(charter.idle1(), idle1);
        (,,, int256 equityAfter) = charter.leaseAccount(0);
        assertApproxEqRel(equityAfter, equityBefore, 1e12, "equity unchanged by settling");
        _ledger();
    }

    function test_aPartialWithdrawalIsAFairSlice() public {
        _open(-600, 600);
        _trade(20);
        uint256 shares = charter.balanceOf(alice) * 3 / 10;
        vm.prank(carol);
        charter.deposit(500e18, type(uint256).max, type(uint256).max, carol);
        uint256 carolBefore = _redeemable(carol);
        uint256 total = _totalValue();

        vm.prank(alice);
        (uint256 o0, uint256 o1) = charter.withdraw(shares, 0, 0, alice);
        assertApproxEqRel(_value(o0, o1), total * shares / (charter.totalSupply() + shares), 1e14);
        assertGe(_redeemable(carol) + 2, carolBefore, "those who stay keep their value");
        _ledger();
    }

    function test_leasedCapitalCannotLeaveYet() public {
        _open(-600, 600);
        uint256 shares = charter.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(VaultLogic.NotEnoughPassive.selector);
        charter.withdraw(shares, 0, 0, alice);
        // the unleased part can
        vm.prank(alice);
        charter.withdraw(shares / 2, 0, 0, alice);
    }

    /// An out-of-range lease earns no fees, so it cannot pay its fee debt from what it holds. The
    /// withdrawer's share of that debt then comes out of passive liquidity, at the same value.
    function test_unpaidDebtIsPaidAsLiquidityAtTheSameValue() public {
        _open(1200, 2400);
        for (uint256 i; i < 30; i++) {
            _nextBlock();
            _swapAs(mallory, i % 2 == 0, -40e18);
        }
        _nextBlock();
        uint256 shares = charter.balanceOf(alice) / 4;
        uint256 total = _totalValue();
        uint256 supply = charter.totalSupply();
        vm.prank(alice);
        (uint256 o0, uint256 o1) = charter.withdraw(shares, 0, 0, alice);
        assertApproxEqRel(_value(o0, o1), total * shares / supply, 1e14);
        _ledger();
    }

    function testFuzz_othersComingAndGoingNeverCostAnObserver(uint256 seed) public {
        _open(-600, 600);
        uint256 observer = _redeemableAfterSettle(alice);
        address[2] memory who = [carol, mallory];
        for (uint256 i; i < 6; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _nextBlock();
            address w = who[r % 2];
            uint256 held = charter.balanceOf(w);
            if (held > 0 && (r >> 8) % 2 == 0) {
                vm.prank(w);
                charter.withdraw(held / 2 + 1, 0, 0, w);
            } else {
                vm.prank(w);
                charter.deposit(1e18 + (r >> 16) % 200e18, type(uint256).max, type(uint256).max, w);
            }
            uint256 now_ = _redeemable(alice);
            assertGe(now_ + 4, observer, "observer never pays for others");
            observer = now_;
        }
        _ledger();
    }

    function _redeemableAfterSettle(address who) internal returns (uint256) {
        // a zero-size poke is not allowed, so settle with a dust deposit that the observer ignores
        vm.prank(mallory);
        charter.deposit(1e6, type(uint256).max, type(uint256).max, mallory);
        return _redeemable(who);
    }
}
