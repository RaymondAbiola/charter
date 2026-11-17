// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Charter} from "../src/Charter.sol";
import {Fixture} from "./utils/Fixture.sol";

contract DepositsTest is Fixture {
    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 1000e18);
        _lp(-600, 600, 2000e18);
    }

    function _deposit(address who, uint256 shares) internal returns (uint256 a0, uint256 a1) {
        vm.prank(who);
        (a0, a1) = charter.deposit(shares, type(uint256).max, type(uint256).max, who);
    }

    function _withdraw(address who, uint256 shares) internal returns (uint256 a0, uint256 a1) {
        vm.prank(who);
        (a0, a1) = charter.withdraw(shares, 0, 0, who);
    }

    function _ledgerMatches() internal view {
        assertEq(manager.balanceOf(address(charter), currency0.toId()), charter.idle0(), "claims0");
        assertEq(manager.balanceOf(address(charter), currency1.toId()), charter.idle1(), "claims1");
    }

    function _churn(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.roll(block.number + 1);
            _swapAs(mallory, i % 2 == 0, -20e18);
        }
    }

    function test_firstDepositLocksDeadShares() public {
        (uint256 a0, uint256 a1) = _deposit(alice, 100e18);
        assertEq(charter.balanceOf(alice), 100e18 - charter.DEAD_SHARES());
        assertEq(charter.totalSupply(), 100e18);
        assertEq(charter.passiveLiquidity(), 100e18);
        // full range at 1:1 holds about L of each token
        assertApproxEqRel(a0, 100e18, 1e12);
        assertApproxEqRel(a1, 100e18, 1e12);
        _ledgerMatches();
    }

    function test_secondDepositMatchesPreview() public {
        _deposit(alice, 100e18);
        _churn(10);
        (uint256 p0, uint256 p1) = charter.previewDeposit(50e18);
        (uint256 a0, uint256 a1) = _deposit(bob, 50e18);
        assertApproxEqAbs(a0, p0, 2);
        assertApproxEqAbs(a1, p1, 2);
        assertEq(charter.balanceOf(bob), 50e18);
        _ledgerMatches();
    }

    function test_withdrawPaysFeesEarned() public {
        (uint256 in0, uint256 in1) = _deposit(alice, 100e18);
        _churn(30);
        uint256 shares = charter.balanceOf(alice);
        (uint256 p0, uint256 p1) = charter.previewWithdraw(shares);
        (uint256 out0, uint256 out1) = _withdraw(alice, shares);
        assertApproxEqAbs(out0, p0, 2);
        assertApproxEqAbs(out1, p1, 2);
        // round trips at the same price leave the deposit whole plus fees
        uint160 s = _sqrt();
        assertGt(_value(out0, out1, s), _value(in0, in1, s) * (100e18 - charter.DEAD_SHARES()) / 100e18);
        _ledgerMatches();
    }

    function test_withdrawIsProRata() public {
        _deposit(alice, 100e18);
        _deposit(bob, 300e18);
        _churn(20);
        (uint256 a0, uint256 a1) = _withdraw(alice, charter.balanceOf(alice));
        (uint256 b0, uint256 b1) = _withdraw(bob, charter.balanceOf(bob));
        // bob holds 3x alice's shares (less alice's dead-share haircut)
        uint256 ratio = 300e18 * 1e18 / (100e18 - charter.DEAD_SHARES());
        assertApproxEqRel(b0 * 1e18 / a0, ratio, 1e12);
        assertApproxEqRel(b1 * 1e18 / a1, ratio, 1e12);
        _ledgerMatches();
    }

    function test_slippageGuards() public {
        _deposit(alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(Charter.Slippage.selector);
        charter.deposit(10e18, 1, type(uint256).max, bob);

        uint256 shares = charter.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(Charter.Slippage.selector);
        charter.withdraw(shares, type(uint256).max, 0, alice);
    }

    function test_cannotWithdrawOthersShares() public {
        _deposit(alice, 100e18);
        vm.prank(mallory);
        vm.expectRevert();
        charter.withdraw(10e18, 0, 0, mallory);
    }

    function test_sharesAreTransferable() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        charter.transfer(carol, 40e18);
        (uint256 c0, uint256 c1) = _withdraw(carol, 40e18);
        assertGt(c0, 0);
        assertGt(c1, 0);
        _ledgerMatches();
    }

    function test_rejectsTinyFirstDeposit() public {
        uint256 dead = charter.DEAD_SHARES();
        vm.prank(alice);
        vm.expectRevert(Charter.ZeroShares.selector);
        charter.deposit(dead, type(uint256).max, type(uint256).max, alice);
    }

    /// Push the price, deposit, push it back, withdraw: shares are a slice of the bundle, so
    /// the attacker gets back no more than the slice they paid for, and alice loses nothing.
    function test_priceManipulationAroundDepositDoesNotPay() public {
        _deposit(alice, 100e18);
        _churn(5);
        uint256 aliceShares = charter.balanceOf(alice);
        (uint256 before0, uint256 before1) = charter.previewWithdraw(aliceShares);
        uint160 ref = _sqrt();

        uint256 m0 = currency0.balanceOf(mallory);
        uint256 m1 = currency1.balanceOf(mallory);
        _swapAs(mallory, true, -500e18);
        _deposit(mallory, 100e18);
        _swapAs(mallory, false, -500e18);
        _withdraw(mallory, charter.balanceOf(mallory));
        int256 pnl = _signedValue(int256(currency0.balanceOf(mallory)) - int256(m0), int256(currency1.balanceOf(mallory)) - int256(m1), ref);
        assertLt(pnl, 0, "attacker loses");

        (uint256 after0, uint256 after1) = charter.previewWithdraw(aliceShares);
        assertGe(_value(after0, after1, _sqrt()), _value(before0, before1, _sqrt()), "alice not diluted");
        _ledgerMatches();
    }

    function testFuzz_roundTripNeverGainsWithoutSwaps(uint96 seed, uint96 size) public {
        _deposit(alice, 100e18 + uint256(seed) % 1e21);
        uint256 shares = 1e15 + uint256(size) % 1e21;
        uint256 b0 = currency0.balanceOf(bob);
        uint256 b1 = currency1.balanceOf(bob);
        _deposit(bob, shares);
        _withdraw(bob, shares);
        assertLe(currency0.balanceOf(bob), b0);
        assertLe(currency1.balanceOf(bob), b1);
        _ledgerMatches();
    }

    function _value(uint256 a0, uint256 a1, uint160 s) internal pure returns (uint256) {
        return a1 + FullMath.mulDiv(FullMath.mulDiv(a0, s, 2 ** 96), s, 2 ** 96);
    }

    function _signedValue(int256 d0, int256 d1, uint160 s) internal pure returns (int256) {
        int256 v0 = d0 >= 0
            ? int256(FullMath.mulDiv(FullMath.mulDiv(uint256(d0), s, 2 ** 96), s, 2 ** 96))
            : -int256(FullMath.mulDiv(FullMath.mulDiv(uint256(-d0), s, 2 ** 96), s, 2 ** 96));
        return v0 + d1;
    }
}
