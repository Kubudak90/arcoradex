// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test }              from "forge-std/Test.sol";
import { StdInvariant }      from "forge-std/StdInvariant.sol";
import { ArcoraDexPool }     from "../src/ArcoraDexPool.sol";
import { ArcoraDexRegistry } from "../src/ArcoraDexRegistry.sol";
import { ArcoraDexLP }       from "../src/ArcoraDexLP.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MintableERC20 }     from "../src/testnet/MintableERC20.sol";
import { MockChainlinkFeed } from "../src/testnet/MockChainlinkFeed.sol";
import { PoolHandler }       from "./handlers/PoolHandler.sol";

contract ArcoraDexPoolInvariant is StdInvariant, Test {
    ArcoraDexPool     pool;
    ArcoraDexRegistry reg;
    ArcoraDexLP       lp;
    MintableERC20     usdc; MockChainlinkFeed fUsdc;
    MintableERC20     eurc; MockChainlinkFeed fEurc;
    MintableERC20     dai;  MockChainlinkFeed fDai;
    address owner = makeAddr("owner");
    PoolHandler handler;

    address a1 = makeAddr("a1");
    address a2 = makeAddr("a2");
    address a3 = makeAddr("a3");

    function setUp() public {
        usdc = new MintableERC20("USDC", "USDC", 6,  owner);
        eurc = new MintableERC20("EURC", "EURC", 6,  owner);
        dai  = new MintableERC20("DAI",  "DAI",  18, owner);
        fUsdc = new MockChainlinkFeed(8, int256(1e8));
        fEurc = new MockChainlinkFeed(8, int256(11e7));
        fDai  = new MockChainlinkFeed(8, int256(1e8));

        reg  = new ArcoraDexRegistry(owner);
        pool = new ArcoraDexPool(address(reg), 30, 1000, owner);
        lp   = ArcoraDexLP(address(pool.LP()));

        vm.startPrank(owner);
        reg.listToken(address(usdc), 6,  IChainlinkAggregator(address(fUsdc)),  50,  3600);
        reg.listToken(address(eurc), 6,  IChainlinkAggregator(address(fEurc)), 150, 14400);
        reg.listToken(address(dai), 18,  IChainlinkAggregator(address(fDai)),   50,  3600);
        vm.stopPrank();

        // Pre-mint generous balances to each actor (handler can't mint due to onlyOwner).
        vm.startPrank(owner);
        for (uint256 i = 0; i < 3; i++) {
            address actor = i == 0 ? a1 : (i == 1 ? a2 : a3);
            usdc.mint(actor, 1_000_000e6);
            eurc.mint(actor, 1_000_000e6);
            dai .mint(actor, 1_000_000e18);
        }
        vm.stopPrank();

        // Seed minimal initial liquidity so first-deposit guard doesn't dominate the run.
        address seeder = makeAddr("seeder");
        vm.prank(owner);
        usdc.mint(seeder, 100_000e6);
        vm.prank(owner);
        eurc.mint(seeder, 100_000e6);
        vm.prank(owner);
        dai .mint(seeder, 100_000e18);
        vm.startPrank(seeder);
        usdc.approve(address(pool), 100_000e6);
        eurc.approve(address(pool), 100_000e6);
        dai .approve(address(pool), 100_000e18);
        pool.deposit(address(usdc), 100_000e6,  0, block.timestamp + 1);
        pool.deposit(address(eurc), 100_000e6,  0, block.timestamp + 1);
        pool.deposit(address(dai),  100_000e18, 0, block.timestamp + 1);
        vm.stopPrank();

        // Build handler
        address[] memory actors = new address[](3);
        actors[0] = a1; actors[1] = a2; actors[2] = a3;
        address[] memory tks = new address[](3);
        tks[0] = address(usdc); tks[1] = address(eurc); tks[2] = address(dai);
        handler = new PoolHandler(address(pool), address(lp), actors, tks);
        targetContract(address(handler));
    }

    /// Contract balance of every token equals reserves + protocolFeesAccrued.
    function invariant_balance_equals_reserves_plus_fees() public view {
        address[3] memory tks = [address(usdc), address(eurc), address(dai)];
        for (uint256 i = 0; i < tks.length; i++) {
            uint256 bal  = MintableERC20(tks[i]).balanceOf(address(pool));
            uint256 res  = pool.reserves(tks[i]);
            uint256 fees = pool.protocolFeesAccrued(tks[i]);
            assertEq(bal, res + fees, "balance != reserves + fees");
        }
    }

    /// (totalSupply == 0) <-> (nav == 0).
    function invariant_supply_nav_link() public view {
        uint256 supply = lp.totalSupply();
        uint256 nav    = pool.totalReservesUSD();
        if (supply == 0) assertEq(nav, 0, "supply==0 but nav!=0");
        else             assertGt(nav, 0, "supply>0 but nav==0");
    }

    /// fees <= contract balance per token.
    function invariant_fees_le_balance() public view {
        address[3] memory tks = [address(usdc), address(eurc), address(dai)];
        for (uint256 i = 0; i < tks.length; i++) {
            uint256 fees = pool.protocolFeesAccrued(tks[i]);
            uint256 bal  = MintableERC20(tks[i]).balanceOf(address(pool));
            assertLe(fees, bal, "fees > balance");
        }
    }

    /// MINIMUM_LIQUIDITY (1000 LP) is permanently held by 0xdead after any first deposit.
    function invariant_lp_minimum_liquidity_burned() public view {
        uint256 supply = lp.totalSupply();
        if (supply == 0) return;
        assertGe(lp.balanceOf(address(0xdead)), 1000, "MIN_LIQUIDITY burn missing");
    }
}
