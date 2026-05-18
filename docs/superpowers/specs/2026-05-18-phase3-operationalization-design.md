# Phase 3 Operationalization — Design

**Date:** 2026-05-18
**Branch:** `phase3-ops/operationalization`
**Status:** design — awaiting implementation plan

## 1. Goal

Operationalize the Phase 3 oracle layer that is already deployed on Arc
testnet. P3 deployed 15 contracts (1 `CumulativeDeviationGuard`, 7
`OracleAggregator`s, 7 secondary `MockChainlinkFeedV2` feeds) and scheduled the
Registry-migration Timelock batch, but the operational wiring that makes the
two-source aggregation real — a keeper driving the secondary feeds, and an
off-chain monitor feeding the deviation guard — is not yet in place. This phase
closes those gaps.

## 2. Context

- The keeper lives in-repo at `ops/keepalive/multi-feed-push.mjs` (viem, ESM),
  deployed to the VPS (`194.163.136.1`) and run every 30 min by a systemd
  timer (`arcoradex-feeds.timer` → `arcoradex-feeds.service`). It pushes
  CoinGecko-derived prices to the 7 **primary** feeds via `FEED_*` env vars,
  signing with `KEEPER_PRIVATE_KEY`.
- The 7 **secondary** feeds were deployed by P3 with their `writer` role set to
  the deployer EOA — so the keeper cannot yet push to them. Ownership of the
  secondary feeds is the Governance Safe (transferred + accepted in P3).
- The `CumulativeDeviationGuard` has no caller — `record` is permissionless and
  event-only, but nothing currently invokes it.
- The P3 Registry-migration Timelock batch executes ≈ 2026-05-19 21:35 UTC. It
  points the Registry's `usdOracle` for each token at that token's aggregator.

## 3. Components

### 3.1 Secondary-feed writer migration (governance, on-chain)

A Forge script `contracts/script/MigrateSecondaryWriters.s.sol` that has the
Governance Safe call `setWriter(keeperEOA)` on each of the 7 secondary feeds.

- `MockChainlinkFeedV2.setWriter(address)` is `onlyOwner`; the secondary feeds'
  owner is the Governance Safe — so each call is a Safe transaction, executed
  via the existing `SafeSigHelpers.execCall` pattern (same as
  `P3GovernanceActions.s.sol`). 7 Safe transactions, one per feed.
- The new writer is the keeper EOA — the address derived from
  `KEEPER_PRIVATE_KEY`, i.e. the same EOA that already writes the primary
  feeds. The script reads the keeper EOA address from an env var
  (`KEEPER_ADDRESS`) so no private key is needed in the script.
- The 7 secondary-feed addresses are read from `P3_SECONDARY_*` env vars
  (same names the P3 scripts already use).
- Chain-id guard (`5042002`). Logs each `setWriter` and asserts
  `feed.writer() == keeperEOA` afterward.
- Broadcast is a controller/operator action (live testnet), consistent with
  how P3's governance scripts were run. The script is committed; running it is
  an operational step, not part of the PR's automated test surface.

### 3.2 Keeper dual-push

Modify `ops/keepalive/multi-feed-push.mjs` so each feed is pushed on both its
primary and its secondary feed.

- Each entry in the `FEEDS` array gains a `secondary` address, sourced from a
  new `P3_SECONDARY_*` env var (e.g. `P3_SECONDARY_USDC`).
- For each feed, after computing the (band-checked, deviation-capped) answer,
  the keeper writes `setAnswer` to **both** the primary and the secondary
  address, in the same run. The existing per-push logic (sanity band, deviation
  cap vs the on-chain `prev`, staleness refresh threshold, skip-when-current)
  is applied independently to each of the two feeds — the secondary has its own
  `prev`/`latestUpdatedAt`, so the cap is computed against the secondary's own
  prior answer.
- Both feeds receive the same CoinGecko-derived price. On testnet this is a
  single price source duplicated across two feeds; that is acceptable for the
  rehearsal — genuine source independence (a second real provider such as
  Pyth) is a P5 item. The point of this phase is that both feeds are *fresh*,
  so the aggregator runs in healthy two-source mode rather than degrading to
  the surviving source.
- A missing `secondary` env var for a feed is handled the same way a missing
  primary is: logged and counted as an error for that feed, without aborting
  the others.
