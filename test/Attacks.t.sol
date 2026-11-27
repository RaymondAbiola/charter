// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Fixture} from "./utils/Fixture.sol";

/// Each attack is judged by the attacker's own profit and loss, valued at a fixed reference price
/// and counting tokens, claims and Charter shares at what they would redeem for.
contract AttacksTest is Fixture {
    uint128 constant UNITS = 300e18;
    uint160 ref;

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 1000e18);
        _lp(-1200, 1200, 3000e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);
        ref = _sqrt();
    }

    function _open(int24 lo, int24 hi, uint256 bondMultiple) internal {
        uint256 bond = charter.minBond(UNITS) * bondMultiple;
        vm.prank(bob);
        charter.openLease(0, UNITS, 50_000, bond, lo, hi);
    }

    function _v(uint256 a0, uint256 a1) internal view returns (uint256) {
        return a1 + FullMath.mulDiv(FullMath.mulDiv(a0, ref, 1 << 96), ref, 1 << 96);
    }

    function _wealth(address who) internal view returns (uint256) {
        uint256 a0 = currency0.balanceOf(who) + manager.balanceOf(who, currency0.toId());
        uint256 a1 = currency1.balanceOf(who) + manager.balanceOf(who, currency1.toId());
        uint256 shares = charter.balanceOf(who);
        if (shares > 0) {
            (uint256 s0, uint256 s1) = charter.previewWithdraw(shares);
            a0 += s0;
            a1 += s1;
        }
        return _v(a0, a1);
    }

    // ------------------------------------------------------------------ attacks

    /// The manager trades against his own lease to farm its fee share. Fees he pays go partly to
    /// other LPs and partly into the passive debt he owes, so he cannot come out ahead.
    function test_washTradingByTheManagerLoses() public {
        uint256 before = _wealth(bob);
        _open(-600, 600, 2);
        for (uint256 i; i < 30; i++) {
            _nextBlock();
            _swapAs(bob, true, -20e18);
            _swapAs(bob, false, -20e18);
        }
        _nextBlock();
        vm.prank(bob);
        charter.exitLease(0);
        assertLt(_wealth(bob), before, "wash trading costs the manager");
    }

    /// A large depositor pushes the price to trip the liquidation check, hoping settlement moves
    /// part of the bond to depositors, then pushes back. Settlement is clamped, so it does not pay.
    function test_aDepositorCannotProfitFromForcingALiquidation() public {
        vm.prank(carol);
        charter.deposit(4000e18, type(uint256).max, type(uint256).max, carol);
        _open(-600, 600, 1);
        _nextBlock();
        uint256 before = _wealth(carol);
        _swapAs(carol, true, -1500e18);
        assertEq(charter.lease(0).manager, address(0), "forced out");
        _swapAs(carol, false, -1500e18);
        assertLt(_wealth(carol), before, "the push costs more than any bond it moves");
    }

    /// The manager pushes the price so his leased capital looks cheaper when rent is charged.
    /// The rent valuation is clamped to the block's opening price, so the saving is tiny and the
    /// push costs far more.
    function test_pushingThePriceToCutRentLoses() public {
        _open(-600, 600, 2);
        _warp(180 days);
        _nextBlock();
        uint256 snap = vm.snapshotState();
        uint256 honestRent = charter.collectRent(0);
        vm.revertToState(snap);

        uint256 before = _wealth(bob);
        // a push that moves the price past the clamp but stops well short of liquidating the lease
        _swapAs(bob, true, -300e18);
        assertEq(charter.lease(0).manager, bob, "still leased");
        assertTrue(charter.settlementSqrtPrice() != _sqrt(), "the push went past the clamp");
        uint256 cutRent = charter.collectRent(0);
        _swapAs(bob, false, -300e18);
        uint256 saved = honestRent > cutRent ? honestRent - cutRent : 0;
        assertLe(saved * 100, honestRent * 3, "the clamp keeps the saving under 3%");
        assertLt(_wealth(bob) + saved, before, "and the push costs more than it saves");
    }

    /// With an out-of-range lease owing fee debt, a withdrawer's share of that debt is paid as
    /// liquidity valued at the clamped price. Pushing the price first does not make it pay more.
    function test_pushingBeforeAWithdrawalDoesNotPay() public {
        _open(1200, 2400, 2);
        for (uint256 i; i < 30; i++) {
            _nextBlock();
            _swapAs(mallory, i % 2 == 0, -40e18);
        }
        vm.prank(carol);
        charter.deposit(500e18, type(uint256).max, type(uint256).max, carol);
        _nextBlock();
        uint256 shares = charter.balanceOf(carol);

        uint256 snap = vm.snapshotState();
        uint256 honestBefore = _wealth(carol);
        vm.prank(carol);
        charter.withdraw(shares, 0, 0, carol);
        int256 honest = int256(_wealth(carol)) - int256(honestBefore);
        vm.revertToState(snap);

        uint256 before = _wealth(carol);
        _swapAs(carol, false, -800e18);
        vm.prank(carol);
        charter.withdraw(shares, 0, 0, carol);
        _swapAs(carol, true, -800e18);
        int256 pushed = int256(_wealth(carol)) - int256(before);
        assertLt(pushed, honest, "pushing first leaves the withdrawer worse off");
    }

    /// An outsider sandwiches the manager's rebalance. Depositors are owed the same as before,
    /// and the sandwich does not pay: its round trip runs fees and inventory through the fresh range.
    function test_sandwichingARebalanceNeitherHurtsDepositorsNorPays() public {
        _open(-600, 600, 3);
        _nextBlock();
        (uint256 o0, uint256 o1) = charter.previewWithdraw(charter.balanceOf(alice));
        uint256 aliceBefore = _v(o0, o1);
        uint256 attackerBefore = _wealth(mallory);

        _swapAs(mallory, true, -600e18);
        vm.prank(bob);
        charter.rebalance(0, -600, 600);
        _swapAs(mallory, false, -600e18);
        _nextBlock();

        (o0, o1) = charter.previewWithdraw(charter.balanceOf(alice));
        assertGe(_v(o0, o1) * 1000, aliceBefore * 999, "depositors keep what they are owed");
        assertLt(_wealth(mallory), attackerBefore, "the sandwich loses");
    }

    /// Price games around a deposit while a lease is open, so the deposit also buys receivables.
    function test_pushingAroundADepositWithLeasesOpenLoses() public {
        _open(-600, 600, 2);
        for (uint256 i; i < 20; i++) {
            _nextBlock();
            _swapAs(mallory, i % 2 == 0, -25e18);
        }
        _warp(30 days);
        _nextBlock();
        (uint256 a0, uint256 a1) = charter.previewWithdraw(charter.balanceOf(alice));
        uint256 aliceBefore = _v(a0, a1);
        uint256 before = _wealth(carol);

        _swapAs(carol, true, -500e18);
        vm.prank(carol);
        charter.deposit(300e18, type(uint256).max, type(uint256).max, carol);
        _swapAs(carol, false, -500e18);
        uint256 half = charter.balanceOf(carol) / 2;
        vm.prank(carol);
        charter.withdraw(half, 0, 0, carol);

        assertLt(_wealth(carol), before, "the attacker loses");
        (a0, a1) = charter.previewWithdraw(charter.balanceOf(alice));
        assertGe(_v(a0, a1) * 1000, aliceBefore * 999, "alice is not diluted");
    }
}
