# Phase 3 — Oracle Hardening Design Spec

**Date:** 2026-05-14
**Status:** Brainstorming complete — pending user review, then writing-plans
**Authors:** Hüseyin Arslan + Claude
**Roadmap parent:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §5
**Audit context:** Closes audit finding #1 (HIGH, TRYC/BRLC writer-compromise drain) and the remaining P1/P2 carryover residuals (try/catch revert resilience, gas-redundant double oracle read, on-chain rolling deviation tracking).

**Scope:** Testnet rehearsal only — same pattern as P2. Mainnet equivalent (real Chainlink mainnet feeds, Pyth secondary, hardware-wallet governance) deferred to P5.

---

## 1. Context & Motivation

P1 closed the in-contract economic footguns (inflation attack, JIT/MEV, quote↔execute gap, single-stale-feed lock). P2 closed the governance footgun (single-EOA-owner blocker). The pool now operates under a Safe 3/5 + 48 h Timelock + Pause Guardian on Arc testnet at the V3 addresses (see `docs/rollouts/2026-05-14-phase2-governance.md`).

The residual issues that survived P1 and P2 are all in the oracle layer:

1. **Audit finding #1 — TRYC/BRLC writer-compromise drain (HIGH).** The Pool's per-token `maxOracleDeviationBps` for TRYC and BRLC is `5000` (50 %). A compromised keeper EOA can iteratively push the on-chain price ~50 % per tx; two such transactions walk the cache to roughly 2.25× the real-world price, and subsequent withdrawals over-pay against the inflated cache. Tightening the cap mitigates but does not eliminate this attack as long as the only source is a single keeper-driven feed.

2. **P1 final-review Important #1 — reverting oracle vs stale data.** `_readOracle` in `ArcoraDexPool` calls `info.usdOracle.latestRoundData()` directly. If the oracle ever reverts (deactivated AccessControlled Chainlink feed, malicious aggregator, ABI mismatch), the call bubbles up through `totalReservesUSD` and reverts every deposit and withdraw globally — the same availability class as #4 but triggered by revert rather than staleness.

3. **P1 final-review Minor #1 — gas-redundant double oracle read.** `_readUsdPrice1e18WithGuard` (used by `quote*()`) calls `_readOracle` then `_readUsdPrice1e18View`, each of which calls Chainlink's `latestRoundData` + `decimals` — that's 4 external calls per token per quote leg. Off-chain consumers pay double the gas needed.

4. **No on-chain rolling-deviation observability.** The pool emits per-swap events but no contract tracks a 24 h rolling deviation envelope. Off-chain monitoring exists in principle but lacks an on-chain reference price log that an off-chain script can subscribe to deterministically.

P3 closes all four. The scope is split into three groups (A, B, C) executed as a single phase with sub-phase commits:
- **A — Pool fixes:** try/catch in `_readOracle` and gas optimisation of `_readUsdPrice1e18WithGuard`.
- **B — OracleAggregator:** new `IChainlinkAggregator`-compatible wrapper contract that aggregates two feeds with a divergence guard; per-token aggregator deploys; governance migration of Registry oracle pointers.
- **C — CumulativeDeviationGuard:** new lightweight contract that tracks a 24 h tumbling deviation window per token and emits structured events for off-chain monitoring.

Per-token cap recalibration (`Registry.setDeviation`) is a separate governance step bundled at the end of B.

---

## 2. Goals & Non-Goals

### Goals

- Close audit finding #1 by introducing source diversity at the oracle layer (median of two feeds) AND tightening TRYC/BRLC caps to mainnet-realistic levels.
- Make the pool resilient against an oracle that reverts (not only one that goes stale).
- Reduce per-quote gas by eliminating the redundant `_readOracle` call.
- Provide an on-chain reference log of rolling 24 h deviations so off-chain monitoring is deterministic and reproducible.
- Keep the existing P2 governance flow (Timelock 48 h + Pause Guardian) the sole path for sensitive parameter changes.

### Non-Goals

