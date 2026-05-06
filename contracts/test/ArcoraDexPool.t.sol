// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ArcoraDexPool }       from "../src/ArcoraDexPool.sol";
import { ArcoraDexRegistry }   from "../src/ArcoraDexRegistry.sol";
import { ArcoraDexLP }         from "../src/ArcoraDexLP.sol";
import { IArcoraDexPool }      from "../src/interfaces/IArcoraDexPool.sol";
import { IArcoraDexRegistry }  from "../src/interfaces/IArcoraDexRegistry.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MintableERC20 }       from "../src/testnet/MintableERC20.sol";
import { MockChainlinkFeed }   from "../src/testnet/MockChainlinkFeed.sol";

contract ArcoraDexPoolTest is Test {
    ArcoraDexPool     pool;
    ArcoraDexRegistry reg;
    ArcoraDexLP       lp;
    MintableERC20 usdc; MockChainlinkFeed fUsdc;
    MintableERC20 eurc; MockChainlinkFeed fEurc;
    MintableERC20 dai;  MockChainlinkFeed fDai;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint16 constant SWAP_FEE_BPS_DEFAULT = 30;
    uint16 constant PROT_SHARE_DEFAULT   = 1000; // 10%

    function setUp() public {
        // Tokens (decimals: USDC=6, EURC=6, DAI=18). 4-arg MintableERC20 ctor.
        usdc = new MintableERC20("USD Coin",    "USDC", 6,  owner);
        eurc = new MintableERC20("Euro Coin",   "EURC", 6,  owner);
        dai  = new MintableERC20("Dai",         "DAI",  18, owner);
        // Feeds (decimals first, answer second). Initial: 1.00 USD, 1.10 USD, 1.00 USD.
        fUsdc = new MockChainlinkFeed(8, int256(1e8));
        fEurc = new MockChainlinkFeed(8, int256(11e7));
        fDai  = new MockChainlinkFeed(8, int256(1e8));

        reg  = new ArcoraDexRegistry(owner);
        pool = new ArcoraDexPool(address(reg), SWAP_FEE_BPS_DEFAULT, PROT_SHARE_DEFAULT, owner);
        lp   = ArcoraDexLP(address(pool.LP()));

        vm.startPrank(owner);
        reg.listToken(address(usdc), 6,  IChainlinkAggregator(address(fUsdc)),  50);
        reg.listToken(address(eurc), 6,  IChainlinkAggregator(address(fEurc)), 150);
        reg.listToken(address(dai),  18, IChainlinkAggregator(address(fDai)),   50);
        vm.stopPrank();

        // Mint to alice/bob via owner (MintableERC20 mint may be owner-only — check).
        vm.startPrank(owner);
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob,   10_000e6);
        eurc.mint(alice, 10_000e6);
        dai.mint (alice, 10_000e18);
        vm.stopPrank();
    }

    // ── Constructor / wiring ─────────────────────────────────────────
    function test_constructor_setsImmutables() public view {
        assertEq(address(pool.REGISTRY()), address(reg));
        assertEq(address(pool.LP()),       address(lp));
        assertEq(pool.swapFeeBps(),        SWAP_FEE_BPS_DEFAULT);
        assertEq(pool.protocolFeeShareBps(), PROT_SHARE_DEFAULT);
        assertFalse(pool.paused());
        assertEq(lp.MINTER(), address(pool));
        assertEq(lp.totalSupply(), 0);
    }

    function test_constructor_revertsBadFee() public {
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.InvalidFeeBps.selector, uint16(101)));
        new ArcoraDexPool(address(reg), 101, PROT_SHARE_DEFAULT, owner);
    }

    function test_constructor_revertsBadProtocolShare() public {
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.InvalidProtocolFeeShareBps.selector, uint16(2501)));
        new ArcoraDexPool(address(reg), SWAP_FEE_BPS_DEFAULT, 2501, owner);
    }

    // ── deposit (first deposit + subsequent) ─────────────────────────
    function test_deposit_first_burns_minimum_liquidity_and_mints_residual() public {
        // Alice deposits 1000 USDC at $1.00 → usdValue = 1000 * 1e18.
        uint256 amount = 1000e6;
        vm.startPrank(alice);
        usdc.approve(address(pool), amount);
        uint256 lpMinted = pool.deposit(address(usdc), amount, 0, block.timestamp);
        vm.stopPrank();

        // Expected: usdValue 1000e18; user gets 1000e18 - 1000.
        assertEq(lpMinted, 1000e18 - 1000);
        assertEq(lp.balanceOf(alice), 1000e18 - 1000);
        assertEq(lp.balanceOf(address(0xdead)), 1000);
        assertEq(lp.totalSupply(), 1000e18);
        assertEq(pool.reserves(address(usdc)), amount);
    }

    function test_deposit_first_revertsTooSmall() public {
        // Use DAI (18 dec). 999 wei DAI at $1 = 999 USD-1e18 → < 1000 ⇒ revert.
        // Mint a tiny amount to alice.
        vm.prank(owner);
        dai.mint(alice, 1000);
        vm.startPrank(alice);
        dai.approve(address(pool), 999);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.FirstDepositTooSmall.selector, uint256(999), uint256(1000)));
        pool.deposit(address(dai), 999, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_deposit_second_proportional() public {
        // Seed first
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.deposit(address(usdc), 1000e6, 0, block.timestamp);
        vm.stopPrank();
        uint256 supplyAfter1 = lp.totalSupply();
        uint256 navAfter1    = pool.totalReservesUSD();

        // Bob deposits 500 USDC. lpMinted = 500e18 * supply / nav.
        vm.startPrank(bob);
        usdc.approve(address(pool), 500e6);
        uint256 lpMintedBob = pool.deposit(address(usdc), 500e6, 0, block.timestamp);
        vm.stopPrank();

        assertEq(lpMintedBob, (500e18 * supplyAfter1) / navAfter1);
        assertEq(lp.balanceOf(bob), lpMintedBob);
    }

    function test_deposit_revertsSlippage() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        // First deposit yields 1000e18 - 1000; require minLpOut = 1000e18 (impossible).
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.InsufficientLpOut.selector, uint256(1000e18 - 1000), uint256(1000e18)));
        pool.deposit(address(usdc), 1000e6, 1000e18, block.timestamp);
        vm.stopPrank();
    }

    function test_deposit_revertsInactive() public {
        vm.prank(owner);
        reg.deactivateToken(address(usdc));

        vm.startPrank(alice);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.TokenNotActive.selector, address(usdc)));
        pool.deposit(address(usdc), 100e6, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_deposit_revertsZeroAmount() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1);
        vm.expectRevert(IArcoraDexPool.ZeroAmount.selector);
        pool.deposit(address(usdc), 0, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_deposit_revertsDeadlinePassed() public {
        vm.warp(2_000);
        vm.startPrank(alice);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(IArcoraDexPool.DeadlinePassed.selector);
        pool.deposit(address(usdc), 100e6, 0, 1_000);
        vm.stopPrank();
    }

    // ── withdraw ─────────────────────────────────────────────────────
    function test_withdraw_singleToken_chargesSwapFeeBps() public {
        // Seed with 2000 USDC
        vm.startPrank(alice);
        usdc.approve(address(pool), 2000e6);
        pool.deposit(address(usdc), 2000e6, 0, block.timestamp);
        uint256 aliceLp = lp.balanceOf(alice);

        // Withdraw half as USDC.
        uint256 lpToBurn = aliceLp / 2;
        uint256 amountOut = pool.withdraw(address(usdc), lpToBurn, 0, block.timestamp);
        vm.stopPrank();

        // After fee = 30 bps: amountOut ≈ 1000e18 * (10000-30)/10000 = 997e18 USD; in USDC ≈ 997e6.
        assertGt(amountOut, 996e6);
        assertLt(amountOut, 998e6);
        assertEq(lp.balanceOf(alice), aliceLp - lpToBurn);
    }

    function test_withdraw_revertsInsufficientReserves() public {
        // Deposit USDC, try to withdraw EURC (no reserves)
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.deposit(address(usdc), 1000e6, 0, block.timestamp);
        vm.expectRevert();   // InsufficientLiquidity
        pool.withdraw(address(eurc), 100e18, 0, block.timestamp);
        vm.stopPrank();
    }

    // ── pause / unpause ──────────────────────────────────────────────
    function test_pause_blocksDepositWithdraw() public {
        vm.prank(owner);
        pool.pause();
        assertTrue(pool.paused());

        vm.startPrank(alice);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(IArcoraDexPool.PoolPaused.selector);
        pool.deposit(address(usdc), 100e6, 0, block.timestamp);
        vm.stopPrank();

        vm.prank(owner);
        pool.unpause();
        assertFalse(pool.paused());
    }

    // ── setProtocolFeeShareBps cap ───────────────────────────────────
    function test_setProtocolFeeShareBps_revertsAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.InvalidProtocolFeeShareBps.selector, uint16(2501)));
        pool.setProtocolFeeShareBps(2501);
    }

    function test_setProtocolFeeShareBps_updates() public {
        vm.prank(owner);
        pool.setProtocolFeeShareBps(2000);
        assertEq(pool.protocolFeeShareBps(), 2000);
    }

    // ── quote ───────────────────────────────────────────────────────
    function test_quote_USDC_to_EURC_oracle_price() public {
        // 1.00 USDC → 1.10 EUR per EURC oracle. amount = 110 USDC, expected gross = 100 EURC, net = 100 * (10000-30)/10000 = 99.7 EURC.
        uint256 amountIn  = 110e6;       // 110 USDC
        uint256 amountOut = pool.quote(address(usdc), address(eurc), amountIn);
        // gross = 110e18 (USD value) / 1.10 (EURC price 1.1e18) * 1e6 ≈ 100e6
        // net   = 100e6 * 9970/10000 = 99.7e6
        assertApproxEqAbs(amountOut, 99_700_000, 100);
    }

    function test_quote_USDC_to_DAI_decimals_6_to_18() public {
        // Both at $1.00. 100 USDC → ~99.7 DAI (after 30 bps swap fee).
        uint256 amountIn  = 100e6;
        uint256 amountOut = pool.quote(address(usdc), address(dai), amountIn);
        // gross = 100e18; net = 100e18 * 9970/10000 = 99.7e18
        assertApproxEqAbs(amountOut, 99_700_000_000_000_000_000, 1e12);
    }

    function test_quote_revertsSameToken() public {
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.SameToken.selector, address(usdc)));
        pool.quote(address(usdc), address(usdc), 1e6);
    }

    function test_quote_revertsZeroAmount() public {
        vm.expectRevert(IArcoraDexPool.ZeroAmount.selector);
        pool.quote(address(usdc), address(eurc), 0);
    }

    function test_quote_revertsInactiveOut() public {
        vm.prank(owner);
        reg.deactivateToken(address(eurc));
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.TokenNotActive.selector, address(eurc)));
        pool.quote(address(usdc), address(eurc), 100e6);
    }

    function test_quoteDeposit_first_deduct_minimum_liquidity() public view {
        uint256 lpOut = pool.quoteDeposit(address(usdc), 1000e6);
        assertEq(lpOut, 1000e18 - 1000);
    }

    function test_quoteDeposit_proportional_after_seed() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.deposit(address(usdc), 1000e6, 0, block.timestamp);
        vm.stopPrank();

        uint256 lpOut = pool.quoteDeposit(address(usdc), 500e6);
        uint256 expected = (500e18 * lp.totalSupply()) / pool.totalReservesUSD();
        assertEq(lpOut, expected);
    }

    function test_quoteWithdraw_returns_amount_and_fee() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 2000e6);
        pool.deposit(address(usdc), 2000e6, 0, block.timestamp);
        uint256 lpToBurn = lp.balanceOf(alice) / 2;
        (uint256 amountOut, uint256 fee) = pool.quoteWithdraw(address(usdc), lpToBurn);
        vm.stopPrank();
        assertGt(amountOut, 996e6);
        assertLt(amountOut, 998e6);
        assertGt(fee, 0);     // protocol's 10% of 30 bps fee on ~1000 USDC
    }

    // ── swap ────────────────────────────────────────────────────────
    function _seedAllThree() internal {
        // Owner-style seeding via a generous Alice deposit across all tokens
        vm.startPrank(alice);
        usdc.approve(address(pool), 5_000e6);
        eurc.approve(address(pool), 5_000e6);
        dai .approve(address(pool), 5_000e18);
        pool.deposit(address(usdc), 5_000e6,  0, block.timestamp);
        pool.deposit(address(eurc), 5_000e6,  0, block.timestamp);
        pool.deposit(address(dai),  5_000e18, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_swap_USDC_to_EURC_amountOut_matches_quote() public {
        _seedAllThree();
        uint256 amountIn = 110e6; // 110 USDC

        uint256 expected = pool.quote(address(usdc), address(eurc), amountIn);

        // Bob swaps
        vm.prank(owner);
        usdc.mint(bob, amountIn);
        vm.startPrank(bob);
        usdc.approve(address(pool), amountIn);
        uint256 amountOut = pool.swap(address(usdc), address(eurc), amountIn, 0, block.timestamp, bob);
        vm.stopPrank();

        assertEq(amountOut, expected);
        assertEq(eurc.balanceOf(bob), amountOut);
    }

    function test_swap_charges_protocol_fee_in_tokenOut() public {
        _seedAllThree();
        uint256 amountIn = 100e6;

        uint256 protBefore = pool.protocolFeesAccrued(address(eurc));

        vm.prank(owner);
        usdc.mint(bob, amountIn);
        vm.startPrank(bob);
        usdc.approve(address(pool), amountIn);
        pool.swap(address(usdc), address(eurc), amountIn, 0, block.timestamp, bob);
        vm.stopPrank();

        uint256 protAfter = pool.protocolFeesAccrued(address(eurc));
        assertGt(protAfter, protBefore);
        // Protocol's share of total fee is protocolFeeShareBps (default 1000 = 10%).
        // Total fee in EURC ≈ swapFeeBps fraction of gross output ≈ 0.30% of ~90.9 EURC ≈ 0.273 EURC.
        // Protocol share ≈ 10% of that ≈ 0.0273 EURC = ~27_300 (6 dec).
        uint256 fee = protAfter - protBefore;
        assertGt(fee, 25_000);
        assertLt(fee, 30_000);
    }

    function test_swap_revertsSlippage() public {
        _seedAllThree();
        uint256 amountIn = 100e6;

        vm.prank(owner);
        usdc.mint(bob, amountIn);
        vm.startPrank(bob);
        usdc.approve(address(pool), amountIn);
        // Overly aggressive minOut
        vm.expectRevert();
        pool.swap(address(usdc), address(eurc), amountIn, 1_000_000_000_000, block.timestamp, bob);
        vm.stopPrank();
    }

    function test_swap_revertsDeadlinePassed() public {
        _seedAllThree();
        vm.warp(2_000);
        vm.prank(owner);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(IArcoraDexPool.DeadlinePassed.selector);
        pool.swap(address(usdc), address(eurc), 100e6, 0, 1_000, bob);
        vm.stopPrank();
    }

    function test_swap_revertsSameToken() public {
        _seedAllThree();
        vm.prank(owner);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.SameToken.selector, address(usdc)));
        pool.swap(address(usdc), address(usdc), 100e6, 0, block.timestamp, bob);
        vm.stopPrank();
    }

    function test_swap_revertsInactiveIn() public {
        _seedAllThree();
        vm.prank(owner);
        reg.deactivateToken(address(usdc));
        vm.prank(owner);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.TokenNotActive.selector, address(usdc)));
        pool.swap(address(usdc), address(eurc), 100e6, 0, block.timestamp, bob);
        vm.stopPrank();
    }

    function test_swap_paused_reverts() public {
        _seedAllThree();
        vm.prank(owner);
        pool.pause();
        vm.prank(owner);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(IArcoraDexPool.PoolPaused.selector);
        pool.swap(address(usdc), address(eurc), 100e6, 0, block.timestamp, bob);
        vm.stopPrank();
    }

    function test_swap_recipient_receives() public {
        _seedAllThree();
        address charlie = makeAddr("charlie");
        vm.prank(owner);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 100e6);
        uint256 outAmt = pool.swap(address(usdc), address(eurc), 100e6, 0, block.timestamp, charlie);
        vm.stopPrank();
        assertEq(eurc.balanceOf(charlie), outAmt);
        assertEq(eurc.balanceOf(bob), 0);
    }
}
