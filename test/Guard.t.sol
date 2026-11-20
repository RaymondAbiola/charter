// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Charter} from "../src/Charter.sol";
import {Guard} from "../src/types/CharterTypes.sol";
import {GuardMath} from "../src/libraries/GuardMath.sol";
import {Fixture} from "./utils/Fixture.sol";

contract GuardTest is Fixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 500e18);
        _lp(-1200, 1200, 1500e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);
    }

    function _open(uint128 units, uint256 bondMultiple, int24 half) internal {
        uint256 bond = charter.minBond(units) * bondMultiple;
        vm.prank(bob);
        charter.openLease(0, units, 50_000, bond, -half, half);
    }

    function _arm() internal {
        _nextBlock();
        _swapAs(mallory, true, -1e15);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = StateLibrary.getSlot0(manager, key.toId());
    }

    function _moveTo(int24 tick) internal {
        uint160 target = TickMath.getSqrtPriceAtTick(tick);
        if (target == _sqrt()) return;
        bool zf = _sqrt() > target;
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zf, amountSpecified: -1e30, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_aSwapArmsTheGuard() public {
        _open(300e18, 1, 600);
        assertEq(charter.guard(0).validUntil, 0, "nothing armed before a swap");
        _arm();
        Guard memory g = charter.guard(0);
        assertGt(g.validUntil, block.timestamp);
        assertLe(g.lo, _tick());
        assertGt(g.hi, _tick());
        assertGt(g.feeBudget, 0);
    }

    /// The core property: anywhere inside the band, a full check agrees the lease is healthy.
    function testFuzz_bandIsSound(uint8 sizeSel, uint8 halfSel, uint8 bondSel, uint16 at) public {
        uint128 units = uint128(20e18 + uint256(sizeSel) * 3e18);
        int24 half = int24(int256(120 + uint256(halfSel % 30) * 60));
        _open(units, 1 + bondSel % 3, half);
        _arm();
        Guard memory g = charter.guard(0);
        int24 lo = g.lo < -4000 ? int24(-4000) : g.lo;
        int24 hi = g.hi > 4000 ? int24(4000) : g.hi;
        int24 tick = lo + int24(int256(uint256(at) % uint256(int256(hi - lo))));

        _moveTo(tick);
        assertEq(charter.lease(0).manager, bob, "not liquidated inside the band");
        vm.expectRevert(Charter.Healthy.selector);
        charter.liquidate(0);
    }

    function test_leavingTheBandForcesAFullCheck() public {
        _open(300e18, 1, 600);
        _arm();
        Guard memory g = charter.guard(0);
        _nextBlock();
        _moveTo(g.lo - 1);
        Guard memory after_ = charter.guard(0);
        bool rearmed = after_.growth0At != g.growth0At || after_.lo != g.lo;
        bool closed = charter.lease(0).manager == address(0);
        assertTrue(rearmed || closed, "re-checked once outside the band");
    }

    function test_rentHorizonExpires() public {
        _open(300e18, 1, 600);
        _arm();
        Guard memory g = charter.guard(0);
        vm.warp(g.validUntil + 1);
        _nextBlock();
        _swapAs(mallory, true, -1e15);
        assertGt(charter.guard(0).validUntil, g.validUntil, "re-armed after expiry");
    }

    function test_feeBudgetForcesARecheck() public {
        _open(300e18, 1, 600);
        _arm();
        uint256 first = charter.guard(0).growth0At;
        // heavy two-way flow inside the range spends the fee budget well before the price band
        for (uint256 i; i < 1500 && charter.guard(0).growth0At == first; i++) {
            _nextBlock();
            _swapAs(mallory, true, -80e18);
            _swapAs(mallory, false, -80e18);
        }
        assertTrue(charter.guard(0).growth0At != first, "re-armed once fees owed passed the budget");
    }

    function test_guardClearsWhenTheLeaseChanges() public {
        _open(300e18, 1, 600);
        _arm();
        vm.prank(bob);
        charter.rebalance(0, -1200, 1200);
        assertEq(charter.guard(0).validUntil, 0, "rebalance");

        _arm();
        charter.collectRent(0);
        assertEq(charter.guard(0).validUntil, 0, "rent");
    }

    function test_armedSwapsAreCheap() public {
        _open(300e18, 1, 600);
        _arm();
        // a first swap in each direction pays for writing that side's counter, so warm both up
        _nextBlock();
        _swapAs(mallory, false, -1e15);
        _nextBlock();
        _warp(12);
        uint256 gas = gasleft();
        _swapAs(mallory, false, -1e15);
        uint256 guarded = gas - gasleft();

        vm.prank(bob);
        charter.rebalance(0, -600, 600);
        _nextBlock();
        gas = gasleft();
        _swapAs(mallory, false, -1e15);
        uint256 full = gas - gasleft();
        emit log_named_uint("swap gas, guard holding", guarded);
        emit log_named_uint("swap gas, full check", full);
        assertLt(guarded + 20_000, full);
    }
}

contract GuardMathTest is Test {
    function test_noSpareEquityMeansNoGuard() public pure {
        uint160 s = TickMath.getSqrtPriceAtTick(100);
        (int24 lo, int24 hi) = GuardMath.band(s, 0, 1e18, 1e18);
        assertGt(lo, 100, "the band excludes the current tick");
        assertLe(hi, 100);
    }

    function test_moreBufferWidensTheBand() public pure {
        uint160 s = TickMath.getSqrtPriceAtTick(0);
        (int24 lo1, int24 hi1) = GuardMath.band(s, 1e18, 100e18, 100e18);
        (int24 lo2, int24 hi2) = GuardMath.band(s, 4e18, 100e18, 100e18);
        assertLt(lo2, lo1);
        assertGt(hi2, hi1);
        assertLt(lo1, 0);
        assertGt(hi1, 0);
    }

    function test_noExposureOpensThatSide() public pure {
        uint160 s = TickMath.getSqrtPriceAtTick(0);
        (int24 lo,) = GuardMath.band(s, 1e18, 0, 100e18);
        (, int24 hi) = GuardMath.band(s, 1e18, 100e18, 0);
        assertEq(lo, TickMath.MIN_TICK);
        assertEq(hi, TickMath.MAX_TICK);
    }

    /// Loss bound check: at the band edge, the worst-case linear loss is within half the buffer.
    function testFuzz_edgeLossWithinHalfTheBuffer(uint64 buffer, uint64 max0, uint64 owed0, int16 t) public pure {
        vm.assume(buffer > 1e6 && max0 > 1e6 && owed0 > 1e6);
        uint160 s = TickMath.getSqrtPriceAtTick(t);
        (int24 lo, int24 hi) = GuardMath.band(s, buffer, max0, owed0);
        uint256 p = uint256(s) * s >> 96;
        if (lo > TickMath.MIN_TICK) {
            uint160 sl = TickMath.getSqrtPriceAtTick(lo);
            uint256 pl = uint256(sl) * sl >> 96;
            if (pl < p) assertLe((p - pl) * max0 >> 96, uint256(buffer) / 2 + 1);
        }
        if (hi < TickMath.MAX_TICK) {
            uint160 sh = TickMath.getSqrtPriceAtTick(hi);
            uint256 ph = uint256(sh) * sh >> 96;
            if (ph > p) assertLe((ph - p) * owed0 >> 96, uint256(buffer) / 2 + 1);
        }
    }
}
