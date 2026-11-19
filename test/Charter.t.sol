// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Charter} from "../src/Charter.sol";
import {Fixture} from "./utils/Fixture.sol";

contract CharterBindingTest is Fixture {
    using PoolIdLibrary for PoolKey;

    function test_bindsToConfiguredPool() public view {
        assertTrue(charter.bound());
        assertEq(PoolId.unwrap(charter.poolId()), PoolId.unwrap(key.toId()));
        assertEq(charter.fullLower(), FL);
        assertEq(charter.fullUpper(), FU);
    }

    function test_secondPoolCannotBind() public {
        PoolKey memory other = key;
        other.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_rejectsWrongPair() public {
        Charter fresh = _freshUnbound();
        MockERC20 t = new MockERC20("X", "X", 18);
        (Currency a, Currency b) = address(t) < Currency.unwrap(currency1)
            ? (Currency.wrap(address(t)), currency1)
            : (currency1, Currency.wrap(address(t)));
        vm.expectRevert();
        manager.initialize(
            PoolKey(a, b, LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(address(fresh))), SQRT_PRICE_1_1
        );
        assertFalse(fresh.bound());
    }

    function test_rejectsStaticFee() public {
        Charter fresh = _freshUnbound();
        vm.expectRevert();
        manager.initialize(PoolKey(currency0, currency1, 3000, SPACING, IHooks(address(fresh))), SQRT_PRICE_1_1);
        assertFalse(fresh.bound());
    }

    function test_rejectsBadConfig() public {
        Charter.Config memory cfg = _config();
        cfg.clampSqrtBps = 0;
        // run the constructor at a valid hook address so the config check is what fails
        address at = address(_flags() ^ (0x6666 << 144));
        vm.etch(at, abi.encodePacked(vm.getCode("Charter.sol:Charter"), abi.encode(manager, cfg)));
        (bool ok, bytes memory ret) = at.call("");
        assertFalse(ok);
        assertEq(bytes4(ret), Charter.BadConfig.selector);
    }

    function _freshUnbound() internal returns (Charter c) {
        address at = address(_flags() ^ (0x5555 << 144));
        deployCodeTo("Charter.sol:Charter", abi.encode(manager, _config()), at);
        c = Charter(at);
    }
}

contract CharterSwapTest is Fixture {
    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 1000e18);
    }

    function test_chargesBaseFee() public {
        uint256 before = currency1.balanceOf(alice);
        _swapAs(alice, true, -1e18);
        uint256 got = currency1.balanceOf(alice) - before;
        // 1e18 in at 0.3% against deep liquidity near 1:1 returns a bit under 0.997e18
        assertApproxEqRel(got, 0.997e18, 0.001e18);
        assertLt(got, 0.997e18);
    }

    function test_recordsBlockStartPrice() public {
        uint160 open = _sqrt();
        _swapAs(alice, true, -10e18);
        assertEq(charter.blockStartSqrt(), open);
        assertEq(charter.lastSwapBlock(), vm.getBlockNumber());
        _swapAs(alice, true, -10e18);
        assertEq(charter.blockStartSqrt(), open, "unchanged within the block");

        _nextBlock();
        uint160 next = _sqrt();
        _swapAs(alice, false, -1e18);
        assertEq(charter.blockStartSqrt(), next);
    }

    function test_settlementPriceIsClamped() public {
        _nextBlock();
        uint160 open = _sqrt();
        _swapAs(mallory, true, -400e18);
        uint160 spot = _sqrt();
        uint160 s = charter.settlementSqrtPrice();
        assertLt(spot, uint256(open) * (10_000 - CLAMP_SQRT_BPS) / 10_000, "push went past the clamp");
        assertEq(s, uint256(open) * (10_000 - CLAMP_SQRT_BPS) / 10_000);

        _nextBlock();
        assertEq(charter.settlementSqrtPrice(), spot, "a new block takes spot as is");
    }

    function test_unlockCallbackOnlyFromManager() public {
        vm.expectRevert();
        charter.unlockCallback("");
    }
}