- The keeper's per-run log line is extended to report primary and secondary
  push outcomes distinctly.
- The VPS keeper environment file gains the 7 `P3_SECONDARY_*` variables. The
  systemd unit itself does not change.

### 3.3 `guard.record` monitor

A new script `ops/keepalive/guard-record.mjs` plus a systemd service + timer,
mirroring the keeper's structure.

- For each of the 7 tokens, the script reads the token's `OracleAggregator`
  via `latestRoundData()`, takes the `answer` (8-decimal), scales it to
  1e18, and calls `CumulativeDeviationGuard.record(token, price1e18)`.
- The aggregator addresses and the token addresses come from env vars
  (`P3_AGG_*`, the 7 token addresses); the guard address from `P3_GUARD`.
- `record` is permissionless, so the script signs with `KEEPER_PRIVATE_KEY`
  (the keeper EOA — already funded for gas; reusing it avoids provisioning a
  new key).
- The script records the price the pool actually consumes — the aggregator's
  on-chain output — so the guard's `PriceObserved` / `CircuitBreakerTripped`
  events reflect the real oracle the pool reads.
- If an aggregator reverts (`SourcesDiverge` / `AllSourcesUnavailable`), the
  script logs that token as errored and continues with the others — a
  reverting aggregator must not block recording for healthy tokens.
- Runs on a 30-minute systemd timer, offset from the keeper timer so it
  records shortly *after* a keeper push (e.g. keeper at :00/:30, monitor at
  :05/:35). Both units are `Type=oneshot`.
- New files: `ops/keepalive/guard-record.mjs`,
  `ops/keepalive/arcoradex-guard-record.service`,
  `ops/keepalive/arcoradex-guard-record.timer`.

### 3.4 Auto-memory update

Add the 15 P3 contract addresses (the `CumulativeDeviationGuard`, the 7
`OracleAggregator`s, the 7 secondary feeds) and the keeper-as-secondary-writer
fact to the auto-memory entry `arcoradex_role_eoas.md`, so future sessions have
the P3 layout. Update the `MEMORY.md` index line if needed.

### 3.5 Rollout-doc corrections

`docs/rollouts/2026-05-14-phase3-oracle.md`:
- Replace the "rolling signed drift" description of the
  `CumulativeDeviationGuard` with the accurate "tumbling-window absolute
  deviation" (the guard measures `|price − anchor|` against a per-window
  anchor; it is a tumbling window, not rolling, and the deviation is unsigned).
- Add the per-token `maxStaleSeconds` values to the configuration table so the
  table is a complete record of the deployed oracle parameters.

## 4. Out of scope

- **SDK changes** — verified unnecessary: `packages/sdk` reads oracle/aggregator
  addresses live from the Registry (`tokenInfo`); only token addresses are
  hardcoded and those are unchanged by P3.
- **Frontend dependency cleanup** (finding #5, `pnpm audit` on `app/`) — split
  into its own task; it belongs with the P4/P5 audit-gate (G3) work.
- **Genuine second oracle provider** (Pyth or similar) — P5. This phase
  duplicates the single CoinGecko source across both feeds.
- **On-chain auto-pause wired to the guard** — P5; the guard stays event-only.
- **Contract code changes** — none. The P3 contracts are already deployed; this
  phase only adds operational scripts and configuration.

## 5. Sequencing & timing

The P3 Registry-migration batch executes ≈ 2026-05-19 21:35 UTC. Components
3.1 (writer migration) and 3.2 (keeper dual-push) should ideally be live before
then so the aggregators have two reasonably-fresh sources when the Registry
points at them. This is not a hard blocker — if a secondary feed is stale or
diverged at migration time, the aggregator reverts and the Pool's `_readOracle`
try/catch falls back to `lastValidPrice` — but healthy two-source operation is
the goal. Implementation order: 3.1 → 3.2 → 3.3, then 3.4 / 3.5.

## 6. Execution approach

Subagent-driven development, consistent with P1–P4: sonnet implementers and
spec/accuracy reviewers, opus code-quality and final review. The governance
script, the keeper modification, and the new monitor are code (and the keeper
change is behaviour-sensitive — its existing per-push logic must be preserved
and applied symmetrically to the secondary). The live broadcast of 3.1 and the
VPS deployment of 3.2 / 3.3 are controller/operator steps, performed the same
way P3's broadcasts were.
