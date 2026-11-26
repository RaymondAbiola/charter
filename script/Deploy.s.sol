// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Charter} from "../src/Charter.sol";

/// Deploys Charter on a tUSDC/tWETH pool.
///   local:   anvil, then forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
///   testnet: POOL_MANAGER=0x00B036B58a818B1BC34d502D3fE730Db729e62AC forge script script/Deploy.s.sol \
///            --rpc-url unichain_sepolia --broadcast --account <keystore name>
contract Deploy is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    int24 constant SPACING = 60;
    uint256 constant ETH_PRICE = 3000;

    function run() external {
        address pmAddr = vm.envOr("POOL_MANAGER", address(0));

        vm.startBroadcast();
        address me = msg.sender;
        IPoolManager pm = pmAddr == address(0) ? IPoolManager(address(new PoolManager(me))) : IPoolManager(pmAddr);

        MockERC20 usdc = new MockERC20("Charter test USDC", "tUSDC", 6);
        MockERC20 weth = new MockERC20("Charter test WETH", "tWETH", 18);
        (Currency c0, Currency c1) = address(usdc) < address(weth)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(usdc)));

        Charter.Config memory cfg = Charter.Config({
            currency0: c0,
            currency1: c1,
            tickSpacing: SPACING,
            baseFee: 3000,
            clampSqrtBps: 100,
            maxLeases: 4,
            minBondBps: 500,
            maintenanceBps: 100,
            auctionDelay: 5 minutes,
            minRaiseBps: 500
        });
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(Charter).creationCode, abi.encode(pm, cfg));
        Charter charter = new Charter{salt: salt}(pm, cfg);
        require(address(charter) == predicted, "hook address mismatch");

        PoolSwapTest swapRouter = new PoolSwapTest(pm);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(pm);

        PoolKey memory key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(address(charter)));
        pm.initialize(key, _sqrtPriceX96(Currency.unwrap(c0) == address(usdc)));
        vm.stopBroadcast();

        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "poolManager", address(pm));
        vm.serializeAddress(o, "charter", address(charter));
        vm.serializeAddress(o, "tUSDC", address(usdc));
        vm.serializeAddress(o, "tWETH", address(weth));
        vm.serializeAddress(o, "currency0", Currency.unwrap(c0));
        vm.serializeAddress(o, "currency1", Currency.unwrap(c1));
        vm.serializeAddress(o, "swapRouter", address(swapRouter));
        vm.serializeAddress(o, "liquidityRouter", address(lpRouter));
        vm.serializeInt(o, "tickSpacing", SPACING);
        string memory json = vm.serializeBytes32(o, "poolId", keccak256(abi.encode(key)));
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Charter hook", address(charter));
        console2.log("written to", path);
    }

    /// 1 tWETH = ETH_PRICE tUSDC, as a raw token1/token0 price.
    function _sqrtPriceX96(bool usdcIsToken0) internal pure returns (uint160) {
        uint256 num = usdcIsToken0 ? 1e18 : ETH_PRICE * 1e6;
        uint256 den = usdcIsToken0 ? ETH_PRICE * 1e6 : 1e18;
        return uint160(Math.sqrt(FullMath.mulDiv(num, 1 << 192, den)));
    }
}
