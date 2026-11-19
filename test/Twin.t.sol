// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Fixture} from "./utils/Fixture.sol";

/// The same swaps go through the Charter pool and a hookless twin where all depositor capital
/// really sits at full range. Both pools are pulled to one outside price after every retail swap,
/// the way arbitrage keeps a real pool in line. The twin's fee growth is what a passive unit truly
/// earned; Charter's floor is its own pool's fee growth and its ceiling is the hook's estimate.
contract TwinTest is Fixture {
    using PoolIdLibrary for PoolKey;

    enum Mix {
        Retail,
        Balanced,
        Arbitrage
    }

    struct Result {
        int256 floorBps;
        int256 ceilingBps;
        uint256 shareBps;
    }

    PoolKey twin;

    function setUp() public override {
        super.setUp();
        (twin,) = initPool(currency0, currency1, IHooks(address(0)), BASE_FEE, SQRT_PRICE_1_1);
        _others(key);
        _others(twin);
    }

    function _lpOn(PoolKey memory k, int24 lo, int24 hi, uint256 l, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(l), salt: salt}), ZERO_BYTES
        );
    }

    function _others(PoolKey memory k) internal {
        _lpOn(k, FL, FU, 1000e18, 0);
        _lpOn(k, -1200, 1200, 3000e18, 0);
        _lpOn(k, -240, 240, 3000e18, 0);
    }

    function _arbTo(PoolKey memory k, uint160 target) internal {
        (uint160 cur,,,) = StateLibrary.getSlot0(manager, k.toId());
        if (cur == target) return;
        bool zf = cur > target;
        swapRouter.swap(
            k,
            SwapParams({zeroForOne: zf, amountSpecified: -1e30, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _growth(PoolKey memory k) internal view returns (uint256 g0, uint256 g1) {
        (g0, g1) = StateLibrary.getFeeGrowthGlobals(manager, k.toId());
    }

    function _bps(uint256 a, uint256 b) internal pure returns (int256) {
        return (int256(a) - int256(b)) * 10_000 / int256(b);
    }

    function _run(uint256 seed, uint128 leased, int24 half, Mix mix, uint256 steps) internal returns (Result memory r) {
        uint128 deposit = 1000e18;
        vm.prank(alice);
        charter.deposit(deposit, type(uint256).max, type(uint256).max, alice);
        _lpOn(twin, FL, FU, deposit, bytes32(uint256(7)));
        uint256 bond = charter.minBond(leased);
        vm.prank(bob);
        charter.openLease(0, leased, 50_000, bond, -half, half);

        uint128 lm = charter.lease(0).liquidity;
        uint128 active = StateLibrary.getLiquidity(manager, key.toId());
        r.shareBps = uint256(lm) * 10_000 / active;

        (uint256 m0, uint256 m1) = _growth(key);
        (uint256 t0, uint256 t1) = _growth(twin);
        uint256 c0 = charter.passiveGrowth0X128();
        uint256 c1 = charter.passiveGrowth1X128();

        (uint256 retail, uint256 vol) = mix == Mix.Retail
            ? (uint256(8e18), uint256(20))
            : mix == Mix.Balanced ? (uint256(4e18), uint256(60)) : (uint256(4e17), uint256(120));
        uint256 target = SQRT_PRICE_1_1;
        for (uint256 i; i < steps; i++) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, i)));
            uint256 step = target * ((rnd >> 64) % (vol + 1)) / 20_000;
            target = (rnd >> 128) & 1 == 1 ? target + step : target - step;
            // keep the walk inside the manager's range often enough to matter
            if (target > SQRT_PRICE_1_1 * 103 / 100) target = SQRT_PRICE_1_1 * 103 / 100;
            if (target < SQRT_PRICE_1_1 * 97 / 100) target = SQRT_PRICE_1_1 * 97 / 100;
            bool zf = rnd & 1 == 1;
            int256 size = -int256(retail * (1 + (rnd >> 8) % 100) / 50);
            _nextBlock();
            swap(key, zf, size, ZERO_BYTES);
            swap(twin, zf, size, ZERO_BYTES);
            _arbTo(key, uint160(target));
            _arbTo(twin, uint160(target));
        }

        (uint256 m0b, uint256 m1b) = _growth(key);
        (uint256 t0b, uint256 t1b) = _growth(twin);
        uint256 truth = (t0b - t0) + (t1b - t1);
        uint256 floor = (m0b - m0) + (m1b - m1);
        uint256 ceiling = (charter.passiveGrowth0X128() - c0) + (charter.passiveGrowth1X128() - c1);
        r.floorBps = _bps(floor, truth);
        r.ceilingBps = _bps(ceiling, truth);
    }

    function _log(string memory label, Result memory r) internal pure {
        console2.log(label, "manager share of active liquidity, bps:", r.shareBps);
        console2.log("   floor vs truth, bps:");
        console2.logInt(r.floorBps);
        console2.log("   ceiling vs truth, bps:");
        console2.logInt(r.ceilingBps);
    }

    function _bracketed(Result memory r) internal pure {
        assertLe(r.floorBps, 100, "floor sits at or under the truth");
        assertGe(r.ceilingBps, -300, "ceiling sits at or over the truth");
    }

    function test_smallLeaseAcrossMixes() public {
        string[3] memory names = ["retail", "balanced", "arbitrage"];
        for (uint256 m; m < 3; m++) {
            uint256 snap = vm.snapshotState();
            Result memory r = _run(11 + m, 10e18, 1200, Mix(m), 150);
            _log(names[m], r);
            _bracketed(r);
            // at a few percent of the pool the estimate stays close to the truth
            assertLt(r.ceilingBps, 600);
            assertGt(r.ceilingBps, -300);
            vm.revertToState(snap);
        }
    }

    function test_largerLeasesWidenTheBand() public {
        uint128[3] memory sizes = [uint128(10e18), 40e18, 150e18];
        int256 lastWidth;
        for (uint256 i; i < 3; i++) {
            uint256 snap = vm.snapshotState();
            Result memory r = _run(21, sizes[i], 1200, Mix.Balanced, 150);
            _log("balanced", r);
            _bracketed(r);
            int256 width = r.ceilingBps - r.floorBps;
            assertGe(width, lastWidth, "a bigger manager share means a wider band");
            lastWidth = width;
            vm.revertToState(snap);
        }
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_truthIsBracketed(uint256 seed, uint8 sizeSel, uint8 mixSel) public {
        uint128 leased = uint128(5e18 + uint256(sizeSel % 8) * 5e18);
        Result memory r = _run(seed, leased, 1200, Mix(mixSel % 3), 60);
        _bracketed(r);
    }
}
