// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ArcoraDexPool }       from "../src/ArcoraDexPool.sol";
import { ArcoraDexRegistry }   from "../src/ArcoraDexRegistry.sol";
import { ArcoraDexLP }         from "../src/ArcoraDexLP.sol";
import { IArcoraDexPool }      from "../src/interfaces/IArcoraDexPool.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MintableERC20 }       from "../src/testnet/MintableERC20.sol";
import { MockChainlinkFeed }   from "../src/testnet/MockChainlinkFeed.sol";

contract ArcoraDexPoolFuzz is Test {
    ArcoraDexPool     pool;
    ArcoraDexRegistry reg;
    ArcoraDexLP       lp;
    MintableERC20 usdc; MockChainlinkFeed fUsdc;
    MintableERC20 eurc; MockChainlinkFeed fEurc;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        usdc  = new MintableERC20("USD Coin",  "USDC", 6,  owner);
        eurc  = new MintableERC20("Euro Coin", "EURC", 6,  owner);
        fUsdc = new MockChainlinkFeed(8, int256(1e8));
        fEurc = new MockChainlinkFeed(8, int256(11e7));

        reg  = new ArcoraDexRegistry(owner);
        pool = new ArcoraDexPool(address(reg), 30, 1000, owner);
        lp   = ArcoraDexLP(address(pool.LP()));

        vm.startPrank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(fUsdc)),  50);
        reg.listToken(address(eurc), 6, IChainlinkAggregator(address(fEurc)), 150);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob,   1_000_000e6);
        eurc.mint(alice, 1_000_000e6);
        vm.stopPrank();
    }

    /// Deposit then immediate single-token withdraw of the same token loses at most ~swapFeeBps + tiny rounding.
    function testFuzz_deposit_then_withdraw_preserves_value(uint96 amountIn) public {
        amountIn = uint96(bound(amountIn, 10_000e6, 100_000e6));   // 10k–100k USDC

        vm.startPrank(alice);
        usdc.approve(address(pool), amountIn);
        uint256 lpMinted = pool.deposit(address(usdc), amountIn, 0, block.timestamp);
        uint256 amountOut = pool.withdraw(address(usdc), lpMinted, 0, block.timestamp);
        vm.stopPrank();

        // Round-trip charges swapFeeBps once (on withdraw). Loss should be <= 30 bps + slack for first-deposit MIN_LIQUIDITY burn.
        assertGe(amountOut, (uint256(amountIn) * (10_000 - 31)) / 10_000);
        assertLe(amountOut, amountIn);
    }

    /// quote() and the actual swap() return the same amountOut for identical inputs.
    function testFuzz_quote_matches_swap(uint96 amountIn) public {
        amountIn = uint96(bound(amountIn, 1e6, 1_000e6));
        // Seed liquidity
        vm.startPrank(alice);
        usdc.approve(address(pool), 100_000e6);
        eurc.approve(address(pool), 100_000e6);
        pool.deposit(address(usdc), 100_000e6, 0, block.timestamp);
        pool.deposit(address(eurc), 100_000e6, 0, block.timestamp);
        vm.stopPrank();

        uint256 expected = pool.quote(address(usdc), address(eurc), amountIn);

        vm.prank(owner);
        usdc.mint(bob, amountIn);
        vm.startPrank(bob);
        usdc.approve(address(pool), amountIn);
        uint256 actual = pool.swap(address(usdc), address(eurc), amountIn, 0, block.timestamp, bob);
        vm.stopPrank();

        assertEq(actual, expected);
    }

    /// Larger amountIn yields >= amountOut (monotonic).
    function testFuzz_swap_monotonic(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1e6, 1_000e6));
        b = uint96(bound(b, 1e6, 1_000e6));
        if (a >= b) return;

        vm.startPrank(alice);
        usdc.approve(address(pool), 100_000e6);
        eurc.approve(address(pool), 100_000e6);
        pool.deposit(address(usdc), 100_000e6, 0, block.timestamp);
        pool.deposit(address(eurc), 100_000e6, 0, block.timestamp);
        vm.stopPrank();

        uint256 outA = pool.quote(address(usdc), address(eurc), a);
        uint256 outB = pool.quote(address(usdc), address(eurc), b);
        assertLe(outA, outB);
    }

    /// Two LPs depositing different USD amounts: their LP balances must be proportional to USD contribution.
    function testFuzz_lp_share_proportional(uint96 amtA, uint96 amtB) public {
        amtA = uint96(bound(amtA, 10_000e6, 100_000e6));
        amtB = uint96(bound(amtB, 10_000e6, 100_000e6));

        vm.startPrank(alice);
        usdc.approve(address(pool), amtA);
        uint256 lpA = pool.deposit(address(usdc), amtA, 0, block.timestamp);
        vm.stopPrank();

        vm.prank(owner);
        usdc.mint(bob, amtB);
        vm.startPrank(bob);
        usdc.approve(address(pool), amtB);
        uint256 lpB = pool.deposit(address(usdc), amtB, 0, block.timestamp);
        vm.stopPrank();

        // Property: ratio of lpA : lpB closely matches amtA : amtB (within rounding + 1000-LP burn dilution).
        uint256 ratioLp_e18  = (uint256(lpB) * 1e18) / lpA;
        uint256 ratioUsd_e18 = (uint256(amtB) * 1e18) / amtA;
        uint256 diff = ratioLp_e18 > ratioUsd_e18 ? ratioLp_e18 - ratioUsd_e18 : ratioUsd_e18 - ratioLp_e18;
        assertLe(diff, 1e15);   // 0.1% tolerance
    }

    /// With any valid protocolFeeShareBps (≤ 2500), protocol's share of total fee is ≤ 25%.
    function testFuzz_protocol_fee_at_most_25pct(uint96 amountIn, uint16 shareBps) public {
        amountIn = uint96(bound(amountIn, 1e6, 1_000e6));
        shareBps = uint16(bound(shareBps, 0, 2500));

        vm.prank(owner);
        pool.setProtocolFeeShareBps(shareBps);

        vm.startPrank(alice);
        usdc.approve(address(pool), 100_000e6);
        eurc.approve(address(pool), 100_000e6);
        pool.deposit(address(usdc), 100_000e6, 0, block.timestamp);
        pool.deposit(address(eurc), 100_000e6, 0, block.timestamp);
        vm.stopPrank();

        uint256 protBefore = pool.protocolFeesAccrued(address(eurc));
        vm.prank(owner);
        usdc.mint(bob, amountIn);
        vm.startPrank(bob);
        usdc.approve(address(pool), amountIn);
        uint256 actual = pool.swap(address(usdc), address(eurc), amountIn, 0, block.timestamp, bob);
        vm.stopPrank();
        uint256 protDelta = pool.protocolFeesAccrued(address(eurc)) - protBefore;

        // Total fee (in tokenOut) is approximately:
        //   gross ≈ actual / (1 - swapFeeBps/BPS) ≈ actual + (actual * swapFeeBps) / (BPS - swapFeeBps)
        uint256 totalFee = (actual * 30) / (10_000 - 30);
        // Strict: protDelta <= totalFee / 4 + tiny rounding
        assertLe(protDelta, totalFee / 4 + 1);
    }
}
