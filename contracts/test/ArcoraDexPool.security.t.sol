// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ArcoraDexPool }      from "../src/ArcoraDexPool.sol";
import { ArcoraDexRegistry }  from "../src/ArcoraDexRegistry.sol";
import { ArcoraDexLP }        from "../src/ArcoraDexLP.sol";
import { IArcoraDexPool }     from "../src/interfaces/IArcoraDexPool.sol";
import { MockChainlinkFeedV2 } from "../src/testnet/MockChainlinkFeedV2.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

contract ArcoraDexPoolSecurityTest is Test {
    ArcoraDexRegistry reg;
    ArcoraDexPool     pool;
    MockERC20         usdc;
    MockERC20         eurc;
    MockChainlinkFeedV2 fUsdc;
    MockChainlinkFeedV2 fEurc;
    address constant DEPLOYER = address(0xD3);
    address constant ALICE    = address(0xA1);

    function setUp() public {
        vm.startPrank(DEPLOYER);
        reg   = new ArcoraDexRegistry(DEPLOYER);
        usdc  = new MockERC20("USDC", "USDC", 6);
        eurc  = new MockERC20("EURC", "EURC", 6);
        fUsdc = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER);  // $1.00
        fEurc = new MockChainlinkFeedV2(8, 110_000_000, DEPLOYER, DEPLOYER);  // $1.10
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(fUsdc)),  50, 3600);
        reg.listToken(address(eurc), 6, IChainlinkAggregator(address(fEurc)), 150, 14400);
        pool = new ArcoraDexPool(address(reg), 5, 2500, DEPLOYER);
        vm.stopPrank();
    }

    function test_stale_feed_falls_back_to_cache() public {
        // Seed cache via a deposit on USDC and EURC
        usdc.mint(ALICE, 1_000_000_000); // 1000 USDC
        eurc.mint(ALICE, 1_000_000_000); // 1000 EURC
        vm.startPrank(ALICE);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60);
        pool.deposit(address(eurc), 100_000_000, 0, block.timestamp + 60);
        vm.stopPrank();

        // Advance time so EURC oracle (4h budget) becomes stale
        vm.warp(block.timestamp + 5 hours);

        // NAV should still compute using the cached EURC price
        uint256 nav = pool.totalReservesUSD();
        assertGt(nav, 0, "NAV must remain queryable with stale feed");

        // Cached price for EURC should be the seeded $1.10 (1.1e18)
        assertEq(pool.lastValidPrice(address(eurc)), 1.1e18);
    }

    function test_no_valid_price_reverts_when_never_seeded() public {
        // Seed USDC + EURC caches so the iteration doesn't revert on them first
        usdc.mint(ALICE, 1_000_000_000);
        eurc.mint(ALICE, 1_000_000_000);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60);
        pool.deposit(address(eurc), 100_000_000, 0, block.timestamp + 60);
        vm.stopPrank();

        // List DAI with a very tight stale window (60s) but never deposit / seed its cache
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockChainlinkFeedV2 fDai = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER);
        vm.prank(DEPLOYER);
        reg.listToken(address(dai), 18, IChainlinkAggregator(address(fDai)), 50, 60); // 1-minute window

        // Warp 120s — DAI oracle is stale, USDC/EURC are still fresh (3600s / 14400s budgets)
        vm.warp(block.timestamp + 120);

        // Iteration reaches DAI and reverts NoValidPrice(dai) specifically
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.NoValidPrice.selector, address(dai)));
        pool.totalReservesUSD();
    }
}
