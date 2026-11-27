// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Charter} from "../src/Charter.sol";

/// Trades the pool to a target price, given in whole token1 per token0 (tUSDC per tWETH), so the
/// hook's reaction can be watched live. Mints whatever input the trade needs, since the test tokens
/// are open-mint. Usage: forge script script/Move.s.sol --sig "run(uint256)" 3800 ...
contract Move is Script {
    using PoolIdLibrary for PoolKey;

    function run(uint256 price) external {
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        Charter charter = Charter(vm.parseJsonAddress(json, ".charter"));
        IPoolManager pm = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        PoolSwapTest router = PoolSwapTest(vm.parseJsonAddress(json, ".swapRouter"));
        MockERC20 t0 = MockERC20(vm.parseJsonAddress(json, ".currency0"));
        MockERC20 t1 = MockERC20(vm.parseJsonAddress(json, ".currency1"));
        int24 spacing = int24(vm.parseJsonInt(json, ".tickSpacing"));
        PoolKey memory key = PoolKey(
            Currency.wrap(address(t0)),
            Currency.wrap(address(t1)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            spacing,
            IHooks(address(charter))
        );

        // price in raw units is token1 per token0 scaled by their decimals; sqrt of that, in Q96
        uint256 raw = FullMath.mulDiv(price * 10 ** t1.decimals(), 1 << 192, 10 ** t0.decimals());
        uint160 target = uint160(FixedPointMathLib.sqrt(raw));
        (uint160 now_,,,) = StateLibrary.getSlot0(pm, key.toId());
        require(target != now_, "already there");
        bool down = target < now_;

        uint256 scale = 10 ** (t0.decimals() + 2 - t1.decimals());
        _report("before", charter, pm, key, scale);
        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        MockERC20 input = down ? t0 : t1;
        input.mint(me, 10 ** (input.decimals() + 12));
        if (input.allowance(me, address(router)) < type(uint128).max) {
            input.approve(address(router), type(uint256).max);
        }
        router.swap(
            key,
            SwapParams({
                zeroForOne: down, amountSpecified: -int256(10 ** (input.decimals() + 12)), sqrtPriceLimitX96: target
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();
        _report("after", charter, pm, key, scale);
    }

    function _report(string memory label, Charter charter, IPoolManager pm, PoolKey memory key, uint256 scale)
        internal
        view
    {
        (uint160 s,,,) = StateLibrary.getSlot0(pm, key.toId());
        // whole token1 per token0, in hundredths
        uint256 cents = FullMath.mulDiv(FullMath.mulDiv(uint256(s), uint256(s), 1 << 96), scale, 1 << 96);
        console2.log(string.concat(label, ": price ", vm.toString(cents / 100), ".", _two(cents % 100)));
        for (uint256 slot; slot < charter.maxLeases(); slot++) {
            address m = charter.lease(slot).manager;
            if (m != address(0)) console2.log("  slot", slot, "leased by", m);
        }
        console2.log("  uncovered", charter.uncovered());
    }

    function _two(uint256 n) internal pure returns (string memory) {
        return n < 10 ? string.concat("0", vm.toString(n)) : vm.toString(n);
    }
}
