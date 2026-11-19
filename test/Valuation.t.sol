// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Lease} from "../src/types/CharterTypes.sol";
import {LeaseMath} from "../src/libraries/LeaseMath.sol";
import {Fixture} from "./utils/Fixture.sol";

contract ValuationTest is Fixture {
    using PoolIdLibrary for PoolKey;

    uint256 constant Q128 = 1 << 128;
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

    function _account() internal view returns (LeaseMath.Account memory a, uint256 bond, int256 equity) {
        return charter.leaseAccount(0);
    }

    function _value(uint256 a0, uint256 a1, uint160 s) internal pure returns (uint256) {
        return a1 + FullMath.mulDiv(FullMath.mulDiv(a0, s, 1 << 96), s, 1 << 96);
    }

    function test_emptySlotIsZero() public view {
        (LeaseMath.Account memory a, uint256 bond, int256 equity) = charter.leaseAccount(1);
        assertEq(a.owedValue, 0);
        assertEq(a.heldValue, 0);
        assertEq(bond, 0);
        assertEq(equity, 0);
    }

    function test_freshLeaseBalances() public view {
        (LeaseMath.Account memory a, uint256 bond, int256 equity) = _account();
        assertApproxEqRel(a.heldValue, a.owedValue, 1e10);
        assertApproxEqRel(uint256(equity), bond, 1e10);
    }

    function test_owedTracksPassiveGrowth() public {
        uint256 c0 = charter.passiveGrowth0X128();
        uint256 c1 = charter.passiveGrowth1X128();
        for (uint256 i; i < 20; i++) {
            _nextBlock();
            _swapAs(mallory, i % 2 == 0, -25e18);
        }
        (LeaseMath.Account memory a,,) = _account();
        uint160 sp = _sqrt();
        uint256 p0 = SqrtPriceMath.getAmount0Delta(sp, TickMath.getSqrtPriceAtTick(FU), UNITS, true);
        uint256 p1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(FL), sp, UNITS, true);
        assertEq(a.owed0 - p0, FullMath.mulDivRoundingUp(charter.passiveGrowth0X128() - c0, UNITS, Q128));
        assertEq(a.owed1 - p1, FullMath.mulDivRoundingUp(charter.passiveGrowth1X128() - c1, UNITS, Q128));
    }

    function test_heldCountsPositionAndFees() public {
        for (uint256 i; i < 20; i++) {
            _nextBlock();
            _swapAs(mallory, i % 2 == 0, -25e18);
        }
        (LeaseMath.Account memory a,,) = _account();
        Lease memory l = charter.lease(0);
        PoolId id = key.toId();
        (uint256 p0, uint256 p1) = LeaseMath.positionAmounts(_sqrt(), l.tickLower, l.tickUpper, l.liquidity);
        (uint128 liq, uint256 last0, uint256 last1) =
            StateLibrary.getPositionInfo(manager, id, address(charter), l.tickLower, l.tickUpper, bytes32(uint256(1)));
        (uint256 g0, uint256 g1) = StateLibrary.getFeeGrowthInside(manager, id, l.tickLower, l.tickUpper);
        uint256 f0 = FullMath.mulDiv(g0 - last0, liq, Q128);
        uint256 f1 = FullMath.mulDiv(g1 - last1, liq, Q128);
        assertGt(f0 + f1, 0);
        assertEq(a.held0, l.held0 + p0 + f0);
        assertEq(a.held1, l.held1 + p1 + f1);
    }

    /// A one-way move costs a concentrated range more than a full-range position.
    function test_aDropHurtsTheLeaseMoreThanPassive() public {
        _nextBlock();
        _swapAs(mallory, true, -150e18);
        _nextBlock();
        (LeaseMath.Account memory a, uint256 bond, int256 equity) = _account();
        assertLt(a.heldValue, a.owedValue);
        assertLt(equity, int256(bond), "the shortfall eats into the bond");
    }

    /// Two-way flow inside the range pays the concentrated lease more fees than the passive debt,
    /// and with the price back where it started the manager comes out ahead.
    function test_choppyFlowLetsTheLeaseBeatPassive() public {
        uint160 start = _sqrt();
        for (uint256 i; i < 40; i++) {
            _nextBlock();
            _swapAs(mallory, true, -20e18);
            _swapAs(mallory, false, -20e18);
        }
        assertApproxEqRel(_sqrt(), start, 1e15);
        _nextBlock();
        (LeaseMath.Account memory a, uint256 bond, int256 equity) = _account();
        assertGt(a.heldValue, a.owedValue);
        assertGt(equity, int256(bond), "the manager keeps the extra");
    }

    function test_valuationUsesTheClampedPrice() public {
        _nextBlock();
        uint160 open = _sqrt();
        _swapAs(mallory, true, -400e18);
        uint160 clamp = uint160(uint256(open) * (10_000 - CLAMP_SQRT_BPS) / 10_000);
        assertEq(charter.settlementSqrtPrice(), clamp);
        (LeaseMath.Account memory a,,) = _account();
        assertEq(a.owedValue, _value(a.owed0, a.owed1, clamp));
        assertEq(a.heldValue, _value(a.held0, a.held1, clamp));
    }
}
