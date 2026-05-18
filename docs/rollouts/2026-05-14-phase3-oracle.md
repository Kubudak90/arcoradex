# Phase 3 — Oracle Hardening Rollout (Testnet Rehearsal)

**Date:** 2026-05-17
**Branch:** `phase3/oracle-rollout`

> **Testnet rehearsal only.** All contract addresses listed below are deployments on the Arc testnet (chainId 5042002). None of these addresses exist on or represent mainnet production deployments.
**Spec:** `docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md`
**Plan:** `docs/superpowers/plans/2026-05-14-phase3-oracle-hardening.md`
**Roadmap parent:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §10

## Why this rollout

P2 closed the governance footgun. P3 closes the oracle footgun — audit finding #1 (HIGH): a compromised price-feed writer for TRYC or BRLC could drain the pool in a single swap by posting a manipulated price. The fix has three layers:

1. **Source diversity** — each stable now has a primary `OracleAggregator` (on-chain weighted combination of the existing `MockChainlinkFeedV2` primary and a new independent secondary feed) with a hard divergence cap; a large primary/secondary spread reverts the read.
2. **Tightened pool-side caps** — `Registry.maxOracleDeviationBps` for TRYC and BRLC is cut from the audit-residual 5000 bps to 200 bps, matching the `OracleAggregator` divergence cap and eliminating the drain window.
3. **Deviation guard** — `CumulativeDeviationGuard` measures the absolute deviation `|price − anchor|` against a per-window anchor over a tumbling 24 h window; when the absolute deviation exceeds the per-token cumulative cap the guard records a trip (observable off-chain; auto-pause is deferred to P5).

P3 also resolves two P1/P2 oracle-layer residuals:
- **Reverting-oracle availability gap** — a single oracle revert would propagate up and brick swaps; the Pool's `_readOracle` function (called by `_readUsdPrice1e18WithGuard`) is refactored to `try/catch` so a reverting aggregator returns the last-good price rather than halting.
- **Redundant double-read** — the Pool was calling the Registry oracle twice per swap (once for price, once for staleness); P3 consolidates to a single `latestRoundData` read.

**Scope: testnet rehearsal only. Pyth / independent oracle source for mainnet is deferred to P5.**

## New P3 contract addresses

15 contracts deployed via `DeployOraclesP3.s.sol` on 2026-05-17 (~13.2 M gas).

### OracleAggregators (primary feeds consumed by Registry)

| Token | OracleAggregator Address |
|-------|--------------------------|
| USDC  | `0x6c6519cB0C66c2269505833382f23D4e8f915480` |
| USDT  | `0x3e58dd7fD2729A27961Ffb11d37BFf42874cAa34` |
| PYUSD | `0x78cB5F03b420F0CD2E8adcb141069F31a38E07E8` |
| DAI   | `0x3e542b4d2EdBFC965028eB85140BcFEa6868A37E` |
| EURC  | `0x1357cf421A8c3b732A882e4812AFba6209EBEBbc` |
| TRYC  | `0xFE3FE7F2b2693D676E4831283dd1B81665AC9faA` |
| BRLC  | `0xF5021349E0D6e2ACB00bEb105D7793202ac3Aa46` |

Each `OracleAggregator` implements `IChainlinkAggregator` and is a drop-in replacement for the existing `MockChainlinkFeedV2` from the Registry's perspective — no Pool redeploy required.

### Secondary feeds (independent source inside each OracleAggregator)

| Token | Secondary Feed Address |
|-------|------------------------|
| USDC  | `0x88D1D41d902eb9e589Bd9840c688F93b833E5Bcf` |
| USDT  | `0x380DF13433f0908d7Fff9c0f5A9e7d7020148325` |
| PYUSD | `0xac5C2Ad4Cf30c39b60C6DFD29bEAc79deE583B83` |
| DAI   | `0x63D06bdD48afa8d3e4166CdBf8102562b17Cb4B1` |
| EURC  | `0x7e29777A4632714C8C08a49b159E706bDBC414E5` |
| TRYC  | `0x30669c5C1baC6c7CEfDd7E842D621075d3454da9` |
| BRLC  | `0x00058b5F7d6f29bC37092F156afe7f2EBE7D3EA6` |

### Deviation guard

| Contract | Address |
|----------|---------|
| CumulativeDeviationGuard | `0x035447f8d97A23fFfC32aa8bFb8ffDbC7B94E608` |

## Configuration

Per-token parameters set at deploy time and in the pending Timelock batch:

