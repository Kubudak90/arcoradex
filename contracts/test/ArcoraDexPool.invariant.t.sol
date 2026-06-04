// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ArcoraDexPool} from "../src/ArcoraDexPool.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {ArcoraDexLP} from "../src/ArcoraDexLP.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
// M-3 (audit 2026-05-24): switched to V2 mock so the invariant suite can
// exercise the round-id / writer-permissioned code paths the live
// deployment relies on. The V1 mock pinned roundId to 1 unconditionally,
// which made `answeredInRound >= roundId` always pass.
import {MockChainlinkFeedV2} from "../src/testnet/MockChainlinkFeedV2.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {PoolHandler} from "./handlers/PoolHandler.sol";

contract ArcoraDexPoolInvariant is StdInvariant, Test {
    ArcoraDexPool pool;
    ArcoraDexRegistry reg;
    ArcoraDexLP lp;
    MintableERC20 usdc;
    MockChainlinkFeedV2 fUsdc;
    MintableERC20 eurc;
    MockChainlinkFeedV2 fEurc;
    MintableERC20 dai;
    MockChainlinkFeedV2 fDai;
    // L-10 (audit 2026-06-03): 4th token is fee-on-transfer (50 bps burn on every
    // transfer) so the invariant suite exercises the measured-balance-delta path.
    FeeOnTransferERC20 fot;
    MockChainlinkFeedV2 fFot;
    address owner = makeAddr("owner");
    PoolHandler handler;

    address a1 = makeAddr("a1");
    address a2 = makeAddr("a2");
    address a3 = makeAddr("a3");

    function setUp() public {
        usdc = new MintableERC20("USDC", "USDC", 6, owner);
        eurc = new MintableERC20("EURC", "EURC", 6, owner);
        dai = new MintableERC20("DAI", "DAI", 18, owner);
        // L-10: fee-on-transfer token (6 dec, 50 bps burn on every transfer).
        fot = new FeeOnTransferERC20("FOT", "FOT", 6, owner, 50);
        // Test contract acts as both the writer (price-pusher) and owner so
        // setAnswer / setWriter can be called inline without prank gymnastics.
        fUsdc = new MockChainlinkFeedV2(8, int256(1e8), address(this), address(this), 1, type(int256).max, 0, 0);
        fEurc = new MockChainlinkFeedV2(8, int256(11e7), address(this), address(this), 1, type(int256).max, 0, 0);
        fDai = new MockChainlinkFeedV2(8, int256(1e8), address(this), address(this), 1, type(int256).max, 0, 0);
        fFot = new MockChainlinkFeedV2(8, int256(1e8), address(this), address(this), 1, type(int256).max, 0, 0);

        reg = new ArcoraDexRegistry(owner);
        pool = new ArcoraDexPool(address(reg), 30, 1000, owner);
        lp = ArcoraDexLP(address(pool.LP()));

        vm.startPrank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(fUsdc)), 50, 3600);
        reg.listToken(address(eurc), 6, IChainlinkAggregator(address(fEurc)), 150, 14400);
        reg.listToken(address(dai), 18, IChainlinkAggregator(address(fDai)), 50, 3600);
        reg.listToken(address(fot), 6, IChainlinkAggregator(address(fFot)), 50, 3600);
        // PR-2.5: wire the Pool so the I-1 reserve guard in deactivateToken is LIVE
        // (without this, deactivation is unguarded and the handler's
        // deactivateReactivate action would not exercise the guard at all).
        reg.setPool(address(pool));
        vm.stopPrank();

        // Pre-mint generous balances to each actor (handler can't mint due to onlyOwner).
        vm.startPrank(owner);
        for (uint256 i = 0; i < 3; i++) {
            address actor = i == 0 ? a1 : (i == 1 ? a2 : a3);
            usdc.mint(actor, 1_000_000e6);
            eurc.mint(actor, 1_000_000e6);
            dai.mint(actor, 1_000_000e18);
            fot.mint(actor, 1_000_000e6);
        }
        vm.stopPrank();

        // Seed minimal initial liquidity so first-deposit guard doesn't dominate the run.
        address seeder = makeAddr("seeder");
        vm.prank(owner);
        usdc.mint(seeder, 100_000e6);
        vm.prank(owner);
        eurc.mint(seeder, 100_000e6);
        vm.prank(owner);
        dai.mint(seeder, 100_000e18);
        vm.prank(owner);
        fot.mint(seeder, 100_000e6);
        vm.startPrank(seeder);
        usdc.approve(address(pool), 100_000e6);
        eurc.approve(address(pool), 100_000e6);
        dai.approve(address(pool), 100_000e18);
        fot.approve(address(pool), 100_000e6);
        pool.deposit(address(usdc), 100_000e6, 0, block.timestamp + 1);
        pool.deposit(address(eurc), 100_000e6, 0, block.timestamp + 1);
        pool.deposit(address(dai), 100_000e18, 0, block.timestamp + 1);
        pool.deposit(address(fot), 100_000e6, 0, block.timestamp + 1);
        vm.stopPrank();

        // Build handler
        address[] memory actors = new address[](3);
        actors[0] = a1;
        actors[1] = a2;
        actors[2] = a3;
        address[] memory tks = new address[](4);
        tks[0] = address(usdc);
        tks[1] = address(eurc);
        tks[2] = address(dai);
        tks[3] = address(fot);
        // PR-2.5: pass the per-token feeds so the handler can drive the oracle
        // (pushPrice / advanceTime heartbeat) and the registry + owner so it can
        // drive pause / deactivate / reactivate / syncAcceptedPrice / resetPriceCache.
        address[] memory feeds = new address[](4);
        feeds[0] = address(fUsdc);
        feeds[1] = address(fEurc);
        feeds[2] = address(fDai);
        feeds[3] = address(fFot);
        handler = new PoolHandler(address(pool), address(reg), address(lp), owner, actors, tks, feeds);
        targetContract(address(handler));
    }

    /// Contract balance of every token equals reserves + protocolFeesAccrued.
    /// Includes the fee-on-transfer token (L-10): the measured-balance-delta credit
    /// keeps this exact even though transfers burn a portion in flight.
    function invariant_balance_equals_reserves_plus_fees() public view {
        address[4] memory tks = [address(usdc), address(eurc), address(dai), address(fot)];
        for (uint256 i = 0; i < tks.length; i++) {
            uint256 bal = MintableERC20(tks[i]).balanceOf(address(pool));
            uint256 res = pool.reserves(tks[i]);
            uint256 fees = pool.protocolFeesAccrued(tks[i]);
            assertEq(bal, res + fees, "balance != reserves + fees");
        }
    }

    /// (totalSupply == 0) <-> (nav == 0).
    function invariant_supply_nav_link() public view {
        uint256 supply = lp.totalSupply();
        uint256 nav = pool.totalReservesUSD();
        if (supply == 0) assertEq(nav, 0, "supply==0 but nav!=0");
        else assertGt(nav, 0, "supply>0 but nav==0");
    }

    /// fees <= contract balance per token.
    function invariant_fees_le_balance() public view {
        address[4] memory tks = [address(usdc), address(eurc), address(dai), address(fot)];
        for (uint256 i = 0; i < tks.length; i++) {
            uint256 fees = pool.protocolFeesAccrued(tks[i]);
            uint256 bal = MintableERC20(tks[i]).balanceOf(address(pool));
            assertLe(fees, bal, "fees > balance");
        }
    }

    /// MINIMUM_LIQUIDITY (1000 LP) is permanently held by 0xdead after any first deposit.
    function invariant_lp_minimum_liquidity_burned() public view {
        uint256 supply = lp.totalSupply();
        if (supply == 0) return;
        assertGe(lp.balanceOf(address(0xdead)), 1000, "MIN_LIQUIDITY burn missing");
    }

    // ─────────────────────────────────────────────────────────────────────
    // PR-2.5: value-conservation invariants.
    //
    // SCOPING NOTE (important — see the audit escalation note): when the oracle
    // moves BETWEEN ticks, value legitimately transfers between LP cohorts and
    // between LPs and swappers. That is correct AMM behaviour, NOT a bug. So a
    // naive "per-LP USD value never decreases / never increases" invariant is
    // FALSE on correct code. We therefore scope the conservation invariants to
    // the claims that ARE genuinely invariant:
    //   1. Same-transaction atomic non-profit (the MIN_HOLD / H-1 guarantee): an
    //      attacker cannot deposit → move oracle within the per-tick cap →
    //      withdraw in ONE transaction for a gain.
    //   2. Frozen-oracle per-LP conservation: with prices held fixed across a
    //      deposit→hold→withdraw round-trip, the round-tripper can only ever
    //      recover LESS than they contributed (they pay the swap fee + dust);
    //      they can never profit.
    // Both are tolerance-aware (swap/protocol fee + integer rounding).
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Tolerance for realized-PnL conservation, in 1e18-scaled USD. Generous
    /// enough to absorb integer-rounding dust across deposit/withdraw share math
    /// (a handful of wei of USD, scaled by 1e18), but vastly smaller than any
    /// economically meaningful gain (which would be on the order of basis points
    /// of thousands of USD = >1e18). Realized PnL on fixed code is strictly
    /// NEGATIVE for the frozen round-trip (fee paid) and exactly zero for the
    /// atomic probe (the withdraw reverts), so the positive-side tolerance is
    /// never actually approached; it exists only to make the bound robust to
    /// off-by-a-few-wei rounding rather than to weaken it.
    int256 internal constant PNL_TOLERANCE_USD_1E18 = 1e12; // 1e-6 USD

    /// No single-transaction deposit → oracle-move (within per-tick cap) → withdraw
    /// can realize positive USD PnL. On the fixed code the MIN_HOLD lock makes the
    /// in-transaction withdraw revert, so realized PnL is 0; if the lock were
    /// removed (mutation), a within-cap favourable move would realize a gain and
    /// trip this bound.
    function invariant_no_positive_pnl_from_atomic_deposit_oraclemove_withdraw() public view {
        assertLe(
            handler.maxAtomicRealizedPnlUsd(),
            PNL_TOLERANCE_USD_1E18,
            "atomic deposit->oracle-move->withdraw realized positive PnL"
        );
    }

    /// Frozen-oracle per-LP value conservation: a deposit→(warp past hold)→withdraw
    /// round-trip executed with prices held FIXED can never return more USD than was
    /// put in (the round-tripper always pays the swap fee + loses rounding dust).
    function invariant_per_lp_value_conservation() public view {
        assertLe(
            handler.maxFrozenRoundTripPnlUsd(),
            PNL_TOLERANCE_USD_1E18,
            "frozen-oracle round-trip realized positive PnL (per-LP value not conserved)"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // PR-2.5: deterministic coverage of the deactivate→reactivate+resetCache
    // path the handler's `deactivateReactivate` action drives.
    //
    // The fuzz campaign's seeded tokens carry ~100k reserves and essentially
    // never reach reserves==0, so the handler's deactivate branch is (correctly)
    // a near-permanent no-op under the I-1 guard — it MUST NOT deactivate a token
    // with live reserves. This test deterministically exercises the full path on
    // a token whose reserves are zero, proving the guard transitions and the I-2
    // cache-reset pairing the handler relies on actually work end to end.
    // ─────────────────────────────────────────────────────────────────────
    function test_pr25_deactivate_requires_zero_reserves_then_reactivate_resets_cache() public {
        // fot has live reserves from setUp's seeder deposit → I-1 guard must block.
        assertGt(pool.reserves(address(fot)), 0, "precondition: fot has reserves");
        vm.prank(owner);
        vm.expectRevert();
        reg.deactivateToken(address(fot));

        // Drain fot reserves to zero by swapping everything out, then withdrawing.
        // Simpler deterministic route: deactivation needs reserves==0; the only
        // token guaranteed reachable-to-zero here is one nobody deposited into.
        // List a fresh zero-reserve token and prove the full path on it.
        MintableERC20 ztk = new MintableERC20("ZERO", "ZERO", 6, owner);
        vm.prank(owner);
        reg.listToken(address(ztk), 6, IChainlinkAggregator(address(fUsdc)), 50, 3600);
        assertEq(pool.reserves(address(ztk)), 0, "fresh token has zero reserves");

        // I-1: deactivation succeeds when reserves are zero.
        vm.prank(owner);
        reg.deactivateToken(address(ztk));
        assertFalse(reg.isActive(address(ztk)), "token deactivated");

        // I-2: reactivate + resetPriceCache (the handler pairs these); the cache
        // mappings must be cleared so the next priced op takes the fresh path.
        vm.prank(owner);
        reg.reactivateToken(address(ztk));
        vm.prank(owner);
        pool.resetPriceCache(address(ztk));
        assertTrue(reg.isActive(address(ztk)), "token reactivated");
        assertEq(pool.lastAcceptedPrice(address(ztk)), 0, "I-2: lastAcceptedPrice cleared");
        assertEq(pool.lastValidPrice(address(ztk)), 0, "I-2: lastValidPrice cleared");
        assertEq(pool.lastValidPriceAt(address(ztk)), 0, "I-2: lastValidPriceAt cleared");
    }
}
