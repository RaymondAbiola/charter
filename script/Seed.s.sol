// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Charter} from "../src/Charter.sol";

/// Puts a deployment into a state worth looking at: outside liquidity, a deposit, a running lease,
/// some trades and a pending bid. Run after Deploy with the same flags.
contract Seed is Script {
    using PoolIdLibrary for PoolKey;

    int24 constant SPACING = 60;

    Charter charter;
    IPoolManager pm;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey key;

    function run() external {
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        charter = Charter(vm.parseJsonAddress(json, ".charter"));
        pm = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        swapRouter = PoolSwapTest(vm.parseJsonAddress(json, ".swapRouter"));
        lpRouter = PoolModifyLiquidityTest(vm.parseJsonAddress(json, ".liquidityRouter"));
        Currency c0 = Currency.wrap(vm.parseJsonAddress(json, ".currency0"));
        Currency c1 = Currency.wrap(vm.parseJsonAddress(json, ".currency1"));
        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(address(charter)));

        vm.startBroadcast();
        address me = msg.sender;
        MockERC20 t0 = MockERC20(Currency.unwrap(c0));
        MockERC20 t1 = MockERC20(Currency.unwrap(c1));
        t0.mint(me, 10 ** (t0.decimals() + 9));
        t1.mint(me, 10 ** (t1.decimals() + 9));
        address[3] memory spenders = [address(charter), address(swapRouter), address(lpRouter)];
        for (uint256 i; i < 3; i++) {
            t0.approve(spenders[i], type(uint256).max);
            t1.approve(spenders[i], type(uint256).max);
        }

        int24 here = _tick();
        int24 mid = here / SPACING * SPACING;
        int24 full = TickMath.maxUsableTick(SPACING);
        // other LPs: some full range, more concentrated around the price
        _lp(-full, full, 20e15);
        _lp(mid - 2400, mid + 2400, 60e15);
        _lp(mid - 600, mid + 600, 60e15);

        charter.deposit(3e15, type(uint256).max, type(uint256).max, me);
        uint128 units = 1e15;
        charter.openLease(0, units, 50_000, charter.minBond(units) * 2, mid - 900, mid + 900);

        for (uint256 i; i < 6; i++) {
            _swap(i % 2 == 0, i % 2 == 0 ? _amount0(2) : _amount1(2));
        }

        charter.bid(0, units, 60_000, charter.minBond(units) * 2, mid - 600, mid + 600);
        vm.stopBroadcast();

        console2.log("passive liquidity", charter.passiveLiquidity());
        console2.log("leased units", charter.leasedUnits());
        console2.log("pending bid ready at", charter.pendingBid(0).readyAt);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = StateLibrary.getSlot0(pm, key.toId());
    }

    function _lp(int24 lo, int24 hi, uint256 l) internal {
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(l), salt: 0}), ""
        );
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// `units` whole tokens of token0, or of token1.
    function _amount0(uint256 units) internal view returns (uint256) {
        return units * 10 ** MockERC20(Currency.unwrap(key.currency0)).decimals() * _scale0();
    }

    function _amount1(uint256 units) internal view returns (uint256) {
        return units * 10 ** MockERC20(Currency.unwrap(key.currency1)).decimals() * _scale1();
    }

    // trade roughly the same dollar size whichever token is token0
    function _scale0() internal view returns (uint256) {
        return MockERC20(Currency.unwrap(key.currency0)).decimals() == 6 ? 3000 : 1;
    }

    function _scale1() internal view returns (uint256) {
        return MockERC20(Currency.unwrap(key.currency1)).decimals() == 6 ? 3000 : 1;
    }
}
