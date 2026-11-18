// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolIdLibrary, PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PassiveMath} from "../src/libraries/PassiveMath.sol";
import {Fixture} from "./utils/Fixture.sol";

contract PassiveGrowthTest is Fixture {
    using PoolIdLibrary for PoolKey;

    uint256 constant Q128 = 1 << 128;

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 500e18);
        _lp(-600, 600, 2000e18);
        _lp(-120, 120, 1500e18);
    }

    function _poolGrowth() internal view returns (uint256 g0, uint256 g1) {
        (g0, g1) = StateLibrary.getFeeGrowthGlobals(manager, key.toId());
    }

    function _swaps(uint256 seed, uint256 n) internal {
        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.roll(block.number + 1);
            uint256 size = 1e18 + (r >> 8) % 60e18;
            _swapAs(mallory, r & 1 == 1, -int256(size));
        }
    }

    function test_noDepositorsNoGrowth() public {
        _swaps(1, 10);
        assertEq(charter.passiveGrowth0X128(), 0);
        assertEq(charter.passiveGrowth1X128(), 0);
    }

    function testFuzz_noLeasesTracksPoolFeeGrowth(uint256 seed) public {
        vm.prank(alice);
        charter.deposit(200e18, type(uint256).max, type(uint256).max, alice);
        (uint256 p0, uint256 p1) = _poolGrowth();
        uint256 c0 = charter.passiveGrowth0X128();
        uint256 c1 = charter.passiveGrowth1X128();

        _swaps(seed, 25);

        (uint256 q0, uint256 q1) = _poolGrowth();
        assertEq(charter.passiveGrowth0X128() - c0, q0 - p0, "token0");
        assertEq(charter.passiveGrowth1X128() - c1, q1 - p1, "token1");
    }

    /// The counter times the passive liquidity is what the passive position actually earned.
    function test_counterPricesThePassivePosition() public {
        vm.prank(alice);
        charter.deposit(200e18, type(uint256).max, type(uint256).max, alice);
        (, uint256 f0Before, uint256 f1Before) = charter.bundle();
        uint256 c0 = charter.passiveGrowth0X128();
        uint256 c1 = charter.passiveGrowth1X128();

        _swaps(7, 30);

        (, uint256 f0, uint256 f1) = charter.bundle();
        uint256 l = charter.passiveLiquidity();
        assertApproxEqAbs(f0 - f0Before, FullMath.mulDiv(charter.passiveGrowth0X128() - c0, l, Q128), 2);
        assertApproxEqAbs(f1 - f1Before, FullMath.mulDiv(charter.passiveGrowth1X128() - c1, l, Q128), 2);
    }

    /// The LP share of fees under a live protocol fee, checked against a real swap.
    function test_lpFeeMatchesPoolUnderProtocolFee() public {
        manager.setProtocolFeeController(address(this));
        // 0.025% one way, 0.04% the other
        uint24 packed = (uint24(400) << 12) | 250;
        manager.setProtocolFee(key, packed);

        PoolKey memory k = key;
        (uint256 g0,) = _poolGrowth();
        uint128 l = StateLibrary.getLiquidity(manager, k.toId());
        // small enough to stay inside the current tick range, so one liquidity value applies
        _swapAs(mallory, true, -1e15);
        (uint256 h0,) = _poolGrowth();
        uint256 real = FullMath.mulDiv(h0 - g0, l, Q128);
        assertApproxEqAbs(PassiveMath.lpFee(1e15, BASE_FEE, 250), real, 2);
    }

    function test_lpFeeMatchesPoolWhenCrossTermSurvives() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, (uint24(1000) << 12) | 1000);
        (, uint256 g1) = _poolGrowth();
        uint128 l = StateLibrary.getLiquidity(manager, key.toId());
        _swapAs(mallory, false, -1e15);
        (, uint256 h1) = _poolGrowth();
        assertApproxEqAbs(PassiveMath.lpFee(1e15, BASE_FEE, 1000), FullMath.mulDiv(h1 - g1, l, Q128), 2);
    }
}

contract PassiveMathTest is Test {
    uint256 constant Q128 = 1 << 128;

    function test_growthWithoutManagersIsTheRealFeeGrowth() public pure {
        uint256 fee = 3e15;
        uint256 l = 5000e18;
        uint256 dfg = FullMath.mulDiv(fee, Q128, l);
        uint256 g = PassiveMath.growth(fee, dfg, 0, 800e18, 800e18);
        assertApproxEqRel(g, dfg, 1e9);
    }

    function test_managersAreSwappedOutOfTheDenominator() public pure {
        uint256 fee = 3e15;
        // others 4000, passive 300, a manager with 1700 in range, 200 depositor units leased
        uint256 dfg = FullMath.mulDiv(fee, Q128, 4000e18 + 300e18 + 1700e18);
        uint256 g = PassiveMath.growth(fee, dfg, 1700e18, 300e18, 500e18);
        uint256 expected = FullMath.mulDiv(fee, Q128, 4000e18 + 500e18);
        assertApproxEqRel(g, expected, 1e9);
        assertGt(g, dfg, "the passive leg is owed more than diluted fee growth");
    }

    function test_noUnitsNoGrowth() public pure {
        assertEq(PassiveMath.growth(1e15, 1e20, 0, 0, 0), 0);
        assertEq(PassiveMath.growth(1e15, 0, 0, 1, 1), 0);
    }

    function test_lpFeeWithoutProtocolFee() public pure {
        assertEq(PassiveMath.lpFee(1e18, 3000, 0), 3e15);
        assertEq(PassiveMath.lpFee(1e18, 3000, 1000), 2.997e15, "cross term survives rounding here");
        assertEq(PassiveMath.lpFee(1e18, 3000, 250), 3e15, "and rounds away here");
    }

    function test_overlapCases() public pure {
        uint160 a = TickMath.getSqrtPriceAtTick(-600);
        uint160 b = TickMath.getSqrtPriceAtTick(600);
        uint160 mid = TickMath.getSqrtPriceAtTick(0);
        uint160 below = TickMath.getSqrtPriceAtTick(-1200);
        uint160 above = TickMath.getSqrtPriceAtTick(1200);
        assertEq(PassiveMath.overlap(mid, mid, a, b), 1e18, "still and inside");
        assertEq(PassiveMath.overlap(above, above, a, b), 0, "still and outside");
        assertEq(PassiveMath.overlap(b, b, a, b), 0, "upper bound is exclusive");
        assertEq(PassiveMath.overlap(a, mid, a, b), 1e18, "fully inside");
        assertEq(PassiveMath.overlap(above, above + 1, a, b), 0, "fully outside");
        uint256 part = PassiveMath.overlap(below, mid, a, b);
        assertEq(part, uint256(mid - a) * 1e18 / (mid - below));
        assertEq(PassiveMath.overlap(mid, below, a, b), part, "direction does not matter");
        assertEq(PassiveMath.overlap(below, above, a, b), uint256(b - a) * 1e18 / (above - below), "spans the range");
    }

    function testFuzz_overlapIsAFraction(uint160 s0, uint160 s1, uint160 a, uint160 b) public pure {
        vm.assume(a < b);
        uint256 f = PassiveMath.overlap(s0, s1, a, b);
        assertLe(f, 1e18);
        assertEq(f, PassiveMath.overlap(s1, s0, a, b));
    }
}