| Token | Aggregator divergenceBps | Guard maxCumulativeBps | Guard windowSeconds | maxStaleSeconds |
|-------|--------------------------|------------------------|---------------------|-----------------|
| USDC  | 50  | 200 | 86400 | 3600  |
| USDT  | 50  | 200 | 86400 | 3600  |
| PYUSD | 50  | 200 | 86400 | 3600  |
| DAI   | 50  | 200 | 86400 | 3600  |
| EURC  | 100 | 300 | 86400 | 14400 |
| TRYC  | 200 | 500 | 86400 | 86400 |
| BRLC  | 200 | 500 | 86400 | 86400 |

**Note on the three deviation caps — they measure distinct quantities and are not redundant:**

- **`OracleAggregator.maxDivergenceBps`** — gates the _spread between primary and secondary_ source prices at read time. If the two sources diverge beyond this cap, `latestRoundData` reverts, preventing the aggregator from returning an implausible midpoint.
- **`ArcoraDexRegistry.maxOracleDeviationBps`** — gates the _aggregator-output price versus the Pool's most-recently-accepted (cached) price_. A sudden jump in the aggregator's reported price — even if primary and secondary agree — is caught here.
- **`CumulativeDeviationGuard.maxCumulativeBps`** — measures the _absolute deviation `|price − anchor|` from the per-window anchor price over a tumbling 24 h window_ (unsigned; the window resets at each boundary). It is event-only (no on-chain auto-pause in P3); off-chain monitoring consumes `CircuitBreakerTripped` to detect price moves that neither of the two above caps would catch within a single round.

Registry `maxOracleDeviationBps` changes carried by the pending batch:

| Token | Old value (bps) | New value (bps) |
|-------|-----------------|-----------------|
| TRYC  | 5000            | 200             |
| BRLC  | 5000            | 200             |
| All others | unchanged | unchanged  |

## Sequence executed

### Day 0 — 2026-05-17 (complete)

**`DeployOraclesP3.s.sol` broadcast — ONCHAIN EXECUTION COMPLETE & SUCCESSFUL (~13.2 M gas)**

- Deployed 7 `OracleAggregator` contracts (one per stable), each wired to its existing primary `MockChainlinkFeedV2` and a new secondary feed.
- Deployed 7 secondary `MockChainlinkFeedV2` feeds.
- Deployed 1 `CumulativeDeviationGuard` with per-token config above.
- All 15 contracts deployed with deployer EOA as initial owner.

**`P3GovernanceActions.s.sol` broadcast — COMPLETE & SUCCESSFUL**

- Governance Safe (`0x715f669D79Cc72d6685F8724c0B86f7B53d7e624`) accepted ownership of all 15 new contracts (7 aggregators + 7 secondary feeds + 1 guard) from the deployer EOA.
- Governance Safe scheduled the 9-operation Timelock batch through `TimelockController` (`0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83`):

  | # | Target | Call |
  |---|--------|------|
  | 1 | `ArcoraDexRegistry` | `setOracle(USDC, 0x6c6519cB...)` |
  | 2 | `ArcoraDexRegistry` | `setOracle(USDT, 0x3e58dd7f...)` |
  | 3 | `ArcoraDexRegistry` | `setOracle(PYUSD, 0x78cB5F03...)` |
  | 4 | `ArcoraDexRegistry` | `setOracle(DAI, 0x3e542b4d...)` |
  | 5 | `ArcoraDexRegistry` | `setOracle(EURC, 0x1357cf42...)` |
  | 6 | `ArcoraDexRegistry` | `setOracle(TRYC, 0xFE3FE7F2...)` |
  | 7 | `ArcoraDexRegistry` | `setOracle(BRLC, 0xF5021349...)` |
  | 8 | `ArcoraDexRegistry` | `setDeviation(TRYC, 200)` |
  | 9 | `ArcoraDexRegistry` | `setDeviation(BRLC, 200)` |

  **Batch id:** `0x31218725d7f61c128825c982ecd962183136a0b755381d128052a09c84c23587`
  **On-chain state:** `isOperationPending = true`
  **Executable after:** Unix timestamp `1779226327` (≈ 2026-05-20, after the 48 h delay)

### Day 2 — ≈2026-05-20 (pending)

Operator runs `ExecuteP3Batch.s.sol` with the same `P3_AGG_*` env vars after the 48 h delay elapses. This calls `TimelockController.executeBatch(...)`, which:
- Points the Registry at the 7 new `OracleAggregator` contracts.
- Tightens TRYC and BRLC `maxOracleDeviationBps` to 200.

No Pool redeploy is required at this step.

