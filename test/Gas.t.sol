// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Fixture} from "./utils/Fixture.sol";

/// Swap gas through the test router, with every account and slot it touches cooled first, as in a
/// fresh transaction. Excludes the 21,000 base transaction cost. Run with -vv to print the table.
contract GasTest is Fixture {
    PoolKey plain;
    address[] cold;

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 500e18);
        _lp(-1200, 1200, 1500e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);

        // the same tokens, fee and liquidity with no hook: Charter's 1000e18 passive units sit full range
        plain = PoolKey(currency0, currency1, BASE_FEE, SPACING, IHooks(address(0)));
        manager.initialize(plain, _sqrt());
        modifyLiquidityRouter.modifyLiquidity(plain, ModifyLiquidityParams(FL, FU, 1500e18, 0), ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(plain, ModifyLiquidityParams(-1200, 1200, 1500e18, 0), ZERO_BYTES);

        cold.push(address(manager));
        cold.push(address(charter));
        cold.push(address(swapRouter));
        cold.push(Currency.unwrap(currency0));
        cold.push(Currency.unwrap(currency1));
        _addLinkedLibraries();
    }

    /// The external libraries the hook delegatecalls, found as PUSH20 operands in its code.
    function _addLinkedLibraries() internal {
        bytes memory code = address(charter).code;
        for (uint256 i; i + 21 <= code.length; i++) {
            if (code[i] != 0x73) continue;
            address a;
            assembly {
                a := shr(96, mload(add(add(code, 0x21), i)))
            }
            if (a.code.length == 0 || a == address(manager) || a == address(charter)) continue;
            bool seen;
            for (uint256 j; j < cold.length; j++) {
                if (cold[j] == a) seen = true;
            }
            if (!seen) cold.push(a);
        }
    }

    function _swap(PoolKey memory k, bool zeroForOne) internal returns (uint256 used) {
        for (uint256 i; i < cold.length; i++) {
            vm.cool(cold[i]);
        }
        vm.startPrank(mallory);
        uint256 start = gasleft();
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        used = start - gasleft();
        vm.stopPrank();
    }

    /// A small swap in a fresh block, after a swap each way has armed guards and written counters.
    function _measure(PoolKey memory k) internal returns (uint256) {
        _nextBlock();
        _swap(k, true);
        _nextBlock();
        _swap(k, false);
        _nextBlock();
        _warp(12);
        return _swap(k, false);
    }

    function _open(uint256 n) internal {
        for (uint256 slot; slot < n; slot++) {
            uint128 units = 100e18;
            uint256 bond = charter.minBond(units) * 2;
            int24 half = int24(int256(600 + slot * 300));
            vm.prank(bob);
            charter.openLease(slot, units, 50_000, bond, -half, half);
        }
    }

    function _clearGuards(uint256 n) internal {
        for (uint256 slot; slot < n; slot++) {
            charter.collectRent(slot);
        }
    }

    function test_swapGas() public {
        uint256 none = _measure(plain);
        uint256 empty = _measure(key);
        console2.log("no hook                    ", none);
        console2.log("Charter, no leases         ", empty);
        uint256 last;
        for (uint256 n = 1; n <= MAX_LEASES; n++) {
            uint256 snap = vm.snapshotState();
            _open(n);
            uint256 guarded = _measure(key);
            _clearGuards(n);
            _nextBlock();
            _warp(12);
            uint256 full = _swap(key, false);
            console2.log("leases", n);
            console2.log("  guards holding           ", guarded);
            console2.log("  full check of every lease", full);
            assertLt(guarded, full, "the guard is the cheap path");
            assertGt(guarded, last, "each lease adds a little");
            last = guarded;
            vm.revertToState(snap);
        }
    }
}
