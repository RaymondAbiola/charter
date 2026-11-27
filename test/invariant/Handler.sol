// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Charter} from "../../src/Charter.sol";

/// Random actors calling every Charter action. Invalid calls just revert and are skipped; the
/// invariants only care that whatever does go through leaves the books consistent.
contract Handler is Test {
    Charter public charter;
    PoolSwapTest public swapRouter;
    PoolKey public key;
    address[4] public actors;
    int24 constant SPACING = 60;

    mapping(bytes4 => uint256) public succeeded;
    mapping(bytes4 => mapping(bytes4 => uint256)) public failedWith;
    bytes4[] public failReasons;

    constructor(Charter c, PoolSwapTest r, PoolKey memory k, address[4] memory a) {
        charter = c;
        swapRouter = r;
        key = k;
        actors = a;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _half(uint256 seed) internal pure returns (int24) {
        return int24(int256(bound(seed, 1, 40))) * SPACING;
    }

    function _ok(bytes4 sel) internal {
        succeeded[sel]++;
    }

    function _fail(bytes4 sel, bytes memory err) internal {
        bytes4 reason = err.length >= 4 ? bytes4(err) : bytes4(0);
        if (failedWith[sel][reason] == 0) failReasons.push(reason);
        failedWith[sel][reason]++;
    }

    function failReasonCount() external view returns (uint256) {
        return failReasons.length;
    }

    function deposit(uint256 who, uint256 shares) external {
        address a = _actor(who);
        shares = bound(shares, 1e15, 200e18);
        vm.prank(a);
        try charter.deposit(shares, type(uint256).max, type(uint256).max, a) {
            _ok(this.deposit.selector);
        } catch {}
    }

    function withdraw(uint256 who, uint256 pct) external {
        address a = _actor(who);
        uint256 shares = charter.balanceOf(a) * bound(pct, 1, 100) / 100;
        if (shares == 0) return;
        vm.prank(a);
        try charter.withdraw(shares, 0, 0, a) {
            _ok(this.withdraw.selector);
        } catch {}
    }

    function swap(uint256 who, bool zeroForOne, uint256 amount) external {
        address a = _actor(who);
        amount = bound(amount, 1e9, 150e18);
        vm.prank(a);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            _ok(this.swap.selector);
        } catch (bytes memory err) {
            _fail(this.swap.selector, err);
        }
    }

    function openLease(uint256 who, uint256 slot, uint256 units, uint256 half, uint32 rent, uint256 extra) external {
        address a = _actor(who);
        slot = bound(slot, 0, 3);
        uint128 u = uint128(bound(units, 1e18, 200e18));
        int24 h = _half(half);
        uint256 bond = charter.minBond(u) * bound(extra, 1, 3);
        vm.prank(a);
        try charter.openLease(slot, u, uint32(bound(rent, 0, 200_000)), bond, -h, h) {
            _ok(this.openLease.selector);
        } catch {}
    }

    function rebalance(uint256 slot, uint256 half) external {
        slot = bound(slot, 0, 3);
        address m = charter.lease(slot).manager;
        if (m == address(0)) return;
        int24 h = _half(half);
        vm.prank(m);
        try charter.rebalance(slot, -h, h) {
            _ok(this.rebalance.selector);
        } catch {}
    }

    function exitLease(uint256 slot) external {
        slot = bound(slot, 0, 3);
        address m = charter.lease(slot).manager;
        if (m == address(0)) return;
        vm.prank(m);
        try charter.exitLease(slot) {
            _ok(this.exitLease.selector);
        } catch {}
    }

    function collectRent(uint256 slot) external {
        try charter.collectRent(bound(slot, 0, 3)) {
            _ok(this.collectRent.selector);
        } catch {}
    }

    function bid(uint256 who, uint256 slot, uint256 raise, uint256 units, uint256 half) external {
        address a = _actor(who);
        // aim at an occupied slot with a rent that actually beats it, so takeovers get exercised
        uint256 start = bound(slot, 0, 3);
        for (uint256 i; i < 4; i++) {
            slot = (start + i) % 4;
            if (charter.lease(slot).manager != address(0)) break;
        }
        uint256 floor = charter.lease(slot).rentPips;
        uint256 pending = charter.pendingBid(slot).rentPips;
        if (pending > floor) floor = pending;
        uint256 rent = (floor == 0 ? 10_000 : floor) * bound(raise, 105, 200) / 100;
        uint128 u = uint128(bound(units, 1e18, 200e18));
        int24 h = _half(half);
        uint256 bond = charter.minBond(u) * 2;
        vm.prank(a);
        try charter.bid(slot, u, uint32(rent), bond, -h, h) {
            _ok(this.bid.selector);
        } catch {}
    }

    function activate(uint256 slot) external {
        try charter.activate(bound(slot, 0, 3)) {
            _ok(this.activate.selector);
        } catch {}
    }

    function cancelBid(uint256 slot) external {
        slot = bound(slot, 0, 3);
        address b = charter.pendingBid(slot).bidder;
        if (b == address(0)) return;
        vm.prank(b);
        try charter.cancelBid(slot) {
            _ok(this.cancelBid.selector);
        } catch {}
    }

    function liquidate(uint256 slot) external {
        try charter.liquidate(bound(slot, 0, 3)) {
            _ok(this.liquidate.selector);
        } catch {}
    }

    function repassivate() external {
        try charter.repassivate() {
            _ok(this.repassivate.selector);
        } catch {}
    }

    function passTime(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 1, 30 days));
        vm.roll(vm.getBlockNumber() + 1);
        _ok(this.passTime.selector);
    }

    function swapFailures() external view returns (uint256 n) {
        for (uint256 i; i < failReasons.length; i++) {
            n += failedWith[this.swap.selector][failReasons[i]];
        }
    }
}