- Real Chainlink mainnet feeds (still using testnet MockChainlinkFeedV2 on both primary and secondary).
- Pyth integration (deferred to P5; mainnet TRY/USD and BRL/USD coverage will be evaluated then).
- DEX TWAP oracle (no liquid DEX exists on Arc testnet for our tokens; would only become an option after mainnet liquidity bootstraps).
- Auto-pause when the circuit breaker trips. The breaker is event-only in P3; on-chain enforcement (Pool auto-pauses on trip) is deferred to P5 once we have operational experience with the false-positive rate.
- Anomaly-detection / ML scoring of oracle deviations.
- Multi-chain oracle reads or cross-chain price discovery.
- Pool storage layout change. P3 deliberately avoids touching Pool storage — only modifier/error-handling adjustments and a single internal helper refactor.

---

## 3. Architecture

### Live ownership today (post-P2)

| Contract | Owner |
|---|---|
| Pool V3 (`0x1ce1ef94...`) | TimelockController (`0x36444f65...`) |
| Registry V3 (`0x9914436e...`) | TimelockController |
| 7 × MockChainlinkFeedV2 (primaries) | Governance Safe (`0x715f669D...`) |

### Architecture after P3

```
                                Registry.tokenInfo(token).usdOracle
                                                |
                                                ▼
                              ┌─────────────────────────────────────┐
                              │      OracleAggregator (per-token)    │
                              │   implements IChainlinkAggregator    │
                              │   owner = Governance Safe            │
                              └───────┬────────────────┬────────────┘
                                      │                │
                       Primary feed   ▼                ▼  Secondary feed
                       MockChainlinkFeedV2     MockChainlinkFeedV2 (NEW)
                       (existing, keeper       (new, keeper writer same EOA
                        EOA writer)            but separate schedule on testnet)

                              ┌─────────────────────────────────────┐
                              │   CumulativeDeviationGuard           │
                              │   - 24 h tumbling window per token   │
                              │   - emits PriceObserved + Trip events│
                              │   - off-chain monitor recovery loop  │
                              │   owner = Governance Safe            │
                              └─────────────────────────────────────┘
```

### Ownership of new contracts

- `OracleAggregator` instances (7 total) → **Governance Safe** (no Timelock; setWriter / setSecondary on a compromised primary needs the same fast-response posture as feed `setWriter` did in P2).
- `CumulativeDeviationGuard` → **Governance Safe** (parameter tuning is slow-pace; could go through Timelock but the contract is operationally low-stakes so direct-Safe is fine).

### Where Pool changes go (intentionally minimal)

- `_readOracle`: wrap `latestRoundData()` in try/catch; on revert, treat as not-fresh and fall through to cache.
- `_readUsdPrice1e18WithGuard`: refactor to a single internal helper to eliminate the duplicate oracle read.

No storage layout changes. No new modifiers. The Pool sees an aggregator only as a Chainlink-shape feed; aggregation happens entirely inside the aggregator contract.

---

## 4. OracleAggregator

### Interface compatibility

Implements `IChainlinkAggregator` so the Pool reads it via the existing `info.usdOracle.latestRoundData()` and `info.usdOracle.decimals()` calls with no contract change.

### State and immutables

```solidity
contract OracleAggregator is IChainlinkAggregator, Ownable2Step {
    IChainlinkAggregator public immutable PRIMARY;
    IChainlinkAggregator public immutable SECONDARY;
    uint8                public immutable DECIMALS_;        // both sources must agree
    uint16               public maxDivergenceBps;           // settable by owner via governance

    error SourcesDiverge(uint256 primary, uint256 secondary, uint16 capBps);
    error AllSourcesUnavailable();
    error DecimalsMismatch(uint8 primaryDec, uint8 secondaryDec);

    event MaxDivergenceUpdated(uint16 oldValue, uint16 newValue);
}
```

Constructor asserts `PRIMARY.decimals() == SECONDARY.decimals()`; mismatch is a configuration bug worth reverting at deploy time.

### Aggregation algorithm

