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

    /// @notice Verifies that ArcoraDexPool's explicit `reserves[]` accounting
    /// blocks the classic Uniswap-V2-style donation-inflation attack.
    /// A direct ERC20 transfer to the pool does NOT increment `reserves[]`,
    /// so subsequent depositors are not diluted regardless of donation size.
    /// This protection is structural (independent of virtual shares).
    function test_donation_does_not_inflate_nav() public {
        address attacker = address(0xBADC0FFEE);
        address victim   = address(0xBE);

        usdc.mint(attacker, 100_000_000_000); // 100,000 USDC
        usdc.mint(victim,     1_000_000_000); //   1,000 USDC

        vm.startPrank(attacker);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 1001, 0, block.timestamp + 60);
        uint256 navAfterTinyDeposit = pool.totalReservesUSD();

        // Donation via direct transfer — should NOT inflate NAV
        usdc.transfer(address(pool), 10_000_000_000); // 10,000 USDC
        uint256 navAfterDonation = pool.totalReservesUSD();
        vm.stopPrank();

        assertEq(navAfterDonation, navAfterTinyDeposit,
            "explicit reserves[] must ignore direct-transfer donations");

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
        assertGe(victimUsdcOut, (100_000_000 * 99) / 100,
            "victim must recover >=99% of deposit (only swap fee deducted)");

        // The donated 10,000 USDC is "orphaned" in the pool's token balance —
        // no LP has a claim against it because reserves[] never recorded it.
        uint256 poolBalance     = usdc.balanceOf(address(pool));
        uint256 poolReserves    = pool.reserves(address(usdc));
        assertGt(poolBalance, poolReserves,
            "orphaned donation should sit outside reserves[]");
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
        address first  = address(0xF1);
        address second = address(0x52);

        usdc.mint(first,  1_000_000_000); //  1,000 USDC
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
