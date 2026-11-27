// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Lease} from "../../src/types/CharterTypes.sol";
import {Fixture} from "../utils/Fixture.sol";
import {Handler} from "./Handler.sol";

/// forge-config: default.invariant.depth = 128
contract CharterInvariants is Fixture {
    using PoolIdLibrary for PoolKey;

    Handler handler;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public override {
        super.setUp();
        _lp(FL, FU, 1000e18);
        _lp(-1200, 1200, 3000e18);
        vm.prank(alice);
        charter.deposit(1000e18, type(uint256).max, type(uint256).max, alice);
        handler = new Handler(charter, swapRouter, key, [alice, bob, carol, mallory]);
        targetContract(address(handler));
    }

    function invariant_claimsLedgerBalances() public view {
        assertEq(
            manager.balanceOf(address(charter), currency0.toId()),
            charter.idle0() + charter.totalHeld0(),
            "token0 claims"
        );
        assertEq(
            manager.balanceOf(address(charter), currency1.toId()),
            charter.idle1() + charter.totalHeld1() + charter.totalBond() + charter.totalEscrow(),
            "token1 claims"
        );
    }

    function invariant_totalsMatchTheLeases() public view {
        uint256 units;
        uint256 held0;
        uint256 held1;
        uint256 bonds;
        uint256 escrow;
        uint256 liquidity;
        for (uint256 s; s < MAX_LEASES; s++) {
            Lease memory l = charter.lease(s);
            units += l.units;
            held0 += l.held0;
            held1 += l.held1;
            bonds += l.bond;
            liquidity += l.liquidity;
            escrow += charter.pendingBid(s).bond;
            if (l.manager == address(0)) {
                assertEq(l.units + l.liquidity + l.bond + l.held0 + l.held1, 0, "an empty slot is fully empty");
            }
        }
        assertEq(charter.leasedUnits(), units, "leased units");
        assertEq(charter.totalHeld0(), held0, "held0");
        assertEq(charter.totalHeld1(), held1, "held1");
        assertEq(charter.totalBond(), bonds, "bonds");
        assertEq(charter.totalEscrow(), escrow, "escrow");
        assertEq(charter.managedLiquidity(), liquidity, "managed liquidity");
    }

    function invariant_uniswapAgreesWithTheBooks() public view {
        PoolId id = key.toId();
        bytes32 passive = keccak256(abi.encodePacked(address(charter), FL, FU, bytes32(0)));
        assertEq(StateLibrary.getPositionLiquidity(manager, id, passive), charter.passiveLiquidity(), "passive");
        for (uint256 s; s < MAX_LEASES; s++) {
            Lease memory l = charter.lease(s);
            if (l.liquidity == 0) continue;
            bytes32 pos = keccak256(abi.encodePacked(address(charter), l.tickLower, l.tickUpper, bytes32(s + 1)));
            assertEq(StateLibrary.getPositionLiquidity(manager, id, pos), l.liquidity, "lease position");
        }
    }

    /// The hook runs inside every swap, so a revert there would freeze the whole pool.
    function invariant_swapsNeverRevert() public view {
        assertEq(handler.swapFailures(), 0);
    }

    function invariant_sharesAddUp() public view {
        uint256 held = charter.balanceOf(DEAD) + charter.balanceOf(alice) + charter.balanceOf(bob)
            + charter.balanceOf(carol) + charter.balanceOf(mallory);
        assertEq(charter.totalSupply(), held);
    }

    function afterInvariant() external view {
        bytes4[13] memory sels = [
            handler.deposit.selector,
            handler.withdraw.selector,
            handler.swap.selector,
            handler.openLease.selector,
            handler.rebalance.selector,
            handler.exitLease.selector,
            handler.collectRent.selector,
            handler.bid.selector,
            handler.activate.selector,
            handler.cancelBid.selector,
            handler.liquidate.selector,
            handler.repassivate.selector,
            handler.passTime.selector
        ];
        string[13] memory names = [
            "deposit",
            "withdraw",
            "swap",
            "openLease",
            "rebalance",
            "exitLease",
            "collectRent",
            "bid",
            "activate",
            "cancelBid",
            "liquidate",
            "repassivate",
            "passTime"
        ];
        for (uint256 i; i < sels.length; i++) {
            console2.log(names[i], handler.succeeded(sels[i]));
        }
    }
}
