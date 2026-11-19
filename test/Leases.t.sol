// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Charter} from "../src/Charter.sol";
import {Lease} from "../src/types/CharterTypes.sol";
import {PassiveMath} from "../src/libraries/PassiveMath.sol";
import {Fixture} from "./utils/Fixture.sol";

contract LeasesTest is Fixture {
    using PoolIdLibrary for PoolKey;

    uint256 constant Q128 = 1 << 128;
    uint32 constant RENT = 50_000; // 5% a year

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 500e18);
        _lp(-1200, 1200, 1500e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);
    }

    function _open(address who, uint256 slot, uint128 units, int24 lo, int24 hi) internal {
        uint256 bond = charter.minBond(units);
        vm.prank(who);
        charter.openLease(slot, units, RENT, bond, lo, hi);
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

    function _positionLiquidity(int24 lo, int24 hi, uint256 slot) internal view returns (uint128) {
        return StateLibrary.getPositionLiquidity(
            manager, key.toId(), keccak256(abi.encodePacked(address(charter), lo, hi, bytes32(slot + 1)))
        );
    }

    // ------------------------------------------------------------------ opening

    function test_openMovesCapitalIntoAManagedRange() public {
        uint256 bond = charter.minBond(300e18);
        uint256 bobBefore = currency1.balanceOf(bob);
        vm.prank(bob);
        charter.openLease(0, 300e18, RENT, bond, -600, 600);

        assertEq(charter.passiveLiquidity(), 700e18);
        assertEq(charter.leasedUnits(), 300e18);
        assertEq(charter.totalBond(), bond);
        assertEq(bobBefore - currency1.balanceOf(bob), bond, "bond pulled from the manager");

        Lease memory l = charter.lease(0);
        assertEq(l.manager, bob);
        assertEq(l.units, 300e18);
        assertEq(l.rentPips, RENT);
        assertEq(l.bond, bond);
        assertEq(l.tickLower, -600);
        assertEq(l.tickUpper, 600);
        assertGt(l.liquidity, 10 * uint256(l.units), "concentrated");
        assertEq(_positionLiquidity(-600, 600, 0), l.liquidity, "position lives at the lease salt");
        _ledger();
    }

    function test_bondIsFivePercentOfLeasedValue() public view {
        // full range at 1:1 holds about L of each token, so value is about 2L
        assertApproxEqRel(charter.minBond(300e18), uint256(600e18) * MIN_BOND_BPS / 10_000, 1e12);
    }

    function test_openRejections() public {
        uint256 bond = charter.minBond(100e18);
        vm.startPrank(bob);
        vm.expectRevert(Charter.BadSlot.selector);
        charter.openLease(MAX_LEASES, 100e18, RENT, bond, -600, 600);
        vm.expectRevert(Charter.NotEnoughCapital.selector);
        charter.openLease(0, 0, RENT, bond, -600, 600);
        vm.expectRevert(Charter.NotEnoughCapital.selector);
        charter.openLease(0, 1001e18, RENT, type(uint128).max, -600, 600);
        vm.expectRevert(Charter.BadRange.selector);
        charter.openLease(0, 100e18, RENT, bond, -590, 600);
        vm.expectRevert(Charter.BadRange.selector);
        charter.openLease(0, 100e18, RENT, bond, 600, -600);
        vm.expectRevert(Charter.BadRange.selector);
        charter.openLease(0, 100e18, RENT, bond, FL - SPACING, 600);
        vm.expectRevert(Charter.BondTooSmall.selector);
        charter.openLease(0, 100e18, RENT, bond - 1, -600, 600);
        charter.openLease(0, 100e18, RENT, bond, -600, 600);
        vm.stopPrank();

        vm.prank(carol);
        vm.expectRevert(Charter.SlotTaken.selector);
        charter.openLease(0, 100e18, RENT, bond, -600, 600);
    }

    function test_slotsFillUpToTheLimit() public {
        address[4] memory managers = [bob, carol, mallory, alice];
        for (uint256 i; i < MAX_LEASES; i++) {
            _open(managers[i], i, 100e18, -600 - int24(int256(i)) * SPACING, 600);
        }
        assertEq(charter.leasedUnits(), 400e18);
        _ledger();
    }

    function test_depositsPausedWhileLeased() public {
        _open(bob, 0, 300e18, -600, 600);
        vm.prank(carol);
        vm.expectRevert(Charter.LeasesActive.selector);
        charter.deposit(1e18, type(uint256).max, type(uint256).max, carol);
        vm.prank(alice);
        vm.expectRevert(Charter.LeasesActive.selector);
        charter.withdraw(1e18, 0, 0, alice);
    }

    // ------------------------------------------------------------------ rebalancing

    function test_rebalanceMovesTheRangeAndKeepsFees() public {
        _open(bob, 0, 300e18, -600, 600);
        for (uint256 i; i < 20; i++) {
            _nextBlock();
            _swapAs(mallory, i % 2 == 0, -30e18);
        }
        Lease memory before = charter.lease(0);
        (uint256 fee0, uint256 fee1) = _pendingLeaseFees(-600, 600, 0);
        assertGt(fee0 + fee1, 0, "the lease earned fees");
        uint256 idle0 = charter.idle0();
        uint256 idle1 = charter.idle1();

        vm.prank(carol);
        vm.expectRevert(Charter.NotManager.selector);
        charter.rebalance(0, -1200, 1200);

        vm.prank(bob);
        charter.rebalance(0, -1200, 1200);
        Lease memory l = charter.lease(0);
        assertEq(charter.idle0(), idle0, "lease fees never reach depositor idle");
        assertEq(charter.idle1(), idle1);
        assertEq(l.tickLower, -1200);
        assertEq(l.tickUpper, 1200);
        assertEq(_positionLiquidity(-600, 600, 0), 0, "old range closed");
        assertEq(_positionLiquidity(-1200, 1200, 0), l.liquidity);
        assertLt(l.liquidity, before.liquidity, "wider range, less liquidity per unit");
        assertEq(l.units, before.units, "the debt does not move with the range");
        _ledger();
    }

    function _pendingLeaseFees(int24 lo, int24 hi, uint256 slot) internal view returns (uint256 f0, uint256 f1) {
        PoolId id = key.toId();
        (uint128 liq, uint256 last0, uint256 last1) =
            StateLibrary.getPositionInfo(manager, id, address(charter), lo, hi, bytes32(slot + 1));
        (uint256 g0, uint256 g1) = StateLibrary.getFeeGrowthInside(manager, id, lo, hi);
        f0 = FullMath.mulDiv(g0 - last0, liq, Q128);
        f1 = FullMath.mulDiv(g1 - last1, liq, Q128);
    }

    // ------------------------------------------------------------------ passive growth with leases live

    function _expectedGrowth(uint256 amountIn, bool zeroForOne) internal returns (uint256 got, uint256 expected) {
        PoolId id = key.toId();
        (uint256 g0, uint256 g1) = StateLibrary.getFeeGrowthGlobals(manager, id);
        uint256 c0 = charter.passiveGrowth0X128();
        uint256 c1 = charter.passiveGrowth1X128();
        _nextBlock();
        _swapAs(mallory, zeroForOne, -int256(amountIn));
        (uint256 h0, uint256 h1) = StateLibrary.getFeeGrowthGlobals(manager, id);

        uint256 dfg = zeroForOne ? h0 - g0 : h1 - g1;
        uint256 fee = FullMath.mulDiv(amountIn, BASE_FEE, 1e6);
        uint256 managed;
        for (uint256 s; s < MAX_LEASES; s++) {
            managed += charter.lease(s).liquidity;
        }
        uint256 passive = charter.passiveLiquidity();
        uint256 units = passive + charter.leasedUnits();
        expected = PassiveMath.growth(fee, dfg, managed, passive, units);
        got = zeroForOne ? charter.passiveGrowth0X128() - c0 : charter.passiveGrowth1X128() - c1;
        // sanity: the correction pays depositors more than the diluted pool rate
        assertGt(got, dfg);
    }

    function test_growthCorrectsForOneLease() public {
        _open(bob, 0, 300e18, -600, 600);
        (uint256 got, uint256 expected) = _expectedGrowth(1e15, true);
        assertApproxEqRel(got, expected, 1e12);
        (got, expected) = _expectedGrowth(1e15, false);
        assertApproxEqRel(got, expected, 1e12);
    }

    function test_growthCorrectsForTwoLeases() public {
        _open(bob, 0, 300e18, -600, 600);
        _open(carol, 1, 200e18, -1800, 1800);
        (uint256 got, uint256 expected) = _expectedGrowth(1e15, true);
        assertApproxEqRel(got, expected, 1e12);
    }

    function test_outOfRangeLeaseDoesNotCount() public {
        _open(bob, 0, 300e18, 1200, 2400);
        PoolId id = key.toId();
        (uint256 g0,) = StateLibrary.getFeeGrowthGlobals(manager, id);
        uint256 c0 = charter.passiveGrowth0X128();
        _nextBlock();
        _swapAs(mallory, true, -1e15);
        (uint256 h0,) = StateLibrary.getFeeGrowthGlobals(manager, id);
        uint256 fee = FullMath.mulDiv(1e15, BASE_FEE, 1e6);
        uint256 expected = PassiveMath.growth(fee, h0 - g0, 0, charter.passiveLiquidity(), 1000e18);
        assertApproxEqRel(charter.passiveGrowth0X128() - c0, expected, 1e12);
    }
}