```solidity
function latestRoundData() external view returns (
    uint80 roundId, int256 answer, uint256 startedAt,
    uint256 updatedAt, uint80 answeredInRound
) {
    // 1. Try-read both sources.
    (bool pOk, int256 pAns, uint256 pAt) = _tryRead(PRIMARY);
    (bool sOk, int256 sAns, uint256 sAt) = _tryRead(SECONDARY);

    // 2. Both failed → propagate as "unavailable" so Pool's _readOracle
    //    catch-branch handles it via cache fallback.
    if (!pOk && !sOk) revert AllSourcesUnavailable();

    // 3. One succeeded → use it directly (degraded but operational).
    if (pOk && !sOk) return (1, pAns, pAt, pAt, 1);
    if (sOk && !pOk) return (1, sAns, sAt, sAt, 1);

    // 4. Both fresh → divergence check.
    uint256 absDiff = pAns > sAns ? uint256(pAns - sAns) : uint256(sAns - pAns);
    uint256 minAns  = pAns < sAns ? uint256(pAns) : uint256(sAns);
    if (absDiff * 10_000 > minAns * maxDivergenceBps) {
        revert SourcesDiverge(uint256(pAns), uint256(sAns), maxDivergenceBps);
    }

    // 5. Within cap → return the average (the "median" for two sources).
    int256 mid     = (pAns + sAns) / 2;
    uint256 latest = pAt > sAt ? pAt : sAt;
    return (1, mid, latest, latest, 1);
}
```

`_tryRead` is a private view that uses Yul `staticcall` (or a small try/catch wrapper) so a reverting source returns `(false, 0, 0)` rather than bubbling up.

### Single-source fallback semantics

