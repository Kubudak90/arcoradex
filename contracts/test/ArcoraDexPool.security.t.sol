// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexPool} from "../src/ArcoraDexPool.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {ArcoraDexLP} from "../src/ArcoraDexLP.sol";
import {IArcoraDexPool} from "../src/interfaces/IArcoraDexPool.sol";
import {MockChainlinkFeedV2} from "../src/testnet/MockChainlinkFeedV2.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

contract ArcoraDexPoolSecurityTest is Test {
    ArcoraDexRegistry reg;
    ArcoraDexPool pool;
    MockERC20 usdc;
    MockERC20 eurc;
    MockChainlinkFeedV2 fUsdc;
    MockChainlinkFeedV2 fEurc;
    address constant DEPLOYER = address(0xD3);
    address constant ALICE = address(0xA1);

    function setUp() public {
        vm.startPrank(DEPLOYER);
        reg = new ArcoraDexRegistry(DEPLOYER);
        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 6);
        fUsdc = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER); // $1.00
        fEurc = new MockChainlinkFeedV2(8, 110_000_000, DEPLOYER, DEPLOYER); // $1.10
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(fUsdc)), 50, 3600);
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

    /// @notice Verifies that ArcoraDexPool's explicit `reserves[]` accounting
    /// blocks the classic Uniswap-V2-style donation-inflation attack.
    /// A direct ERC20 transfer to the pool does NOT increment `reserves[]`,
    /// so subsequent depositors are not diluted regardless of donation size.
    /// This protection is structural (independent of virtual shares).
    function test_donation_does_not_inflate_nav() public {
        address attacker = address(0xBADC0FFEE);
        address victim = address(0xBE);

        usdc.mint(attacker, 100_000_000_000); // 100,000 USDC
        usdc.mint(victim, 1_000_000_000); //   1,000 USDC

        vm.startPrank(attacker);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 1001, 0, block.timestamp + 60);
        uint256 navAfterTinyDeposit = pool.totalReservesUSD();

        // Donation via direct transfer — should NOT inflate NAV
        usdc.transfer(address(pool), 10_000_000_000); // 10,000 USDC
        uint256 navAfterDonation = pool.totalReservesUSD();
        vm.stopPrank();

        assertEq(navAfterDonation, navAfterTinyDeposit, "explicit reserves[] must ignore direct-transfer donations");

        // Victim deposits, receives LP based on legitimate NAV (not the inflated balance)
        vm.startPrank(victim);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60); // 100 USDC
        uint256 victimLp = pool.LP().balanceOf(victim);
        vm.stopPrank();

        assertGt(victimLp, 0, "victim must receive non-zero LP from a legitimate deposit");

        // Victim withdraws all LP, recovers near-full deposit value
        vm.warp(block.timestamp + 2 hours); // bypass MIN_HOLD_SECONDS (Task 4 adds it)
        vm.prank(victim);
        pool.withdraw(address(usdc), victimLp, 0, block.timestamp + 60);

        uint256 victimUsdcOut = usdc.balanceOf(victim);
        assertGe(
            victimUsdcOut, (100_000_000 * 99) / 100, "victim must recover >=99% of deposit (only swap fee deducted)"
        );

        // The donated 10,000 USDC is "orphaned" in the pool's token balance —
        // no LP has a claim against it because reserves[] never recorded it.
        uint256 poolBalance = usdc.balanceOf(address(pool));
        uint256 poolReserves = pool.reserves(address(usdc));
        assertGt(poolBalance, poolReserves, "orphaned donation should sit outside reserves[]");
    }

    function test_jit_mev_blocked_by_min_hold() public {
        address bot = address(0xB07);
        usdc.mint(bot, 1_000_000_000); // 1000 USDC

        vm.startPrank(bot);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60); // 100 USDC
        uint256 botLp = pool.LP().balanceOf(bot);
        uint256 expectedUnlock = block.timestamp + 1 hours;

        // Simulate keeper oracle update (price up)
        vm.stopPrank();
        vm.prank(DEPLOYER);
        fUsdc.setAnswer(100_500_000); // 0.5% up
        vm.startPrank(bot);

        // Immediate withdraw must revert (1h min-hold)
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.EarlyWithdraw.selector, expectedUnlock, block.timestamp));
        pool.withdraw(address(usdc), botLp, 0, block.timestamp + 60);

        // After 59m 59s — still blocked
        vm.warp(block.timestamp + 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.EarlyWithdraw.selector, expectedUnlock, block.timestamp));
        pool.withdraw(address(usdc), botLp, 0, block.timestamp + 60);

        // After exactly 1h from mint — allowed
        vm.warp(block.timestamp + 1);
        pool.withdraw(address(usdc), botLp, 0, block.timestamp + 60);
        vm.stopPrank();

        assertGt(usdc.balanceOf(bot), 0, "withdraw should succeed after 1h");
    }

    /// @notice Verifies the LP-transfer hook closes the deposit→transfer→withdraw
    /// JIT bypass. Without the hook, a fresh wallet receiving LP could withdraw
    /// immediately because its lastMintAt = 0.
    function test_jit_mev_blocked_by_lp_transfer_hook() public {
        address botA = address(0xB0A);
        address botB = address(0xB0B); // fresh, never deposited

        usdc.mint(botA, 1_000_000_000); // 1000 USDC

        // Bot deposits to wallet A
        vm.startPrank(botA);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60);
        uint256 botLp = pool.LP().balanceOf(botA);
        uint256 expectedUnlock = block.timestamp + 1 hours;

        // Bot transfers all LP to fresh wallet B (same block as deposit)
        pool.LP().transfer(botB, botLp);
        vm.stopPrank();

        // The hook should have propagated lastMintAt[A] to lastMintAt[B]
        assertEq(pool.lastMintAt(botB), pool.lastMintAt(botA), "transfer must propagate lastMintAt");

        // B tries to withdraw — must revert because of inherited lock
        vm.prank(botB);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.EarlyWithdraw.selector, expectedUnlock, block.timestamp));
        pool.withdraw(address(usdc), botLp, 0, block.timestamp + 60);

        // Warp past the lock
        vm.warp(block.timestamp + 1 hours);

        // Now B can withdraw
        vm.prank(botB);
        pool.withdraw(address(usdc), botLp, 0, block.timestamp + 60);
        assertGt(usdc.balanceOf(botB), 0, "post-lock withdraw should succeed");
    }

    /// @notice Verifies that a second deposit during the hold window extends
    /// the unlock time (resets the clock to block.timestamp + MIN_HOLD_SECONDS).
    function test_second_deposit_extends_minhold() public {
        address alice = address(0xA11);
        usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        uint256 firstDepositAt = block.timestamp;
        pool.deposit(address(usdc), 50_000_000, 0, block.timestamp + 60);
        assertEq(pool.lastMintAt(alice), firstDepositAt);

        // Advance 30 minutes (inside the 1-hour window)
        vm.warp(block.timestamp + 30 minutes);

        // Second deposit resets the clock
        uint256 secondDepositAt = block.timestamp;
        pool.deposit(address(usdc), 50_000_000, 0, block.timestamp + 60);
        assertEq(pool.lastMintAt(alice), secondDepositAt, "second deposit must overwrite lastMintAt");

        // Withdraw 45 minutes after FIRST deposit (15 min after second) — still locked
        vm.warp(firstDepositAt + 45 minutes);
        uint256 aliceLp = pool.LP().balanceOf(alice);
        uint256 expectedUnlock = secondDepositAt + 1 hours;
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.EarlyWithdraw.selector, expectedUnlock, block.timestamp));
        pool.withdraw(address(usdc), aliceLp, 0, block.timestamp + 60);

        // Warp 1h after SECOND deposit — now allowed
        vm.warp(secondDepositAt + 1 hours);
        pool.withdraw(address(usdc), pool.LP().balanceOf(alice), 0, block.timestamp + 60);
        vm.stopPrank();
    }

    /// @notice Scenario B (intentional STRICTER-than-swap): live oracle has
    /// moved past the cache-deviation cap; Task 2's cache guard shields swap()
    /// so it silently executes at the cached price. quote() OVER-REVERTS to
    /// give integrators an early-warning signal that the executed price would
    /// be stale.
    function test_quote_over_reverts_when_cache_guard_would_shield_swap() public {
        usdc.mint(ALICE, 1_000_000_000);
        eurc.mint(ALICE, 1_000_000_000);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60);
        pool.deposit(address(eurc), 100_000_000, 0, block.timestamp + 60);
        vm.stopPrank();

        // After seeding: lastAcceptedPrice[eurc] = $1.10, cache = $1.10.
        // Move oracle to $1.132 — 290 bps above the cache; EURC's cap is 150 bps.
        // Cache-deviation guard will reject this update; cache stays at $1.10.
        // swap() will silently execute at $1.10. quote() over-reverts.
        vm.prank(DEPLOYER);
        fEurc.setAnswer(113_200_000);

        // Sanity: cache untouched by a read (until a state-changing op).
        // quote() reverts PriceDeviation on the EURC leg (raw oracle $1.132
        // vs lastAcceptedPrice $1.10 is 290 bps > 150 bps cap).
        vm.expectRevert(
            abi.encodeWithSelector(
                IArcoraDexPool.PriceDeviation.selector, address(eurc), uint256(1.132e18), uint256(1.1e18), uint16(150)
            )
        );
        pool.quote(address(usdc), address(eurc), 10_000_000);

        // swap() in the same state SILENTLY succeeds at the cached price.
        // This documents the intentional behavioral asymmetry.
        usdc.mint(address(this), 10_000_000);
        usdc.approve(address(pool), 10_000_000);
        uint256 amountOut = pool.swap(address(usdc), address(eurc), 10_000_000, 0, block.timestamp + 60, address(this));
        assertGt(amountOut, 0, "swap should silently execute at cached price");

        // After syncAcceptedPrice, quote unblocks (lastAcceptedPrice catches up).
        vm.prank(DEPLOYER);
        pool.syncAcceptedPrice(address(eurc));
        uint256 q = pool.quote(address(usdc), address(eurc), 10_000_000);
        assertGt(q, 0, "quote should return a value after sync");
    }

    /// @notice Scenario C (MATCH): cache has tracked the oracle in small steps,
    /// pushing past the lastAcceptedPrice cap; both quote() and swap() revert.
    /// This is the genuine parity case stated by the spec.
    function test_quote_and_swap_both_revert_when_cache_drifted_past_cap() public {
        usdc.mint(ALICE, 1_000_000_000);
        eurc.mint(ALICE, 10_000_000_000);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60);
        pool.deposit(address(eurc), 100_000_000, 0, block.timestamp + 60);
        vm.stopPrank();

        // After seeding: lastAcceptedPrice[eurc] = $1.10, cache = $1.10.
        //
        // Walk the cache up in TWO steps, each within the 150 bps cache-deviation
        // cap, but each step also advancing lastAcceptedPrice via a swap. Then
        // freeze lastAcceptedPrice (by stopping swaps on EURC) while letting the
        // cache walk further. Concretely:
        //
        // Step a: oracle $1.10 -> $1.112 (109 bps from cache, accepted). Swap to
        //         advance both cache and lastAcceptedPrice.
        // Step b: oracle $1.112 -> $1.124 (108 bps from cache, accepted). Same.
        //         Now cache = lastAcceptedPrice = $1.124.
        // Step c: oracle $1.124 -> $1.136 (107 bps from cache, accepted by cache
        //         guard). But this time DON'T do a swap, so lastAcceptedPrice
        //         stays at $1.124 while cache moves to $1.136.
        //
        // The trick: in Task 2's design, `lastValidPrice` only updates inside
        // `_readUsdPrice1e18Mut` (called by deposit/withdraw/swap), so to "walk
        // the cache without updating lastAcceptedPrice" we trigger any mutating
        // call that calls `_totalReservesUSDMut` but NOT `_readAndGuardPrice` on
        // EURC specifically. A USDC swap touches USDC's lastAcceptedPrice but
        // calls _totalReservesUSDMut for NAV, which updates all caches.
        //
        // After step c, cache = $1.136 vs lastAcceptedPrice $1.124 = 109 bps
        // (within 150 bps cap, so guard doesn't fire yet).
        //
        // Step d: oracle $1.136 -> $1.148 (106 bps from cache). Another NAV
        //         iteration via deposit/withdraw will move cache to $1.148.
        //         Cache vs lastAcceptedPrice: $1.148 vs $1.124 = 213 bps > 150
        //         bps. Now both quote and swap revert.

        // Step a: oracle bump + USDC->EURC swap to advance EURC's lastAcceptedPrice
        vm.prank(DEPLOYER);
        fEurc.setAnswer(111_200_000); // $1.112

        vm.startPrank(ALICE);
        pool.swap(address(usdc), address(eurc), 1_000_000, 0, block.timestamp + 60, ALICE);
        vm.stopPrank();
        // Now lastAcceptedPrice[eurc] = cache[eurc] = $1.112

        // Step b: oracle bump + another swap
        vm.prank(DEPLOYER);
        fEurc.setAnswer(112_400_000); // $1.124
        vm.startPrank(ALICE);
        pool.swap(address(usdc), address(eurc), 1_000_000, 0, block.timestamp + 60, ALICE);
        vm.stopPrank();
        // Now lastAcceptedPrice[eurc] = cache[eurc] = $1.124

        // Step c: oracle bump, then deposit USDC (touches NAV iteration -> updates
        // cache[eurc] WITHOUT calling _readAndGuardPrice on EURC, so EURC's
        // lastAcceptedPrice is NOT updated).
        vm.prank(DEPLOYER);
        fEurc.setAnswer(113_600_000); // $1.136

        vm.startPrank(ALICE);
        pool.deposit(address(usdc), 1_000_000, 0, block.timestamp + 60);
        vm.stopPrank();
        // Now cache[eurc] = $1.136, lastAcceptedPrice[eurc] = $1.124 (gap = 108 bps)

        // Step d: another oracle bump + NAV iteration via deposit
        vm.prank(DEPLOYER);
        fEurc.setAnswer(114_800_000); // $1.148

        vm.startPrank(ALICE);
        pool.deposit(address(usdc), 1_000_000, 0, block.timestamp + 60);
        vm.stopPrank();
        // Now cache[eurc] = $1.148, lastAcceptedPrice[eurc] = $1.124 (gap = 213 bps > 150)

        // Now: cache has drifted past the ratchet cap relative to lastAccepted.
        // Both quote() and swap() should revert with PriceDeviation.

        // quote: WithGuard's fresh-branch (raw $1.148 vs lastAccepted $1.124 = 213 bps) reverts.
        vm.expectRevert();
        pool.quote(address(usdc), address(eurc), 10_000_000);

        // swap: _readAndGuardPrice uses cache ($1.148) and checks vs lastAccepted ($1.124),
        // diff 213 bps > 150 bps cap, reverts PriceDeviation.
        usdc.mint(address(this), 10_000_000);
        usdc.approve(address(pool), 10_000_000);
        vm.expectRevert();
        pool.swap(address(usdc), address(eurc), 10_000_000, 0, block.timestamp + 60, address(this));
    }

    /// @notice Verifies that virtual shares defeat the round-down-dust dilution
    /// vector even at the worst-case NAV/supply ratio.
    ///
    /// Without virtual shares, after a withdrawal that leaves a tiny LP supply
    /// against a much larger remaining NAV, a small follow-up deposit could
    /// round to zero LP (because `lpMinted = usdIn * supply / NAV` with
    /// supply << NAV produces 0 for small usdIn).
    ///
    /// With the offset (supply + 1e6) and (NAV + 1), the floor guarantees
    /// non-zero usdIn -> non-zero lpMinted regardless of the supply/NAV ratio.
    function test_virtual_shares_prevent_lp_round_to_zero() public {
        address first = address(0xF1);
        address second = address(0x52);

        usdc.mint(first, 1_000_000_000); //  1,000 USDC
        usdc.mint(second, 1_000_000_000); //  1,000 USDC

        // First depositor: 500 USDC → mints a lot of LP, NAV = 500 USD
        vm.startPrank(first);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 500_000_000, 0, block.timestamp + 60);
        uint256 firstLp = pool.LP().balanceOf(first);
        vm.stopPrank();

        // First depositor burns nearly all their LP back, leaving a tiny
        // (1-wei) LP supply outstanding (plus MINIMUM_LIQUIDITY in DEAD).
        // This creates the supply<<NAV edge case (in the limit) needed to
        // expose round-down dust.
        vm.warp(block.timestamp + 2 hours);
        vm.prank(first);
        pool.withdraw(address(usdc), firstLp - 1, 0, block.timestamp + 60);

        // After the burn: supply = 1 + MINIMUM_LIQUIDITY = 1001 LP units;
        // reserves[usdc] still holds the protocol-fee remainder + the 1-LP
        // claim. NAV is roughly proportional to the residual reserves.

        // Second depositor: 200 USDC-wei (~$0.0002 dust deposit).
        // The residual NAV after the large withdrawal is ~1.875e17 (≈ $0.000188 USD)
        // with LP supply = 1001 (1000 MINIMUM_LIQUIDITY + 1 remaining unit).
        //
        // Without virtual shares:
        //   lpMinted = usdIn * supply / navResidual
        //            = 2e14 * 1001 / 1.875e17
        //            = 1.068 → floor = 1 (still non-zero, but barely)
        //   For usdIn < 1.873e14 (i.e., amount < 188 USDC-wei) it rounds to 0.
        //
        // With virtual shares (VIRTUAL_SHARES = 1e6):
        //   lpMinted = usdIn * (supply + 1e6) / (navResidual + 1)
        //            = 2e14 * 1001001 / 1.875e17
        //            ≈ 1068 — the VIRTUAL_SHARES term provides the ~1000x boost.
        //
        // assertGt(secondLp, 1000) verifies this boost is load-bearing: the
        // offset pushes the result from "borderline 1" to ">1000", proving it is
        // the VIRTUAL_SHARES doing the work, not the bare supply term.
        vm.startPrank(second);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 200, 0, block.timestamp + 60);
        uint256 secondLp = pool.LP().balanceOf(second);
        vm.stopPrank();

        // Primary assertion: second depositor receives non-zero LP.
        // This is the contract the virtual-shares offset guarantees.
        assertGt(secondLp, 0, "second depositor with dust deposit must receive non-zero LP");

        // Stronger assertion: the lpMinted is dominated by the VIRTUAL_SHARES
        // term, demonstrating the offset is doing the work. Without the
        // offset, lpMinted = floor(usdIn * 1001 / navResidual) ≈ 1. With the
        // offset the (supply + 1e6) factor pushes lpMinted to ~1068, which is
        // >1000, proving the VIRTUAL_SHARES term (not 'supply') is the driver.
        assertGt(secondLp, 1000, "lpMinted should be dominated by VIRTUAL_SHARES, not 'supply' alone");
    }
}
