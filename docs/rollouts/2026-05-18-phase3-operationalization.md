# Phase 3 Operationalization Rollout

**Date:** 2026-05-18
**Branch:** `phase3-ops/rollout`
**Spec:** `docs/superpowers/specs/2026-05-18-phase3-operationalization-design.md`
**Plan:** `docs/superpowers/plans/2026-05-18-phase3-operationalization.md`

## Why this rollout

P3 deployed the oracle layer (1 `CumulativeDeviationGuard`, 7 `OracleAggregator`s,
7 secondary feeds) but the operational wiring that makes two-source aggregation
real was missing: the secondary feeds had no keeper driving them, and nothing
called the deviation guard. This rollout closes both gaps.

## Keeper EOA

`0xe8fe70433779359C4ae72CF3b801Ed569Ba9b8C3` — the EOA that already writes the
primary feeds; now also the `writer` of the 7 secondary feeds and the signer of
the `guard-record` monitor.

## 1. Secondary-feed writer migration

`MigrateSecondaryWriters.s.sol` — the Governance Safe called `setWriter(keeperEOA)`
on each of the 7 secondary `MockChainlinkFeedV2` feeds.

- The first broadcast hit an Arc-testnet nonce-sync error mid-run (`EOA nonce
  changed unexpectedly`). No `setWriter` had landed. The stale broadcast file
  was cleared and the script re-run (it is re-runnable — it skips an
  already-migrated feed); the retry completed `ONCHAIN EXECUTION COMPLETE &
  SUCCESSFUL`.
- Verified on-chain: all 7 secondary feeds' `writer()` == the keeper EOA.

## 2. Keeper dual-push

`ops/keepalive/multi-feed-push.mjs` refactored: the per-feed-address push is now
a `pushFeedAddress` helper called for both the primary feed and the P3 secondary
feed. Each address keeps its own deviation cap (vs its own on-chain `prev`) and
its own staleness check.

- Deployed to the VPS at `/home/arcora/arcoradex-feeds/multi-feed-push.mjs`.
- The keeper `.env` gained 7 `P3_SECONDARY_*` variables.
- Verified run: `done updated=10 skipped=4 errored=0` — both primary and
  secondary feeds pushed for all 7 tokens.

**Secondary-feed convergence:** the EURC/TRYC/BRLC secondary feeds were deployed
at rough placeholder prices; the keeper walks them toward the live price at the
per-feed deviation cap (150 bps/tick, every 30 min). They converge to the live
FX rate within a few hours — well before the P3 Timelock batch executes
(≈ 2026-05-19 21:35 UTC). USD-pegged secondaries were already at peg and need no
walk.

## 3. `guard-record` monitor

New `ops/keepalive/guard-record.mjs` + `arcoradex-guard-record.service` /
`.timer`. Reads each `OracleAggregator.latestRoundData()`, scales the 8-decimal
answer to 1e18, and calls `CumulativeDeviationGuard.record(token, price)` —
producing the `PriceObserved` / `CircuitBreakerTripped` event stream. Signs with
the keeper EOA (`record` is permissionless).

- Deployed to the VPS; the timer is enabled (30 min cadence, `OnBootSec=7min` so
  it trails a keeper push).
- First run: `done recorded=4 errored=3`. The 3 errors are EURC/TRYC/BRLC —
  **expected and transient**: while those secondary feeds are still
  cap-walking toward the live price, their aggregators revert `SourcesDiverge`
  (primary vs not-yet-converged secondary). `guard-record` errors only the
  affected token and records the rest. Once the secondaries converge (a few
  hours), all 7 aggregators read healthy and `guard-record` records all 7.

## 4. Documentation & memory

- `docs/rollouts/2026-05-14-phase3-oracle.md` — corrected the
  `CumulativeDeviationGuard` description ("rolling signed drift" →
  tumbling-window absolute deviation) and added the per-token `maxStaleSeconds`
  column.
- Auto-memory `arcoradex_role_eoas.md` — added the guard address and the
  secondary-writer = keeper fact.

## Downstream / P5

- The two feeds per token are still driven from a single price source
  (CoinGecko) duplicated across both feeds. A genuine independent second
  provider (e.g. Pyth) is a P5 item.
- On-chain auto-pause wired to the `CumulativeDeviationGuard` remains P5; the
  guard stays event-only.

## Status

- ✅ Secondary-feed writer migrated to the keeper EOA (7/7)
- ✅ Keeper drives both primary and secondary feeds
- ✅ `guard-record` monitor deployed and on a 30-min timer
- ⏳ EURC/TRYC/BRLC secondary feeds converging to live price (keeper-walked;
  healthy within hours, before the P3 batch)
