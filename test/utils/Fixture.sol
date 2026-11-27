// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Charter} from "../../src/Charter.sol";

abstract contract Fixture is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint24 constant BASE_FEE = 3000;
    int24 constant SPACING = 60;
    uint16 constant CLAMP_SQRT_BPS = 100;
    uint8 constant MAX_LEASES = 4;
    uint16 constant MIN_BOND_BPS = 500;
    uint16 constant MAINTENANCE_BPS = 100;
    uint32 constant AUCTION_DELAY = 5 minutes;
    uint16 constant MIN_RAISE_BPS = 500;

    Charter charter;
    int24 FL;
    int24 FU;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address mallory = makeAddr("mallory");

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        charter = _deployCharter();
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(address(charter)));
        manager.initialize(key, SQRT_PRICE_1_1);
        FL = TickMath.minUsableTick(SPACING);
        FU = TickMath.maxUsableTick(SPACING);
        address[4] memory users = [alice, bob, carol, mallory];
        for (uint256 i; i < users.length; i++) {
            _fund(users[i]);
        }
    }

    function _config() internal view returns (Charter.Config memory) {
        return Charter.Config({
            currency0: currency0,
            currency1: currency1,
            tickSpacing: SPACING,
            baseFee: BASE_FEE,
            clampSqrtBps: CLAMP_SQRT_BPS,
            maxLeases: MAX_LEASES,
            minBondBps: MIN_BOND_BPS,
            maintenanceBps: MAINTENANCE_BPS,
            auctionDelay: AUCTION_DELAY,
            minRaiseBps: MIN_RAISE_BPS,
            shareCapBps: _shareCapBps()
        });
    }

    // most tests use deliberately large leases; the cap has its own suite
    function _shareCapBps() internal pure virtual returns (uint16) {
        return 10_000;
    }

    function _flags() internal pure returns (uint160) {
        return Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    }

    function _deployCharter() internal returns (Charter c) {
        address at = address(_flags() ^ (0x4444 << 144));
        deployCodeTo("Charter.sol:Charter", abi.encode(manager, _config()), at);
        c = Charter(at);
    }

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(who, 1e30);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(charter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(charter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _lp(int24 lo, int24 hi, uint256 l) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(l), salt: 0}), ZERO_BYTES
        );
    }

    function _swapAs(address who, bool zeroForOne, int256 amount) internal {
        vm.prank(who);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    // via-ir can reuse an earlier block.number read inside one test, so ask the cheatcode
    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _warp(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function _sqrt() internal view returns (uint160 s) {
        (s,,,) = StateLibrary.getSlot0(manager, key.toId());
    }
}
