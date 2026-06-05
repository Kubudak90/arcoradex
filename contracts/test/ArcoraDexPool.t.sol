// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexPool} from "../src/ArcoraDexPool.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {ArcoraDexLP} from "../src/ArcoraDexLP.sol";
import {IArcoraDexPool} from "../src/interfaces/IArcoraDexPool.sol";
import {IArcoraDexRegistry} from "../src/interfaces/IArcoraDexRegistry.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {MockChainlinkFeed} from "../src/testnet/MockChainlinkFeed.sol";
import {RevertingMockFeed} from "./oracle/RevertingMockFeed.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ArcoraDexPoolTest is Test {
    ArcoraDexPool pool;
    ArcoraDexRegistry reg;
    ArcoraDexLP lp;
    MintableERC20 usdc;
    MockChainlinkFeed fUsdc;
    MintableERC20 eurc;
    MockChainlinkFeed fEurc;
    MintableERC20 dai;
    MockChainlinkFeed fDai;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint16 constant SWAP_FEE_BPS_DEFAULT = 30;
    uint16 constant PROT_SHARE_DEFAULT = 1000; // 10%

    function setUp() public {
        // Tokens (decimals: USDC=6, EURC=6, DAI=18). 4-arg MintableERC20 ctor.
        usdc = new MintableERC20("USD Coin", "USDC", 6, owner);
        eurc = new MintableERC20("Euro Coin", "EURC", 6, owner);
        dai = new MintableERC20("Dai", "DAI", 18, owner);
        // Feeds (decimals first, answer second). Initial: 1.00 USD, 1.10 USD, 1.00 USD.
        fUsdc = new MockChainlinkFeed(8, int256(1e8));
        fEurc = new MockChainlinkFeed(8, int256(11e7));
        fDai = new MockChainlinkFeed(8, int256(1e8));

        reg = new ArcoraDexRegistry(owner);
        pool = new ArcoraDexPool(address(reg), SWAP_FEE_BPS_DEFAULT, PROT_SHARE_DEFAULT, owner);
        lp = ArcoraDexLP(address(pool.LP()));

        vm.startPrank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(fUsdc)), 50, 3600);
        reg.listToken(address(eurc), 6, IChainlinkAggregator(address(fEurc)), 150, 14400);
        reg.listToken(address(dai), 18, IChainlinkAggregator(address(fDai)), 50, 3600);
        vm.stopPrank();

        // Mint to alice/bob via owner (MintableERC20 mint may be owner-only — check).
        vm.startPrank(owner);
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        eurc.mint(alice, 10_000e6);
        dai.mint(alice, 10_000e18);
        vm.stopPrank();
    }

    // ── Constructor / wiring ─────────────────────────────────────────
    function test_constructor_setsImmutables() public view {
        assertEq(address(pool.REGISTRY()), address(reg));
        assertEq(address(pool.LP()), address(lp));
        assertEq(pool.swapFeeBps(), SWAP_FEE_BPS_DEFAULT);
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
        // Alice deposits 1000 USDC at $1.00 → usdValue = 1000e18.
        // With virtual shares: lpMinted = usdIn * VIRTUAL_SHARES / VIRTUAL_ASSETS = 1000e18 * 1e6 / 1 = 1000e24.
        uint256 amount = 1000e6;
        vm.startPrank(alice);
        usdc.approve(address(pool), amount);
        uint256 lpMinted = pool.deposit(address(usdc), amount, 0, block.timestamp);
        vm.stopPrank();

        // Expected: usdValue 1000e18; lpMinted = 1000e18 * 1e6 = 1000e24.
        assertEq(lpMinted, 1000e24);
        assertEq(lp.balanceOf(alice), 1000e24);
        assertEq(lp.balanceOf(address(0xdead)), 1000);
        assertEq(lp.totalSupply(), 1000e24 + 1000);
        assertEq(pool.reserves(address(usdc)), amount);
    }

    function test_deposit_first_revertsTooSmall() public {
        // Use DAI (18 dec). 999 wei DAI at $1 = 999 USD-1e18 → < 1000 ⇒ revert.
        // Mint a tiny amount to alice.
        vm.prank(owner);
        dai.mint(alice, 1000);
        vm.startPrank(alice);
        dai.approve(address(pool), 999);
        vm.expectRevert(
            abi.encodeWithSelector(IArcoraDexPool.FirstDepositTooSmall.selector, uint256(999), uint256(1000))
        );
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
        uint256 navAfter1 = pool.totalReservesUSD();

        // Bob deposits 500 USDC. lpMinted = 500e18 * (supply + VIRTUAL_SHARES) / (nav + VIRTUAL_ASSETS).
        // VIRTUAL_SHARES = 1e6, VIRTUAL_ASSETS = 1.
        vm.startPrank(bob);
        usdc.approve(address(pool), 500e6);
        uint256 lpMintedBob = pool.deposit(address(usdc), 500e6, 0, block.timestamp);
        vm.stopPrank();

        assertEq(lpMintedBob, (500e18 * (supplyAfter1 + 1e6)) / (navAfter1 + 1));
        assertEq(lp.balanceOf(bob), lpMintedBob);
    }

    function test_deposit_revertsSlippage() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        // First deposit yields 1000e24 (virtual shares); require minLpOut = 1000e24 + 1 (impossible).
        vm.expectRevert(
            abi.encodeWithSelector(IArcoraDexPool.InsufficientLpOut.selector, uint256(1000e24), uint256(1000e24 + 1))
        );
        pool.deposit(address(usdc), 1000e6, 1000e24 + 1, block.timestamp);
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

    // ── L-10: fee-on-transfer / deflationary token accounting ────────
    /// @notice The pool must credit the *measured* balance delta on inbound
    /// transfers, not the *requested* amount. A fee-on-transfer token delivers
    /// less than `amount`; crediting `amount` over-states reserves and breaks the
    /// `balance == reserves + fees` invariant (can freeze residual liquidity).
    function test_l10_depositCreditsReceivedNotRequested() public {
        // 100 bps (1%) fee-on-transfer token, 6 decimals, priced at $1.00.
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("Fee Token", "FOT", 6, owner, 100);
        MockChainlinkFeed fFot = new MockChainlinkFeed(8, int256(1e8));

        vm.prank(owner);
        reg.listToken(address(fot), 6, IChainlinkAggregator(address(fFot)), 50, 3600);

        uint256 amount = 1000e6;
        vm.prank(owner);
        fot.mint(alice, amount);

        // 1% burns on transfer-in → pool receives 990e6, not 1000e6.
        uint256 expectedReceived = amount - (amount * 100) / 10_000;
        assertEq(expectedReceived, 990e6);

        vm.startPrank(alice);
        fot.approve(address(pool), amount);
        pool.deposit(address(fot), amount, 0, block.timestamp);
        vm.stopPrank();

        // Pool actually holds the post-fee balance...
        assertEq(fot.balanceOf(address(pool)), expectedReceived, "pool balance must equal received");
        // ...and reserves must match it exactly (received, not requested).
        assertEq(pool.reserves(address(fot)), expectedReceived, "reserves must credit received, not requested");
    }

    /// @notice Swap path of L-10: when a fee-on-transfer token is swapped IN, the
    /// pool must credit only the *received* (post-fee) amount to its reserves AND
    /// compute the swap output from that received amount — not the requested
    /// `amountIn`. Crediting the requested amount would over-state reserves and
    /// hand the swapper more output than the pool actually received, draining LPs.
    function test_l10_swapCreditsReceivedInNotAmountIn() public {
        // 100 bps (1%) fee-on-transfer token IN, 6 decimals, priced at $1.00.
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("Fee Token", "FOT", 6, owner, 100);
        MockChainlinkFeed fFot = new MockChainlinkFeed(8, int256(1e8));
        vm.prank(owner);
        reg.listToken(address(fot), 6, IChainlinkAggregator(address(fFot)), 50, 3600);

        // Seed both sides with liquidity so the swap can execute. USDC is the
        // clean token OUT; FOT is seeded via a deposit (deposit credits received).
        uint256 fotSeed = 10_000e6;
        vm.prank(owner);
        fot.mint(alice, fotSeed);
        vm.startPrank(alice);
        usdc.approve(address(pool), 5_000e6);
        pool.deposit(address(usdc), 5_000e6, 0, block.timestamp);
        fot.approve(address(pool), fotSeed);
        pool.deposit(address(fot), fotSeed, 0, block.timestamp);
        vm.stopPrank();

        uint256 amountIn = 1000e6; // requested transfer amount
        // 1% burns on transfer-in → pool receives 990e6, not 1000e6.
        uint256 receivedIn = amountIn - (amountIn * 100) / 10_000;
        assertEq(receivedIn, 990e6);

        // Baseline output a *clean* token of the same size/price would yield:
        // quote the full requested amountIn (what the pool would credit if the
        // token had no transfer fee). FOT→USDC, both $1.00, both 6 dec.
        uint256 cleanOut = pool.quote(address(fot), address(usdc), amountIn);
        // Expected FOT output is consistent with the received (post-fee) amount.
        uint256 expectedFotOut = pool.quote(address(fot), address(usdc), receivedIn);
        assertLt(expectedFotOut, cleanOut, "received-amount quote must be below full-amount quote");

        uint256 reservesBefore = pool.reserves(address(fot));
        uint256 bobUsdcBefore = usdc.balanceOf(bob); // bob holds a setUp() balance

        // Bob swaps the FOT token IN, USDC OUT, minOut: 0.
        vm.prank(owner);
        fot.mint(bob, amountIn);
        vm.startPrank(bob);
        fot.approve(address(pool), amountIn);
        uint256 amountOut = pool.swap(address(fot), address(usdc), amountIn, 0, block.timestamp, bob);
        vm.stopPrank();

        // (a) reserves(fot) increased by the RECEIVED amount, not the requested.
        assertEq(
            pool.reserves(address(fot)) - reservesBefore,
            receivedIn,
            "reserves must increase by received (post-fee), not requested amountIn"
        );

        // (b) output was computed from the received amount: it matches the
        // received-amount quote, and is strictly lower than a clean-token swap
        // of the same requested size (output computed from 990e6, not 1000e6).
        assertEq(amountOut, expectedFotOut, "output must derive from received amount");
        assertLt(amountOut, cleanOut, "output must be below a fee-free swap of the same requested size");
        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, amountOut, "recipient receives the computed output");
    }

    // ── withdraw ─────────────────────────────────────────────────────
    function test_withdraw_singleToken_chargesSwapFeeBps() public {
        // Seed with 2000 USDC
        vm.startPrank(alice);
        usdc.approve(address(pool), 2000e6);
        pool.deposit(address(usdc), 2000e6, 0, block.timestamp);
        uint256 aliceLp = lp.balanceOf(alice);

        // Bypass MIN_HOLD_SECONDS (Task 4: 1-hour LP min-hold).
        // Warp exactly 1 hour so the hold expires without pushing past the
        // USDC oracle's maxStaleSeconds (also 3600 s). The check in withdraw()
        // is strict-less-than, so block.timestamp == unlockAt is allowed.
        vm.warp(block.timestamp + 1 hours);

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
        vm.expectRevert(); // InsufficientLiquidity
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
        uint256 amountIn = 110e6; // 110 USDC
        uint256 amountOut = pool.quote(address(usdc), address(eurc), amountIn);
        // gross = 110e18 (USD value) / 1.10 (EURC price 1.1e18) * 1e6 ≈ 100e6
        // net   = 100e6 * 9970/10000 = 99.7e6
        assertApproxEqAbs(amountOut, 99_700_000, 100);
    }

    function test_quote_USDC_to_DAI_decimals_6_to_18() public {
        // Both at $1.00. 100 USDC → ~99.7 DAI (after 30 bps swap fee).
        uint256 amountIn = 100e6;
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
        // With virtual shares: lpOut = usdIn * VIRTUAL_SHARES / VIRTUAL_ASSETS = 1000e18 * 1e6 = 1000e24.
        uint256 lpOut = pool.quoteDeposit(address(usdc), 1000e6);
        assertEq(lpOut, 1000e24);
    }

    function test_quoteDeposit_proportional_after_seed() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.deposit(address(usdc), 1000e6, 0, block.timestamp);
        vm.stopPrank();

        uint256 lpOut = pool.quoteDeposit(address(usdc), 500e6);
        // With virtual shares: lpOut = usdIn * (supply + VIRTUAL_SHARES) / (nav + VIRTUAL_ASSETS).
        // VIRTUAL_SHARES = 1e6, VIRTUAL_ASSETS = 1.
        uint256 expected = (500e18 * (lp.totalSupply() + 1e6)) / (pool.totalReservesUSD() + 1);
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
        assertGt(fee, 0); // protocol's 10% of 30 bps fee on ~1000 USDC
    }

    // ── swap ────────────────────────────────────────────────────────
    function _seedAllThree() internal {
        // Owner-style seeding via a generous Alice deposit across all tokens
        vm.startPrank(alice);
        usdc.approve(address(pool), 5_000e6);
        eurc.approve(address(pool), 5_000e6);
        dai.approve(address(pool), 5_000e18);
        pool.deposit(address(usdc), 5_000e6, 0, block.timestamp);
        pool.deposit(address(eurc), 5_000e6, 0, block.timestamp);
        pool.deposit(address(dai), 5_000e18, 0, block.timestamp);
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

    // ── I-3: protocol-fee sweep gated by whenNotPaused ───────────────
    function test_i3_withdrawProtocolFees_revertsWhenPaused() public {
        _seedAllThree();

        // Accrue real protocol fees in EURC via a swap (PROT_SHARE_DEFAULT = 10%).
        uint256 amountIn = 100e6;
        vm.prank(owner);
        usdc.mint(bob, amountIn);
        vm.startPrank(bob);
        usdc.approve(address(pool), amountIn);
        pool.swap(address(usdc), address(eurc), amountIn, 0, block.timestamp, bob);
        vm.stopPrank();

        uint256 accrued = pool.protocolFeesAccrued(address(eurc));
        assertGt(accrued, 0, "expected accrued protocol fees to sweep");

        // Pause the pool: users can no longer exit, so admin must not be able to
        // sweep protocol fees either (symmetry — finding I-3).
        vm.prank(owner);
        pool.pause();
        assertTrue(pool.paused());

        // Sweep must revert at the whenNotPaused gate, even though fees are accrued
        // and the call is well-formed.
        vm.prank(owner);
        vm.expectRevert(IArcoraDexPool.PoolPaused.selector);
        pool.withdrawProtocolFees(address(eurc), accrued, owner);

        // After unpause, the same sweep succeeds.
        vm.prank(owner);
        pool.unpause();
        assertFalse(pool.paused());

        uint256 ownerBalBefore = eurc.balanceOf(owner);
        vm.prank(owner);
        pool.withdrawProtocolFees(address(eurc), accrued, owner);

        assertEq(eurc.balanceOf(owner), ownerBalBefore + accrued);
        assertEq(pool.protocolFeesAccrued(address(eurc)), 0);
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

    // ── PriceGuard ──────────────────────────────────────────────────
    function test_priceGuard_excessiveDeviationRejectedByCache() public {
        // EURC deviation cap = 150 bps. Push price by 200 bps after first accepted.
        // With the cache-deviation guard, excessive oracle moves are now rejected at the
        // cache level: the swap proceeds using the old cached price and the cache is NOT
        // updated — rather than reverting, the pool stays available.
        _seedAllThree(); // first reads accept current oracle prices; cache = $1.10.

        uint256 cachedEurcBefore = pool.lastValidPrice(address(eurc));
        uint256 cachedEurcAtBefore = pool.lastValidPriceAt(address(eurc));

        // Move EURC oracle by +2% (200 bps over 110_000_000 → 112_200_000) — exceeds 150 bps cap.
        // Initial fEurc was 11e7 = 110_000_000 (8 dec, $1.10).
        fEurc.setAnswer(int256(112_200_000));

        vm.prank(owner);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 100e6);
        // Swap proceeds using cached (guard-rejected oracle) price — no revert.
        uint256 amountOut = pool.swap(address(usdc), address(eurc), 100e6, 0, block.timestamp, bob);
        vm.stopPrank();

        assertGt(amountOut, 0, "swap should proceed using cached price");
        // Cache must remain unchanged — the excessive oracle value was rejected.
        assertEq(
            pool.lastValidPrice(address(eurc)), cachedEurcBefore, "cache value must not update on excessive deviation"
        );
        assertEq(
            pool.lastValidPriceAt(address(eurc)),
            cachedEurcAtBefore,
            "cache timestamp must not update on excessive deviation"
        );
    }

    function test_priceGuard_acceptsWithinCap() public {
        _seedAllThree();
        // Move EURC by +1% (100 bps), within 150 bps cap.
        fEurc.setAnswer(int256(111_100_000)); // 1.111 USD

        vm.prank(owner);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 100e6);
        pool.swap(address(usdc), address(eurc), 100e6, 0, block.timestamp, bob);
        vm.stopPrank();
    }

    function test_priceGuard_staleOracle_usesCache() public {
        _seedAllThree();
        // Advance time past USDC maxStaleSeconds (3600s) without updating feed timestamp.
        // New behavior: stale feed falls back to cached price (no revert) because cache is seeded.
        vm.warp(block.timestamp + 1 hours + 1);

        // Capture cache state BEFORE the swap — the stale fallback should not update it.
        uint256 cachedUsdcBefore = pool.lastValidPrice(address(usdc));
        uint256 cachedUsdcAtBefore = pool.lastValidPriceAt(address(usdc));

        vm.prank(owner);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 100e6);
        // Should succeed using cached USDC price (not revert).
        uint256 amountOut = pool.swap(address(usdc), address(eurc), 100e6, 0, block.timestamp, bob);
        vm.stopPrank();

        assertEq(pool.lastValidPrice(address(usdc)), cachedUsdcBefore, "stale fallback should not update cache value");
        assertEq(
            pool.lastValidPriceAt(address(usdc)), cachedUsdcAtBefore, "stale fallback should not update cache timestamp"
        );
        assertGt(amountOut, 0);
    }

    function test_syncAcceptedPrice_resetsBaseline() public {
        _seedAllThree();
        // Move EURC by +5% (500 bps) — exceeds 150 bps cap; would revert without sync.
        fEurc.setAnswer(int256(115_500_000)); // 1.155 USD

        // Owner syncs the new price as accepted baseline.
        vm.prank(owner);
        uint256 newBaseline = pool.syncAcceptedPrice(address(eurc));
        assertEq(newBaseline, 1.155e18);
        assertEq(pool.lastAcceptedPrice(address(eurc)), 1.155e18);

        // Subsequent swap proceeds (deviation now measured from 1.155).
        vm.prank(owner);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 100e6);
        pool.swap(address(usdc), address(eurc), 100e6, 0, block.timestamp, bob);
        vm.stopPrank();
    }

    function test_syncAcceptedPrice_revertsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(); // OZ Ownable
        pool.syncAcceptedPrice(address(usdc));
    }

    // ── setSwapFeeBps ──────────────────────────────────────────────
    function test_setSwapFeeBps_revertsAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.InvalidFeeBps.selector, uint16(101)));
        pool.setSwapFeeBps(101);
    }

    function test_setSwapFeeBps_succeedsAtCap() public {
        vm.prank(owner);
        pool.setSwapFeeBps(100);
        assertEq(pool.swapFeeBps(), 100);
    }

    // ── pauseGuardian role (Phase 2) ──
    function test_setPauseGuardian_byOwner_emitsAndStores() public {
        address guardian = address(0xC0DE);
        vm.expectEmit(true, true, false, true);
        emit IArcoraDexPool.PauseGuardianUpdated(address(0), guardian);
        vm.prank(owner);
        pool.setPauseGuardian(guardian);
        assertEq(pool.pauseGuardian(), guardian);
    }

    function test_setPauseGuardian_byNonOwner_reverts() public {
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert();
        pool.setPauseGuardian(address(0xC0DE));
    }

    function test_pauseUnpause_guardianCanPause_cannotUnpause() public {
        address guardian = address(0xC0DE);
        address attacker = address(0xBAD);
        vm.prank(owner);
        pool.setPauseGuardian(guardian);

        // Guardian can pause
        vm.prank(guardian);
        pool.pause();
        assertEq(pool.paused(), true);

        // Guardian cannot unpause — only the owner (Timelock) may restart (A1 asymmetry)
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        pool.unpause();
        assertEq(pool.paused(), true); // still paused

        // Owner can unpause
        vm.prank(owner);
        pool.unpause();
        assertEq(pool.paused(), false);

        // Random third party cannot pause
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.NotAuthorized.selector));
        pool.pause();
    }

    // ── P3 Task 2: reverting oracle falls back to cache (A1) ──
    function test_pool_handles_reverting_oracle() public {
        // Setup: seed USDC cache via a successful deposit using the existing feed.
        // MintableERC20.mint is onlyOwner, so prank as owner.
        vm.prank(owner);
        usdc.mint(address(this), 100_000_000);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60);
        uint256 cachedPrice = pool.lastValidPrice(address(usdc));
        assertGt(cachedPrice, 0, "cache should be seeded by deposit");

        // Capture NAV before swapping in the reverting feed. With only USDC deposited
        // and all three feeds still live, this is the baseline we compare against.
        uint256 navBeforeSwap = pool.totalReservesUSD();

        // Swap the USDC oracle for a reverting feed via the registry (owner-gated).
        RevertingMockFeed bad = new RevertingMockFeed(8);
        vm.prank(owner);
        reg.setOracle(address(usdc), IChainlinkAggregator(address(bad)));

        // totalReservesUSD() should now use the cached USDC price, not revert.
        // The NAV must be identical to the pre-swap value: same reserves, same cached
        // price, no other oracle changed — proving the cache drove the result.
        uint256 navAfterSwap = pool.totalReservesUSD();
        assertEq(navAfterSwap, navBeforeSwap, "NAV must equal pre-swap value -- cache must have driven the result");

        // A subsequent deposit must also succeed by reading the cache.
        vm.prank(owner);
        usdc.mint(address(this), 50_000_000);
        pool.deposit(address(usdc), 50_000_000, 0, block.timestamp + 60);
    }

    // ── L-9: removeToken shrinks the NAV loop ────────────────────────
    /// @notice After governance deactivates a zero-reserve token and removes it
    /// from the registry, the Pool's NAV loop must no longer iterate over it and
    /// NAV / quotes must be unchanged. The loop is order-independent (a sum), so
    /// the registry's swap-pop reorder is safe.
    function test_l9_removeToken_navLoopShrinks() public {
        // Deposit A (USDC) and B (DAI). EURC is listed but never deposited.
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        dai.approve(address(pool), 1000e18);
        pool.deposit(address(usdc), 1000e6, 0, block.timestamp);
        pool.deposit(address(dai), 1000e18, 0, block.timestamp);
        vm.stopPrank();

        // Remove EURC (B): it has zero reserves, so removal does not change NAV.
        // (I-1, when landed, makes deactivation require reserves==0; here EURC was
        // never deposited, so its reserves are already 0.)
        assertEq(pool.reserves(address(eurc)), 0, "EURC must have zero reserves before removal");

        uint256 navBefore = pool.totalReservesUSD();
        uint256 quoteBefore = pool.quote(address(usdc), address(dai), 100e6);
        uint256 lenBefore = reg.tokensLength();

        vm.startPrank(owner);
        reg.deactivateToken(address(eurc));
        reg.removeToken(address(eurc));
        vm.stopPrank();

        // List shrank and EURC is gone from the registry's token set.
        assertEq(reg.tokensLength(), lenBefore - 1, "tokensLength must decrease by one");
        for (uint256 i = 0; i < reg.tokensLength(); i++) {
            assertTrue(reg.tokens(i) != address(eurc), "EURC must not appear in the token list");
        }

        // NAV and quotes are unchanged: EURC contributed nothing and the surviving
        // tokens' contributions are identical regardless of iteration order.
        assertEq(pool.totalReservesUSD(), navBefore, "NAV must be unchanged after removing a zero-reserve token");
        assertEq(pool.quote(address(usdc), address(dai), 100e6), quoteBefore, "quote must be unchanged");

        // Prove the loop no longer visits EURC at all: once removed, EURC is fully
        // unlisted (its _info is cleared), so the registry rejects any further ops
        // on it. This confirms the NAV loop iterates a strictly smaller token set.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.TokenNotListed.selector, address(eurc)));
        reg.setOracle(address(eurc), IChainlinkAggregator(address(fEurc)));
    }

    /// @notice Covers the inner try/catch around `oracle.decimals()` in `_readOracle`.
    /// A feed with a working `latestRoundData()` (passes all freshness checks so
    /// `isFresh` becomes true) but a reverting `decimals()` must cause the Pool to
    /// invalidate the read and fall back to its cached price — not revert.
    function test_pool_handles_reverting_decimals() public {
        // Step 1: seed USDC cache via a normal deposit with the existing live feed.
        vm.prank(owner);
        usdc.mint(address(this), 100_000_000);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60);
        uint256 cachedPrice = pool.lastValidPrice(address(usdc));
        assertGt(cachedPrice, 0, "cache should be seeded before swapping oracle");

        // Capture NAV with the live feed (baseline — only USDC has reserves here).
        uint256 navBaseline = pool.totalReservesUSD();

        // Step 2: model an ALREADY-INSTALLED feed whose latestRoundData() keeps
        // succeeding (fresh round) but whose decimals() starts reverting at
        // runtime — exercising the Pool's inner `decimals()` try/catch in
        // `_readOracle`. We mock the live feed (fUsdc) rather than installing a
        // RevertingDecimalsMockFeed via setOracle, because I-7 now makes setOracle
        // probe `decimals()` up front and reject a feed that reverts there; the
        // inner-catch path defends against a feed that degrades AFTER install,
        // which is what this regression covers. `RevertingDecimalsMockFeed`
        // remains a documented analogue of this failure mode.
        vm.mockCallRevert(
            address(fUsdc), abi.encodeWithSelector(IChainlinkAggregator.decimals.selector), "decimals unavailable"
        );

        // totalReservesUSD() must not revert; cache fallback keeps NAV non-zero
        // and equal to the baseline (same reserves, same cached price).
        uint256 navAfter = pool.totalReservesUSD();
        assertEq(navAfter, navBaseline, "cache fallback must preserve NAV when decimals() reverts");

        // Step 3: a follow-up deposit must also succeed via cache.
        vm.prank(owner);
        usdc.mint(address(this), 50_000_000);
        pool.deposit(address(usdc), 50_000_000, 0, block.timestamp + 60);
    }

    // ── I-1: Registry.deactivateToken reserve-guard ────────────────────
    /// @dev With the Pool wired into the Registry, deactivating a token while the
    /// Pool still holds reserves for it must revert `TokenHasReserves`; once the
    /// reserves are drained to zero, deactivation succeeds. Guards against the
    /// value-transfer-between-LP-cohorts bug (inactive tokens drop out of NAV).
    function test_i1_deactivate_revertsWithReserves() public {
        // Wire the pool so the registry can read its reserves (production wiring).
        vm.prank(owner);
        reg.setPool(address(pool));

        // Zero fees so the drain swap below empties USDC reserves to exactly zero.
        vm.startPrank(owner);
        pool.setSwapFeeBps(0);
        pool.setProtocolFeeShareBps(0);
        vm.stopPrank();

        // Seed USDC (the token under test) and DAI (the drain counter-asset).
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        dai.approve(address(pool), 5_000e18);
        pool.deposit(address(usdc), 1_000e6, 0, block.timestamp);
        pool.deposit(address(dai), 5_000e18, 0, block.timestamp);
        vm.stopPrank();

        uint256 r = pool.reserves(address(usdc));
        assertGt(r, 0, "USDC reserves must be non-zero after deposit");

        // Deactivation must be blocked while reserves are live.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.TokenHasReserves.selector, address(usdc)));
        reg.deactivateToken(address(usdc));

        // Drain all USDC by swapping DAI -> USDC. Both priced at $1.00, fees are 0,
        // so daiIn = r * 1e12 (18-dec DAI for 6-dec USDC) pulls out exactly r USDC.
        uint256 daiIn = r * 1e12;
        vm.prank(owner);
        dai.mint(bob, daiIn);
        vm.startPrank(bob);
        dai.approve(address(pool), daiIn);
        pool.swap(address(dai), address(usdc), daiIn, 0, block.timestamp, bob);
        vm.stopPrank();

        assertEq(pool.reserves(address(usdc)), 0, "USDC reserves must be drained to zero");

        // Now deactivation is permitted.
        vm.prank(owner);
        reg.deactivateToken(address(usdc));
        assertFalse(reg.isActive(address(usdc)), "USDC must be inactive after draining + deactivating");
    }

    // ── I-2: Pool.resetPriceCache forces a fresh price on reactivation ──
    /// @dev A token that was deactivated (drained) keeps its stale price caches.
    /// On reactivation, without `resetPriceCache` a swap trades against the ancient
    /// cached price (the cache-deviation guard demotes the fresh oracle to the
    /// stale cache). After the owner calls `resetPriceCache`, the next priced op
    /// takes the fresh-oracle path instead of the stale cache.
    function test_i2_reactivate_thenResetCache_forcesFreshPrice() public {
        vm.prank(owner);
        reg.setPool(address(pool));

        // Zero fees so the drain swap empties EURC reserves to exactly zero.
        vm.startPrank(owner);
        pool.setSwapFeeBps(0);
        pool.setProtocolFeeShareBps(0);
        vm.stopPrank();

        // Seed EURC ($1.10) and USDC ($1.00). This establishes EURC's caches.
        vm.startPrank(alice);
        eurc.approve(address(pool), 5_000e6);
        usdc.approve(address(pool), 5_000e6);
        pool.deposit(address(eurc), 5_000e6, 0, block.timestamp);
        pool.deposit(address(usdc), 5_000e6, 0, block.timestamp);
        vm.stopPrank();

        assertEq(pool.lastValidPrice(address(eurc)), 1.1e18, "EURC cache must be seeded at $1.10");
        assertEq(pool.lastAcceptedPrice(address(eurc)), 1.1e18, "EURC accepted baseline must be $1.10");

        // Drain EURC fully by swapping it out (USDC -> EURC pulls all EURC).
        uint256 rEurc = pool.reserves(address(eurc));
        // USDC in worth rEurc EURC at $1.00/$1.10: usdcIn = rEurc * 1.10 (same 6 dec).
        uint256 usdcIn = (rEurc * 11) / 10;
        vm.prank(owner);
        usdc.mint(bob, usdcIn);
        vm.startPrank(bob);
        usdc.approve(address(pool), usdcIn);
        pool.swap(address(usdc), address(eurc), usdcIn, 0, block.timestamp, bob);
        vm.stopPrank();
        assertEq(pool.reserves(address(eurc)), 0, "EURC reserves must be drained to zero");

        // Deactivate EURC (now permitted: zero reserves).
        vm.prank(owner);
        reg.deactivateToken(address(eurc));

        // Oracle moves dramatically while EURC is inactive: $1.10 -> $5.00.
        // (350%+ jump, far beyond the 150 bps deviation cap.)
        fEurc.setAnswer(int256(5e8));

        // Reactivate WITHOUT resetting the cache: the stale $1.10 cache survives.
        vm.prank(owner);
        reg.reactivateToken(address(eurc));
        assertEq(pool.lastValidPrice(address(eurc)), 1.1e18, "stale cache must survive reactivation");
        assertEq(pool.lastAcceptedPrice(address(eurc)), 1.1e18, "stale accepted baseline must survive reactivation");

        // A swap now trades EURC against the STALE cache ($1.10): the fresh $5.00
        // oracle is demoted by the cache-deviation guard, so the cache is unchanged.
        vm.prank(owner);
        eurc.mint(bob, 100e6);
        vm.startPrank(bob);
        eurc.approve(address(pool), 100e6);
        pool.swap(address(eurc), address(usdc), 100e6, 0, block.timestamp, bob);
        vm.stopPrank();
        assertEq(pool.lastValidPrice(address(eurc)), 1.1e18, "without reset, swap uses the stale $1.10 cache");

        // Owner resets the EURC caches (paired with reactivation in governance).
        vm.prank(owner);
        pool.resetPriceCache(address(eurc));
        assertEq(pool.lastValidPrice(address(eurc)), 0, "lastValidPrice must be cleared");
        assertEq(pool.lastValidPriceAt(address(eurc)), 0, "lastValidPriceAt must be cleared");
        assertEq(pool.lastAcceptedPrice(address(eurc)), 0, "lastAcceptedPrice must be cleared");

        // The next priced op takes the FRESH-oracle path ($5.00), NOT the stale cache.
        vm.prank(owner);
        eurc.mint(bob, 100e6);
        vm.startPrank(bob);
        eurc.approve(address(pool), 100e6);
        pool.swap(address(eurc), address(usdc), 100e6, 0, block.timestamp, bob);
        vm.stopPrank();
        assertEq(pool.lastValidPrice(address(eurc)), 5e18, "after reset, swap must use the fresh $5.00 oracle");
        assertEq(pool.lastAcceptedPrice(address(eurc)), 5e18, "after reset, accepted baseline must be the fresh $5.00");
    }

    // ── PR-4 golden test: price-stack NAV/quote bit-identical net (G-1..G-4) ──
    // Seeds a deterministic multi-token pool (USDC@$1.00, EURC@$1.10, DAI@$1.00)
    // and pins the EXACT outputs of totalReservesUSD / quoteDeposit / quoteWithdraw
    // / quote(swap). These constants were captured on pre-refactor code and MUST
    // remain bit-identical after the G-1/G-2/G-3/G-4 read-collapse refactor.
    function test_g_nav_and_quotes_unchanged() public {
        // Deterministic multi-token seed (all from alice, who is funded in setUp).
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.deposit(address(usdc), 1000e6, 0, block.timestamp); // 1000 USDC @ $1.00
        eurc.approve(address(pool), 600e6);
        pool.deposit(address(eurc), 600e6, 0, block.timestamp); // 600 EURC @ $1.10
        dai.approve(address(pool), 2000e18);
        pool.deposit(address(dai), 2000e18, 0, block.timestamp); // 2000 DAI @ $1.00
        vm.stopPrank();

        uint256 nav = pool.totalReservesUSD();
        uint256 qDepUsdc = pool.quoteDeposit(address(usdc), 250e6);
        uint256 qDepDai = pool.quoteDeposit(address(dai), 750e18);
        (uint256 qWdAmt, uint256 qWdFee) = pool.quoteWithdraw(address(eurc), 100e24);
        uint256 qSwap = pool.quote(address(usdc), address(eurc), 500e6);

        // ── Golden constants (captured on pre-refactor code) ──
        assertEq(nav, 3660e18, "NAV");
        assertEq(qDepUsdc, 250000000000000000000000249, "quoteDeposit USDC");
        assertEq(qDepDai, 750000000000000000000000749, "quoteDeposit DAI");
        assertEq(qWdAmt, 90636363, "quoteWithdraw amountOut");
        assertEq(qWdFee, 27272, "quoteWithdraw protocolFee");
        assertEq(qSwap, 453181818, "quote swap USDC->EURC");
    }
}
