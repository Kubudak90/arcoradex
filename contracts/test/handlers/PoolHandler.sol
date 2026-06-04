// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexPool} from "../../src/ArcoraDexPool.sol";
import {ArcoraDexRegistry} from "../../src/ArcoraDexRegistry.sol";
import {ArcoraDexLP} from "../../src/ArcoraDexLP.sol";
import {MintableERC20} from "../../src/testnet/MintableERC20.sol";
import {MockChainlinkFeedV2} from "../../src/testnet/MockChainlinkFeedV2.sol";

/// @notice Random-action driver for the invariant tests. Calls public Pool entry points
/// with bounded inputs, fronted by a small set of actors. Every action is wrapped in
/// `try` so the handler never reverts the invariant runner.
///
/// PR-2.5 expansion: in addition to deposit/withdraw/swap, the handler now drives the
/// oracle (`pushPrice`), the clock (`advanceTime`), pause/unpause, deactivate/reactivate
/// (respecting the I-1 reserve guard + I-2 cache-reset pairing) and `syncAcceptedPrice`.
/// It also maintains per-actor USD ghost accounting (deposited-in / withdrawn-out) so the
/// invariant test can state value-conservation bounds, plus a self-contained atomic
/// deposit→oracle-move→withdraw probe for the H-2 single-tick JIT concern.
contract PoolHandler is Test {
    ArcoraDexPool public pool;
    ArcoraDexRegistry public reg;
    ArcoraDexLP public lp;
    address public owner;
    address[] public actors;
    address[] public tokens;
    // Per-token registry oracle feed (the test contract is the feed writer + owner).
    mapping(address token => MockChainlinkFeedV2) public feedOf;

    // ── Call counters (surfaced by invariant_call_summary) ──────────────
    uint256 public depositCalls;
    uint256 public withdrawCalls;
    uint256 public swapCalls;
    uint256 public pushPriceCalls;
    uint256 public advanceTimeCalls;
    uint256 public pauseUnpauseCalls;
    uint256 public deactReactCalls;
    uint256 public syncCalls;
    uint256 public atomicProbeCalls;

    // ── Per-actor USD ghost accounting (1e18-scaled USD) ────────────────
    // depositedUsd: cumulative USD value credited at deposit time (deposit-time price).
    // withdrawnUsd: cumulative USD value received at withdraw time (withdraw-time price).
    // These are recorded at the price prevailing in the same transaction as the flow,
    // so they are price-consistent with the share math the pool itself runs.
    mapping(address actor => uint256) public depositedUsd;
    mapping(address actor => uint256) public withdrawnUsd;

    // Worst observed positive realized PnL from the atomic probe (should stay 0 on
    // fixed code because the MIN_HOLD lock makes the in-transaction withdraw revert).
    int256 public maxAtomicRealizedPnlUsd;

    // Worst observed positive realized PnL from a FROZEN-ORACLE round-trip
    // (deposit → warp past MIN_HOLD → withdraw-all, with the price held fixed across
    // the window). With no price move the round-tripper can only ever get back LESS
    // than they put in (they pay the swap fee + lose dust to rounding), so this must
    // stay <= a fee+rounding tolerance. It is the soundly-statable per-LP
    // value-conservation claim: under a frozen oracle, an LP cannot extract more
    // value than they contributed. (Under a MOVING oracle, value legitimately
    // transfers between LP cohorts and swappers, so a per-LP USD-profit bound is NOT
    // an invariant — see the test-file header note.)
    int256 public maxFrozenRoundTripPnlUsd;
    // Count of frozen round-trips that actually completed a withdraw (non-vacuity).
    uint256 public frozenRoundTripCompletions;
    uint256 public frozenRoundTripCalls;

    constructor(
        address pool_,
        address reg_,
        address lp_,
        address owner_,
        address[] memory actors_,
        address[] memory tokens_,
        address[] memory feeds_
    ) {
        pool = ArcoraDexPool(pool_);
        reg = ArcoraDexRegistry(reg_);
        lp = ArcoraDexLP(lp_);
        owner = owner_;
        actors = actors_;
        tokens = tokens_;
        require(feeds_.length == tokens_.length, "feeds/tokens length mismatch");
        for (uint256 i = 0; i < tokens_.length; i++) {
            feedOf[tokens_[i]] = MockChainlinkFeedV2(feeds_[i]);
        }
    }

    // ── Internal: keeper heartbeat — re-publish every feed's CURRENT answer so
    // `updatedAt` stays fresh after a warp. Value-neutral (answer unchanged). ─────
    function _restampAllFeeds() internal {
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; i++) {
            MockChainlinkFeedV2 f = feedOf[tokens[i]];
            (, int256 cur,,,) = f.latestRoundData();
            if (cur <= 0) continue;
            address w = f.writer();
            vm.prank(w);
            try f.setAnswer(cur) {} catch {}
        }
    }

    // ── Internal: move a token's feed answer by `deltaBps` in [-40, +40] bps,
    // clamped strictly positive. Returns true if a setAnswer was attempted. ─────
    function _pushWithinCap(address token, int256 deltaBps) internal {
        MockChainlinkFeedV2 f = feedOf[token];
        (, int256 cur,,,) = f.latestRoundData();
        if (cur <= 0) return;
        int256 bps = int256(bound(uint256(deltaBps), 0, 80)) - 40; // [-40, 40]
        int256 next = cur + (cur * bps) / 10_000;
        if (next <= 0) next = cur / 2 + 1;
        address w = f.writer();
        vm.prank(w);
        try f.setAnswer(next) {} catch {}
    }

    // ── Internal: 1e18-scaled USD value of `amount` of `token` at the feed price ─
    function _usdValue1e18(address token, uint256 amount) internal view returns (uint256) {
        MockChainlinkFeedV2 feed = feedOf[token];
        (, int256 answer,,,) = feed.latestRoundData();
        if (answer <= 0) return 0;
        uint8 feedDec = feed.decimals();
        uint8 tokDec = MintableERC20(token).decimals();
        // price1e18 = answer scaled to 1e18
        uint256 price1e18;
        if (feedDec == 18) price1e18 = uint256(answer);
        else if (feedDec < 18) price1e18 = uint256(answer) * (10 ** (18 - feedDec));
        else price1e18 = uint256(answer) / (10 ** (feedDec - 18));
        return (amount * price1e18) / (10 ** tokDec);
    }

    // ── deposit ──────────────────────────────────────────────────────
    function deposit(uint256 actorSeed, uint256 tokenSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        address token = tokens[tokenSeed % tokens.length];
        uint8 dec = MintableERC20(token).decimals();
        uint256 amount = bound(amountSeed, 10 ** dec, 10_000 * 10 ** dec);
        if (MintableERC20(token).balanceOf(actor) < amount) return;

        // Snapshot pool token balance so we can credit the MEASURED delta to the
        // ghost (matches the L-10 fee-on-transfer accounting the pool itself uses).
        uint256 poolBalBefore = MintableERC20(token).balanceOf(address(pool));

        vm.prank(actor);
        MintableERC20(token).approve(address(pool), amount);
        vm.prank(actor);
        try pool.deposit(token, amount, 0, block.timestamp + 1) {
            uint256 received = MintableERC20(token).balanceOf(address(pool)) - poolBalBefore;
            depositedUsd[actor] += _usdValue1e18(token, received);
            depositCalls++;
        } catch {}
    }

    // ── withdraw ─────────────────────────────────────────────────────
    function withdraw(uint256 actorSeed, uint256 tokenSeed, uint256 lpSeed) external {
        address actor = actors[actorSeed % actors.length];
        address token = tokens[tokenSeed % tokens.length];
        uint256 bal = lp.balanceOf(actor);
        if (bal == 0) return;
        uint256 lpAmt = bound(lpSeed, 1, bal);

        uint256 actorTokBefore = MintableERC20(token).balanceOf(actor);
        vm.prank(actor);
        try pool.withdraw(token, lpAmt, 0, block.timestamp + 1) {
            uint256 out = MintableERC20(token).balanceOf(actor) - actorTokBefore;
            withdrawnUsd[actor] += _usdValue1e18(token, out);
            withdrawCalls++;
        } catch {}
    }

    // ── swap ─────────────────────────────────────────────────────────
    function swap(uint256 actorSeed, uint256 inSeed, uint256 outSeed, uint256 amtSeed) external {
        address actor = actors[actorSeed % actors.length];
        address tIn = tokens[inSeed % tokens.length];
        address tOut = tokens[outSeed % tokens.length];
        if (tIn == tOut) return;

        uint8 dec = MintableERC20(tIn).decimals();
        uint256 amount = bound(amtSeed, 10 ** dec, 1_000 * 10 ** dec);
        if (MintableERC20(tIn).balanceOf(actor) < amount) return;

        vm.prank(actor);
        MintableERC20(tIn).approve(address(pool), amount);
        vm.prank(actor);
        try pool.swap(tIn, tOut, amount, 0, block.timestamp + 1, actor) {
            swapCalls++;
        } catch {}
    }

    // ── pushPrice: move a token's oracle answer by a bounded delta ────────
    /// @dev Bound the per-tick move to ±40 bps of the current answer. This keeps
    /// most moves inside the smallest configured `maxOracleDeviationBps` (50 bps),
    /// so the pool keeps trading (the deviation ratchet only trips occasionally),
    /// while still letting the accepted price walk cumulatively over many ticks —
    /// the exact pattern the H-2 cumulative-walk concern is about. `setAnswer`
    /// requires answer > 0, so we clamp the result to a positive floor.
    function pushPrice(uint256 tokenSeed, int256 deltaBps) external {
        // setAnswer is writer-gated; _pushWithinCap pranks the registered writer.
        _pushWithinCap(tokens[tokenSeed % tokens.length], deltaBps);
        pushPriceCalls++;
    }

    // ── advanceTime: warp forward up to ~2 days ──────────────────────────
    /// @dev Exercises the 1h MIN_HOLD lock and the cache-staleness windows. We also
    /// must keep the registry feeds "fresh": warping the clock without re-stamping
    /// the oracle would push `updatedAt` outside `maxStaleSeconds`, after which every
    /// priced op falls back to the cache (and eventually NoValidPrice once the cache
    /// TTL — when set — expires). To keep the campaign productive we re-stamp every
    /// feed at its current answer after the warp (simulating a keeper heartbeat),
    /// which is itself a legitimate, value-neutral oracle action.
    function advanceTime(uint256 secondsSeed) external {
        uint256 dt = bound(secondsSeed, 1, 2 days);
        vm.warp(block.timestamp + dt);
        // Keeper heartbeat: re-publish current answers so freshness holds.
        _restampAllFeeds();
        advanceTimeCalls++;
    }

    // ── pauseUnpause: toggle the pool's pause flag (owner) ───────────────
    /// @dev Never leaves the pool paused across calls: if currently paused we always
    /// unpause, otherwise we pause then immediately unpause. This fuzzes the paused
    /// window (the whenNotPaused revert path is caught by the deposit/swap/withdraw
    /// try-blocks) without deadlocking the campaign in a permanently-paused state.
    function pauseUnpause(uint256 seed) external {
        if (pool.paused()) {
            vm.prank(owner);
            try pool.unpause() {} catch {}
        } else if (seed % 2 == 0) {
            vm.prank(owner);
            try pool.pause() {} catch {}
            // unpause again immediately so subsequent actions can make progress.
            vm.prank(owner);
            try pool.unpause() {} catch {}
        } else {
            // Leave paused for ONE tick so a paused-window invariant check happens,
            // relying on the next pauseUnpause call (or any owner unpause) to lift it.
            vm.prank(owner);
            try pool.pause() {} catch {}
        }
        pauseUnpauseCalls++;
    }

    // ── deactivateReactivate: exercise I-1 guard + I-2 cache-reset pairing ─
    /// @dev Deactivation is only legal when the token's pool reserves are zero (I-1
    /// guard, enforced now that setUp wires `reg.setPool(pool)`). Forcing reserves to
    /// zero would distort the rest of the campaign, so when reserves are non-zero we
    /// simply skip (no-op, no revert). When a token IS already inactive we reactivate
    /// it AND call `resetPriceCache` in the same action (the I-2 pairing) so the next
    /// priced op for that token takes the fresh-oracle path. After a cache reset the
    /// next op needs a fresh oracle reading; the feed is kept fresh by advanceTime's
    /// heartbeat and pushPrice, and lastAcceptedPrice re-seeds on the next priced op.
    function deactivateReactivate(uint256 tokenSeed) external {
        address token = tokens[tokenSeed % tokens.length];
        if (!reg.isActive(token)) {
            // Reactivate + reset cache together (I-2).
            vm.prank(owner);
            try reg.reactivateToken(token) {
                vm.prank(owner);
                try pool.resetPriceCache(token) {} catch {}
                // Re-seed the accepted/cache baseline so post-reset ops don't all
                // revert NoValidPrice: sync against the (fresh) feed.
                vm.prank(owner);
                try pool.syncAcceptedPrice(token) {} catch {}
                deactReactCalls++;
            } catch {}
            return;
        }
        // Active: only deactivate when reserves are already zero (respect I-1).
        if (pool.reserves(token) != 0) return; // no-op, do NOT revert
        vm.prank(owner);
        try reg.deactivateToken(token) {
            deactReactCalls++;
        } catch {}
    }

    // ── syncPrice: owner-forced accepted-price/cache resync ──────────────
    function syncPrice(uint256 tokenSeed) external {
        address token = tokens[tokenSeed % tokens.length];
        if (!reg.isActive(token)) return; // syncAcceptedPrice reads the oracle; skip if inactive path noisy
        vm.prank(owner);
        try pool.syncAcceptedPrice(token) {
            syncCalls++;
        } catch {}
    }

    // ── atomicProbe: H-2 single-tick JIT non-profit probe ────────────────
    /// @dev Within ONE handler call: deposit token X, push X's oracle within the
    /// per-tick deviation cap, then attempt to withdraw the freshly-minted LP back to
    /// X — WITHOUT advancing the clock. On the fixed code the MIN_HOLD lock makes the
    /// in-transaction withdraw revert, so no PnL is ever realized (the H-1 guarantee).
    /// We record the realized USD PnL (usdOut at exit price − usdIn at entry price);
    /// `invariant_no_positive_pnl_from_atomic_deposit_oraclemove_withdraw` asserts it
    /// never goes positive beyond a fee+rounding tolerance. This is mutation-resistant:
    /// were the hold removed, a within-cap favourable oracle move would let the atomic
    /// round-trip realize a positive PnL and trip the invariant.
    function atomicProbe(uint256 actorSeed, uint256 tokenSeed, uint256 amountSeed, int256 deltaBps) external {
        address actor = actors[actorSeed % actors.length];
        address token = tokens[tokenSeed % tokens.length];
        if (!reg.isActive(token)) return;
        uint8 dec = MintableERC20(token).decimals();
        uint256 amount = bound(amountSeed, 10 ** dec, 5_000 * 10 ** dec);
        if (MintableERC20(token).balanceOf(actor) < amount) return;

        atomicProbeCalls++;

        uint256 usdIn;
        uint256 mintedLp;
        {
            uint256 lpBefore = lp.balanceOf(actor);
            uint256 poolBalBefore = MintableERC20(token).balanceOf(address(pool));
            vm.prank(actor);
            MintableERC20(token).approve(address(pool), amount);
            vm.prank(actor);
            try pool.deposit(token, amount, 0, block.timestamp + 1) {} catch {
                return; // deposit itself failed (e.g. paused / deviation) — nothing to probe
            }
            uint256 received = MintableERC20(token).balanceOf(address(pool)) - poolBalBefore;
            usdIn = _usdValue1e18(token, received);
            // Keep the global ghost consistent with this deposit.
            depositedUsd[actor] += usdIn;
            mintedLp = lp.balanceOf(actor) - lpBefore;
        }
        if (mintedLp == 0) return;

        // Oracle move within the per-tick cap (±up to 40 bps, < min 50 bps cap).
        _pushWithinCap(token, deltaBps);

        // Attempt the in-transaction withdraw of the freshly minted LP (no warp).
        uint256 actorTokBefore = MintableERC20(token).balanceOf(actor);
        vm.prank(actor);
        try pool.withdraw(token, mintedLp, 0, block.timestamp + 1) {
            uint256 usdOut = _usdValue1e18(token, MintableERC20(token).balanceOf(actor) - actorTokBefore);
            withdrawnUsd[actor] += usdOut;
            // Realized PnL at consistent prices (entry vs exit).
            int256 pnl = int256(usdOut) - int256(usdIn);
            if (pnl > maxAtomicRealizedPnlUsd) maxAtomicRealizedPnlUsd = pnl;
        } catch {
            // Expected on fixed code: MIN_HOLD lock blocks the atomic withdraw.
            // LP retained, no realized PnL — the H-1 guarantee. The held LP is
            // still tracked in depositedUsd, so global conservation stays sound.
        }
    }

    // ── frozenRoundTrip: frozen-oracle per-LP value-conservation probe ───
    /// @dev Deposit token X, advance PAST the MIN_HOLD lock, then withdraw ALL the
    /// freshly-minted LP back to X — with X's oracle (and every other oracle) held
    /// FIXED across the whole window. Because no price moved, the round-tripper can
    /// only ever recover LESS USD than they contributed (they pay the swap fee on
    /// withdraw and lose at most a wei or two to integer rounding); they can NEVER
    /// profit. We record the realized PnL (usdOut − usdIn at the same frozen price)
    /// and assert (via invariant_per_lp_value_conservation) it stays <= a small
    /// fee+rounding tolerance.
    ///
    /// This is the soundly-statable per-LP conservation claim. We deliberately do NOT
    /// move the oracle here: under a moving oracle, value legitimately transfers
    /// between LP cohorts, so a per-LP USD bound is not an invariant.
    function frozenRoundTrip(uint256 actorSeed, uint256 tokenSeed, uint256 amountSeed) external {
        frozenRoundTripCalls++;
        address actor = actors[actorSeed % actors.length];
        address token = tokens[tokenSeed % tokens.length];
        if (!reg.isActive(token)) return;
        // Don't run while paused — deposit would just revert.
        if (pool.paused()) return;
        uint8 dec = MintableERC20(token).decimals();
        uint256 amount = bound(amountSeed, 10 ** dec, 5_000 * 10 ** dec);
        if (MintableERC20(token).balanceOf(actor) < amount) return;

        uint256 usdIn;
        uint256 mintedLp;
        {
            uint256 lpBefore = lp.balanceOf(actor);
            uint256 poolBalBefore = MintableERC20(token).balanceOf(address(pool));
            vm.prank(actor);
            MintableERC20(token).approve(address(pool), amount);
            vm.prank(actor);
            try pool.deposit(token, amount, 0, block.timestamp + 1) {} catch {
                return;
            }
            uint256 received = MintableERC20(token).balanceOf(address(pool)) - poolBalBefore;
            usdIn = _usdValue1e18(token, received);
            depositedUsd[actor] += usdIn;
            mintedLp = lp.balanceOf(actor) - lpBefore;
        }
        if (mintedLp == 0) return;

        // Warp past the hold WITHOUT changing any oracle ANSWER (frozen prices).
        // We re-stamp updatedAt at the SAME answer so the freshness check passes;
        // the price is unchanged across the round-trip window.
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
        _restampAllFeeds();

        uint256 actorTokBefore = MintableERC20(token).balanceOf(actor);
        vm.prank(actor);
        try pool.withdraw(token, mintedLp, 0, block.timestamp + 1) {
            uint256 usdOut = _usdValue1e18(token, MintableERC20(token).balanceOf(actor) - actorTokBefore);
            withdrawnUsd[actor] += usdOut;
            frozenRoundTripCompletions++;
            int256 pnl = int256(usdOut) - int256(usdIn);
            if (pnl > maxFrozenRoundTripPnlUsd) maxFrozenRoundTripPnlUsd = pnl;
        } catch {
            // Withdraw can still revert if a between-call action deactivated the
            // token or drained reserves below the redeemable amount; LP retained.
        }
    }
}