When one source reverts or returns stale data (`updatedAt` beyond the Pool's `maxStaleSeconds`), the aggregator returns the other source's value with a normal round id. The aggregator does NOT enforce staleness — it leaves that judgement to the Pool's existing `_readOracle` freshness check, which compares `updatedAt` against the per-token `maxStaleSeconds`. The aggregator just reports the freshest available reading.

### Setters

- `setMaxDivergenceBps(uint16 newBps)` — `onlyOwner` (Governance Safe). Validates `1 ≤ newBps ≤ 10_000`. Emits `MaxDivergenceUpdated`.
- No setter for `PRIMARY` / `SECONDARY` — those are immutable. If a source needs to be rotated, governance deploys a new aggregator and `Registry.setOracle` repoints to it (48 h timelock).

### Initial divergence caps

| Symbol | maxDivergenceBps | Rationale |
|---|---|---|
| USDC | 50  | Hard-pegged stable; >0.5 % between two reliable feeds is a red flag |
| USDT | 50  | Same |
| PYUSD | 50 | Same |
| DAI  | 50 | Same |
| EURC | 100 | EUR/USD daily volatility ≈ 0.3 %; 100 bps absorbs short-term noise |
| TRYC | 200 | TRY/USD daily volatility ≈ 1–2 %; 200 bps tolerates intraday spread |
| BRLC | 200 | BRL/USD similar volatility profile |

---

## 5. Pool Changes (Task A)

### A1. Try/catch on `_readOracle`

Current code:
```solidity
(uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
    info.usdOracle.latestRoundData();
// ... validate ...
```

New code:
```solidity
try info.usdOracle.latestRoundData() returns (
    uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
) {
    // existing validation: roundOk, timestampOk, ageOk, answerOk
    isFresh = roundOk && timestampOk && ageOk && answerOk;
    if (isFresh) {
        uint8 oracleDec = info.usdOracle.decimals();
        // scale to 1e18
        ...
    }
} catch {
    isFresh = false;
}
```

`decimals()` call inside the success branch can also revert in theory; wrap it too for full robustness. If the call site that catches a revert needs a specific selector for monitoring, emit `OracleCallReverted(token)` from the catch branch.

### A2. Refactor `_readUsdPrice1e18WithGuard`

Current code (post-P1):
```solidity
function _readUsdPrice1e18WithGuard(address token) internal view returns (uint256, uint8) {
    IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
    uint256 prev = lastAcceptedPrice[token];
    (uint256 rawPrice, uint8 dec, bool isFresh) = _readOracle(token);   // first read
    // ... fresh-branch ratchet check on rawPrice ...
    (uint256 price1e18, uint8 dec2) = _readUsdPrice1e18View(token);     // second read
    // ... stale-branch ratchet check on cached price ...
}
```

Refactored:
```solidity
function _readUsdPrice1e18WithGuard(address token) internal view returns (uint256, uint8) {
    IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
    uint256 prev = lastAcceptedPrice[token];

    // Single oracle read; resolve fresh/cache locally.
    (uint256 rawPrice, uint8 dec, bool isFresh) = _readOracle(token);
    uint256 price1e18 = isFresh ? rawPrice : lastValidPrice[token];
    if (price1e18 == 0) revert NoValidPrice(token);

    // Apply lastAcceptedPrice ratchet check (same as before).
    if (prev != 0) {
        uint256 diff = price1e18 > prev ? price1e18 - prev : prev - price1e18;
        if (diff * BPS > prev * uint256(info.maxOracleDeviationBps)) {
            revert PriceDeviation(token, price1e18, prev, info.maxOracleDeviationBps);
        }
    }
    return (price1e18, dec);
}
```

This drops the second `_readUsdPrice1e18View` call. Net behaviour is identical because `_readUsdPrice1e18View` was effectively replaying the logic of this function with a slightly different cache-deviation interaction; that interaction is preserved here by the explicit `isFresh ? rawPrice : lastValidPrice[token]` branch.

### Test impact

- A1 needs a new test exercising a malicious oracle that reverts on `latestRoundData()`. P1 had a stale-feed test; A1 adds a reverting-feed test.
- A2 has no behavioural change — existing quote tests should pass unchanged. Re-run the `test_quote_*` suite to confirm.

---

## 6. CumulativeDeviationGuard (Task C)

### Storage

```solidity
contract CumulativeDeviationGuard is Ownable2Step {
    struct WindowState {
        uint256 startPrice1e18;
        uint256 startTimestamp;
    }
    struct Config {
        uint32 maxCumulativeBps;  // e.g., 500 = 5 % over the window
        uint32 windowSeconds;     // e.g., 86_400 = 24 h
    }
    mapping(address token => WindowState) public windows;
    mapping(address token => Config)      public configs;

    event PriceObserved(address indexed token, uint256 price1e18, uint256 timestamp);
    event CircuitBreakerTripped(address indexed token, uint256 deviationBps, uint256 timestamp);
    event ConfigUpdated(address indexed token, uint32 maxCumulativeBps, uint32 windowSeconds);
}
```

### Behaviour

`record(address token, uint256 price1e18)` — permissionless, anyone (off-chain monitor, Aggregator post-read, EOA tooling) can call. Steps:

1. If `configs[token].windowSeconds == 0`, the token isn't tracked — return silently (no revert; soft.)
2. Compute window age. If elapsed > `windowSeconds`, reset window: `windows[token] = (price1e18, now)`. Emit `PriceObserved` and return.
3. Compute `|price1e18 - windows[token].startPrice1e18| * 10_000 / windows[token].startPrice1e18` as deviation in bps.
4. Emit `PriceObserved(token, price1e18, now)`.
5. If deviation > `configs[token].maxCumulativeBps`, emit `CircuitBreakerTripped(token, deviation, now)`. Do NOT reset the window — let the off-chain monitor decide. The next call within the same window will re-emit if still tripped.

### Why tumbling window over rolling

A true rolling 24 h window requires storing every observation and walking the history each call — high gas, unbounded storage growth. A tumbling window stores only `(startPrice, startTimestamp)` and resets when elapsed. Less sensitive to gradual drift but catches sharp 24 h moves. Acceptable for testnet rehearsal MVP.

### Initial per-token configs

| Symbol | maxCumulativeBps | windowSeconds | Rationale |
|---|---|---|---|
| USDC | 200 | 86_400 | A 2 % move on USD-pegged stable in 24 h is anomalous |
| USDT | 200 | 86_400 | Same |
| PYUSD | 200 | 86_400 | Same |
| DAI  | 200 | 86_400 | Same |
| EURC | 300 | 86_400 | EUR moves ≤ 2 % daily under normal conditions |
| TRYC | 500 | 86_400 | TRY can move 5 %+ in a single day historically |
| BRLC | 500 | 86_400 | BRL similar |

### Off-chain monitoring integration

A small Node script in `ops/monitoring/` (NOT delivered in P3 — out of scope) subscribes to:
- `PriceObserved` events on the guard
- `CircuitBreakerTripped` events on the guard

When `CircuitBreakerTripped` fires, the script alerts the operator (e.g., Slack webhook) and optionally schedules a `pool.pause()` Safe transaction in the Pause Guardian Safe. The actual signing/relaying is human-in-the-loop for P3.

### Who calls `record`?

For P3 MVP: **off-chain only**. A separate keeper script (similar to the existing `arcoradex-feeds` keeper) runs every block or every minute, reads `aggregator.latestRoundData()`, and calls `guard.record(token, scaledPrice)`. This keeps Pool gas costs unchanged.

Pool-side integration (Pool's `_readUsdPrice1e18Mut` calls `guard.record` after a successful read) is deferred to P5 — adds ~30 k gas per swap, which warrants experimentation before committing.

---

## 7. Per-Token Cap Recalibration (Task D)

Governance proposals scheduled via the Governance Safe through the Timelock (48 h delay each). All seven are batched into a single Safe transaction that calls `timelock.scheduleBatch(...)`.

Proposed new values:

| Symbol | Old `maxOracleDeviationBps` | New | Note |
|---|---|---|---|
| USDC | 50 | 50 | Unchanged |
| USDT | 50 | 50 | Unchanged |
| PYUSD | 50 | 50 | Unchanged |
| DAI | 50 | 50 | Unchanged |
| EURC | 150 | 150 | Unchanged |
| TRYC | 5000 | **200** | Tighten 25× to match real-world volatility |
| BRLC | 5000 | **200** | Tighten 25× |

Rationale for the 200 bps target on exotic FX:
- Daily volatility for TRY/USD and BRL/USD averages 0.5–1.5 % under normal conditions.
- The cap controls the rate at which `lastAcceptedPrice` walks per swap. With 200 bps, an attacker needs ~50 sequential txs to move the cache 100 %, which gives off-chain monitoring time to catch and pause.
- Some intraday spikes (e.g., 2 % market moves) will trigger swap reverts. This is acceptable — the swap reverts safely; legitimate users either wait or use the Pause Guardian's `syncAcceptedPrice` path (P5 may automate sync via a permissionless keeper).

The 200 bps is conservative; if operational data shows legitimate market moves trigger too many reverts, governance can re-tighten or widen.

---

## 8. Testnet Deploy Strategy

### Step ordering

1. **Deploy phase (Day 0):** operator runs `DeployOraclesP3.s.sol`, which:
   - Deploys 7 new `MockChainlinkFeedV2` secondary feeds (one per token; initial answer copied from primary).
   - Deploys 7 `OracleAggregator` instances (each pointing at primary + secondary, with the per-token divergence cap).
   - Deploys 1 `CumulativeDeviationGuard` with all 7 tokens configured.
   - Transfers ownership of all 7 aggregators + the guard to the Governance Safe.
2. **Schedule phase (Day 0):** Governance Safe signs a single batched Safe tx calling `timelock.scheduleBatch(...)` with 9 operations:
   - 7 × `Registry.setOracle(token, aggregator)`
   - 2 × `Registry.setDeviation(TRYC, 200)` and `Registry.setDeviation(BRLC, 200)`
3. **Wait 48 h.** Operator coordinates downstream (SDK update plan; keeper config tweaks).
4. **Execute phase (Day 2):** anyone (open executor role) calls `timelock.executeBatch(...)`. Aggregators become the active oracles; deviation caps tighten.
5. **Verify on-chain:** each `Registry.tokenInfo(token).usdOracle` points at the corresponding aggregator; each `maxOracleDeviationBps` matches the new target; `aggregator.latestRoundData()` returns a sensible price.

### Why batched scheduleBatch over 9 individual schedules

A single proposal is simpler to track, atomic at execute time, and avoids interleaving with other governance work during the 48 h wait. The downside is that one failed sub-call reverts the whole batch — acceptable because the batch is internally consistent.

### Keeper updates (operational, not in this PR)

The existing testnet keeper (`/home/arcora/arcoradex-feeds/multi-feed-push.mjs`) currently pushes to the 7 primary feeds. After P3 it must ALSO push to the 7 secondary feeds. On testnet we can use the same keeper key on a slightly offset schedule (e.g., primary at minute 0, secondary at minute 15) to simulate "two independent sources". For mainnet, the secondary will be a real Pyth subscription (or similar).

A separate small JS script `ops/monitoring/cumulative-deviation-recorder.mjs` (NOT in this PR) reads each aggregator every minute and calls `guard.record(token, price)`. Implementation deferred to P5.

---

## 9. Test Plan

### New test files

`contracts/test/oracle/P3Aggregator.t.sol`:
- `test_aggregator_returns_average_within_divergence_cap` — two sources at $1.00 and $1.01, cap 200 bps; aggregator returns ~$1.005.
- `test_aggregator_reverts_on_sources_diverge` — two sources at $1.00 and $1.05, cap 200 bps; aggregator reverts `SourcesDiverge`.
- `test_aggregator_returns_primary_when_secondary_stale` — secondary `updatedAt` outside Pool's `maxStaleSeconds`; aggregator returns primary alone.
- `test_aggregator_reverts_when_both_stale` — both stale; aggregator reverts `AllSourcesUnavailable`; Pool's catch branch falls back to cache.
- `test_setMaxDivergenceBps_onlyOwner` — governance ownership check.

`contracts/test/oracle/P3CircuitBreaker.t.sol`:
- `test_guard_emits_PriceObserved_on_first_record` — verifies window initialisation.
- `test_guard_emits_Trip_when_deviation_exceeds_cap` — moves price >`maxCumulativeBps` and asserts the event.
- `test_guard_resets_window_after_expiry` — warp past `windowSeconds`; record again; verify new window starts.
- `test_setConfig_onlyOwner` — ownership.

`contracts/test/ArcoraDexPool.t.sol` additions:
- `test_pool_handles_reverting_oracle` — replace token's oracle with a contract whose `latestRoundData` reverts; verify Pool falls back to cache (NoValidPrice if cache empty).
- `test_pool_quote_gas_reduction` — soft assertion (`forge snapshot --check`) that quote gas is ≤ pre-P3 baseline (refactor should reduce, not increase).

Existing test count: 101 (post-P2). P3 adds ~10 new tests → target ≥ 110.

### Coverage targets

- New aggregator file: ≥ 95 % line coverage.
- New guard file: ≥ 90 % line coverage.
- Pool: ≥ 93 % (P1 baseline) maintained; the A2 refactor may shift coverage slightly but must not regress.

### Governance dry-run test

In `P3Aggregator.t.sol`, add a setUp that deploys the full P2 governance stack + new aggregators, then exercises:
- Governance Safe schedules `Registry.setOracle(USDC, aggregator)` → warp 48 h → execute → verify Registry points at aggregator.
- A swap goes through the aggregator path (NAV math unchanged).

---

## 10. Migration Sequence (Operational Runbook)

This is operator-driven; not part of the PR-shippable test plan. Captured here for completeness.

1. **Pre-deploy verify:** operator's local checkout passes `forge test`. P3 branch merged to `main`.
2. **Deploy contracts** via `forge script script/DeployOraclesP3.s.sol --broadcast`:
   - 7 secondary mock feeds
   - 7 aggregators (each transferOwnership → Governance Safe)
   - 1 deviation guard (transferOwnership → Governance Safe)
3. **Governance Safe accepts** ownership for all 8 contracts via `acceptOwnership` (no timelock; direct Safe call).
4. **Governance Safe schedules** the batched migration through Timelock.
5. **Wait 48 h** (operationally: schedule on Friday, execute Monday morning).
6. **Anyone executes** the batched migration. Registry now points at aggregators; deviation caps tightened.
7. **Operator updates keeper** (`/home/arcora/arcoradex-feeds/multi-feed-push.mjs`) to push to both primary and secondary feed sets.
8. **Operator deploys monitoring script** (`ops/monitoring/cumulative-deviation-recorder.mjs`) on the VPS as a systemd timer.
9. **Operator updates auto-memory** (`arcoradex_role_eoas.md`) with new aggregator + guard addresses.
10. **Sanity ping:** perform a small test swap on each pair to verify aggregator path works end-to-end on-chain.

Estimated total time: 4 days (Day 0 deploy + schedule, Day 2 execute, Day 2 keeper update + monitoring deploy, Day 3 sanity ping).

---

## 11. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Aggregator reverts when sources legitimately diverge (e.g., during real volatile market) → swaps lock up | Medium | (a) Conservative divergence caps (50 bps stables, 100 bps EUR, 200 bps exotic). (b) Pool's `_readOracle` try/catch catches the aggregator revert and falls back to cache. (c) Governance can update `maxDivergenceBps` via owner call (no timelock — same posture as feed `setWriter`). |
| Off-chain `guard.record` misses → no trip events | Medium | (a) Recorder script has Prometheus liveness probe. (b) Backup daemon as failover. (c) Default operator alarm if no `PriceObserved` event for >2 × `windowSeconds` (off-chain alarm, P5 spec). |
| Setup-mode trick unavailable for setOracle migration (Timelock is locked at 48 h) | Certain | Use proper 48 h schedule cycle. Operational SLA: 2-day rollout window. |
| Aggregator gas cost (2 oracle reads per `view` call) propagates to Pool quotes | Low | Cost is paid by off-chain consumers via RPC. Mainnet relayers handle this. |
| Wrong divergence cap on aggregator at deploy → frequent reverts | Medium | (a) Caps are mutable post-deploy via `setMaxDivergenceBps`. (b) Initial values are conservative and based on historical market volatility tables. (c) Operator monitors aggregator revert rate for 48 h post-execute. |
| New secondary feed on testnet has no fresh data | Certain at deploy | Aggregator gracefully falls back to primary alone (single-source mode); keeper pushes to secondary right after deploy. |
| OracleAggregator transferOwnership → Governance Safe fails because Safe doesn't recognise the Ownable2Step flow | Low | P2 already validated this pattern for feeds. Same Safe, same pattern. |
| Pool's `_readUsdPrice1e18WithGuard` refactor introduces a regression | Low | (a) Existing quote test suite (post-P1, 101 tests) catches behavioural change. (b) Add `test_pool_quote_gas_reduction` to snapshot the new gas baseline. |

---

## 12. Acceptance Criteria

P3 is complete when:

- Pool's `_readOracle` has a try/catch around `latestRoundData()` and `decimals()`; revert falls back to cache via existing path.
- Pool's `_readUsdPrice1e18WithGuard` performs at most ONE `_readOracle` call (verified by reading the function source).
- `OracleAggregator.sol` exists, exports `IChainlinkAggregator`, with the algorithm in §4.
- `CumulativeDeviationGuard.sol` exists with the algorithm in §6.
- New tests: ≥ 5 in `P3Aggregator.t.sol`, ≥ 4 in `P3CircuitBreaker.t.sol`, ≥ 2 added to `ArcoraDexPool.t.sol`. Total forge test count ≥ 110.
- Coverage thresholds met (aggregator ≥ 95 %, guard ≥ 90 %, Pool ≥ 93 %).
- Slither: no new HIGH/MEDIUM findings.
- `DeployOraclesP3.s.sol` deploys cleanly in dry-run.
- Live testnet broadcast: 7 secondaries + 7 aggregators + 1 guard live; Governance Safe owns all 8.
- Live batched scheduleBatch + executeBatch demonstrated: Registry's `usdOracle` now points at aggregators for all 7 tokens; `maxOracleDeviationBps` is 200 for TRYC/BRLC (down from 5000).
- Rollout doc `docs/rollouts/2026-05-14-phase3-oracle.md` written and committed.
- At least one swap on the new oracle path succeeds on-chain.

---

## 13. Open Questions Deferred to Plan / Implementation

1. **Should the aggregator publish events on every successful read?** — Adds gas but gives off-chain monitoring a deterministic source. Default: no, rely on the dedicated guard contract. Reconsider if monitoring proves unreliable.
2. **`_tryRead` implementation: Yul staticcall vs Solidity try/catch?** — Yul is leaner but harder to audit. Solidity try/catch is canonical but requires the function to be `external` and returns to be tuple-decoded. Default: Solidity try/catch on an external IChainlinkAggregator interface; benchmark gas vs Yul in writing-plans.
3. **Window-reset on first observation vs explicit init call** — Tumbling window resets when elapsed > windowSeconds, but the FIRST observation for a token has no prior window. Default: first `record` initialises both `startPrice` and `startTimestamp`; no separate init call needed.
4. **Governance migration: batch vs sequential scheduleBatch?** — `TimelockController.scheduleBatch` exists in OZ v5 and groups operations atomically. Default: use it for the 9-step migration.
5. **Aggregator decimal handling when primary and secondary have different `decimals()`?** — Constructor reverts on mismatch. If a future secondary source has different decimals (e.g., Pyth uses 8 dp consistently but some feeds use 18), we deploy a wrapper that normalises. Out of scope for P3.