## Contract changes (non-deployed)

The Pool (`0x1ce1ef94e7ebe70727bd69003d61a3f0c9a331bc`) was **not** redeployed as part of P3. Two code-level changes are ready but take effect only on the next Pool redeploy (earliest P4):

- **A1 — try/catch oracle read** — `Pool._readOracle` (called by `_readUsdPrice1e18WithGuard`) wraps the oracle call in a `try/catch`; a reverting aggregator returns the last-good cached price rather than propagating a revert up to the user.
- **A2 — single-read refactor** — the redundant second `latestRoundData` call (staleness check was previously a separate call) is merged into the single price-fetch path.

The 7 new `OracleAggregator` contracts are consumed by the existing Registry via `setOracle` in the pending batch. Because `OracleAggregator` implements `IChainlinkAggregator`, the Registry (and the existing Pool) call it identically to the old feeds — no ABI or Pool change needed.

## Downstream tasks (post-merge)

- [ ] **Keeper: push to both feeds** — the keeper currently writes only to the primary `MockChainlinkFeedV2`. After the batch executes, prices flow through `OracleAggregator`, which reads both the primary and the secondary feed. The secondary feed writer is currently the deployer EOA. The Governance Safe must call `<secondaryFeed>.setWriter(keeperEOA)` for each of the 7 secondary feeds before the keeper can drive them. Without this the secondary feed prices go stale and the aggregator's divergence check may revert.
- [ ] **Off-chain guard monitor** — deploy the `guard.record(token, price)` off-chain monitor (specified for P5). The `CumulativeDeviationGuard` is live on-chain but has no auto-pause; an external process must call `record` each keeper cycle and alert when a trip is detected.
- [ ] **Update auto-memory** — add P3 addresses to `arcoradex_role_eoas.md` (aggregators, secondary feeds, guard, batch id).
- [ ] **Update SDK** — if the SDK caches feed addresses (`FEED_USDC`, `FEED_USDT`, etc.), update them to point at the new `OracleAggregator` addresses once the batch executes and Registry is live on the new feeds.
- [ ] **Announce in ops channel** — note the pending batch execution window and the secondary-feed writer migration.

## Tracking for P5

The following items are out of scope for P3 but must land before mainnet:

- **On-chain auto-pause** — when `CumulativeDeviationGuard` trips, automatically call `pool.pause()` via the Pause Guardian Safe rather than relying on an off-chain alert.
- **`record` access control** — restrict `CumulativeDeviationGuard.record` to a keeper-only role before auto-pause is wired in (currently callable by any address).
- **Pyth / independent secondary source** — replace the testnet `MockChainlinkFeedV2` secondary feeds with Pyth or an on-chain TWAP for genuine source independence on mainnet.
- **Tumbling → rolling window upgrade** — the guard currently uses a tumbling (reset-at-boundary) 24 h window; upgrade to a true rolling window to close the boundary-straddling manipulation vector.

## Rollback

**Standard (≥48 h notice):** Governance Safe schedules a new batch through the Timelock:
- 7 × `Registry.setOracle(token, originalMockFeedAddress)` — reverts each token back to its pre-P3 `MockChainlinkFeedV2`.
- 2 × `Registry.setDeviation(token, 5000)` — restores TRYC/BRLC caps (only if the tightening batch has already executed).

The batch executes after the 48 h delay. Existing pool behavior is unchanged during the delay window.

**Emergency (<48 h):** The Pause Guardian Safe (2/3 of {pg1, pg2, pg3}) can call `pool.pause()` instantly, halting all swaps while a recovery proposal is prepared. No Timelock delay applies.

The deployer EOA holds no ownership over any P3 contract; all P3 contracts are owned by the Governance Safe.

## Phase 3 status

✅ Pool `try/catch` oracle read (A1) — code complete, activates on next Pool redeploy
✅ Single-read refactor (A2) — code complete, activates on next Pool redeploy
✅ `OracleAggregator` deployed × 7 (one per stable)
✅ `CumulativeDeviationGuard` deployed
✅ Secondary feeds deployed × 7
✅ Ownership of all 15 contracts migrated to Governance Safe
✅ 9-operation Timelock batch scheduled (batch id `0x31218725...`)
⏳ Timelock batch executed — pending (executable ≈ 2026-05-20 after 48 h delay)
⏳ TRYC/BRLC `maxOracleDeviationBps` 5000 → 200 — in pending batch
⏳ Secondary-feed writer migrated from deployer EOA to keeper EOA — downstream task

⏭ Next: P4 — Spearbit private review
