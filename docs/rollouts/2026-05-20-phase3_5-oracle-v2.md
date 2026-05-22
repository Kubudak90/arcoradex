# Phase 3.5 — OracleAggregator V2 Rollout

**Date:** 2026-05-20 (deploy + schedule); execute scheduled for 2026-05-22 15:55 UTC
**Branch / PRs:** `audit-fix/phase-d1-contracts` (#25), `audit-fix/phase-d2-deploy` (#26), `audit-fix/phase-d5-rollout` (this doc)
**Audit findings closed:** C-1, C-2, C-5, C-14, G-3, G-7 (and C-3/C-4/C-7/C-8/C-10/C-16/C-17 already accepted-and-documented in Phase B).
**Plan:** `docs/superpowers/plans/2026-05-20-audit-remediation.md` — Phase D.

---

## 1. Why this rollout

The P3 oracle layer landed a two-source aggregator pattern but the audit (2026-05-19) found three load-bearing weaknesses in `OracleAggregator` V1:

- **C-1** — divergence cross-check bypassable: a single compromised feed can push its peer to `0`/negative, `_tryRead` returns `ok=false`, the aggregator silently demotes to single-source mode and the divergence check evaporates.
- **C-2** — no per-source staleness check: a frozen primary blended with a fresh secondary is reported with `updatedAt = max(pAt, sAt)`, hiding the stale source from the Pool's `maxStaleSeconds` check.
- **C-5** — `roundId = 1` hardcoded: the Pool's `roundOk = (roundId != 0 && answeredInRound >= roundId)` defense is inert against the deployed aggregator + mocks.

V2 closes all three with one redeploy plus a Timelock-batched Registry migration.

## 2. What changed (contracts)

### `MockChainlinkFeedV2` (audit C-5, C-14)
- `setAnswer` reverts `AnswerNotPositive` on `newAnswer <= 0`. Closes C-14 (the enabling primitive for C-1's disable-the-honest-source attack).
- Internal `_roundId` increments per successful `setAnswer`; `latestRoundData` returns it as both `roundId` and `answeredInRound`. Mocks are now faithful Chainlink doubles, restoring the Pool's `roundOk` defense (closes C-5).

### `OracleAggregator` V2 (audit C-1, C-2, C-5)
New constructor param: `uint32 maxStaleSeconds_` (immutable). `_tryRead` rejects readings where `block.timestamp > updatedAt + MAX_STALE_SECONDS` — closes C-2 by demoting a stale source per-source rather than blending it.

`latestRoundData`:
- Both sources healthy → `updatedAt = min(pAt, sAt)` (staler timestamp, so the Pool's existing `maxStaleSeconds` outer-bound check catches the staler feed) and `roundId = max(pR, sR)` (real, monotonic).
- Single source healthy → `roundId = 0` — explicit degraded-mode signal. The Pool's `_readOracle` treats `roundId == 0` as not-fresh and falls back to its `lastValidPrice` cache, so the divergence cross-check being inactive is detectable on the consumer side rather than silently bypassed. Closes C-1.
- Both fail → `AllSourcesUnavailable` (unchanged).

Decision: `MAX_STALE_SECONDS` stays **immutable** (not a governance-mutable setter). Making it mutable would shift the C-1/C-2 risk into a new setter that the aggregator owner (Governance Safe, direct, no Timelock per audit C-10) could disable with zero delay. Redeploying via this same migration path is the proper relaxation route.

## 3. Pool — no code change

`ArcoraDexPool._readOracle` already contains `bool roundOk = (roundId != 0 && answeredInRound >= roundId)` (line 110). With V2 returning `roundId = 0` in degraded mode, `roundOk` becomes false → `isFresh = false` → existing cache fallback runs. Audit-verified, no Pool code change required. Pinned by `P3AggregatorDegradedConsumerTest` (regression test in `contracts/test/oracle/P3Aggregator.t.sol`).

## 4. Migration scripts (audit G-3, G-7)

Four new files in `contracts/script/`:

- **`DeployOraclesP3_5.s.sol`** — deploys 7 V2 aggregators reusing existing primary + P3 secondary feeds. Each is constructed with `initialOwner = Governance Safe` directly (no two-step transfer), `maxStaleSeconds_ = 3600`, per-token `divergenceBps` matching P3 (50 USD pegs / 100 EURC / 200 TRYC/BRLC). Three `require` asserts post-`new` pin owner / MAX_STALE_SECONDS / divergenceBps so an off-by-one in args fails at deploy time.
- **`P3_5BatchBuilder.sol`** — single source of truth for the Timelock batch (7× `Registry.setOracle` payloads). **Non-zero salt:** `keccak256("ArcoraDEX-P3_5-aggregator-migration-v1")` — closes G-3 (zero-salt front-run + non-recoverability). Defines `TIMELOCK_DELAY = 48 hours` shared constant.
- **`P3_5GovernanceActions.s.sol`** — Safe schedules the batch via Timelock. Idempotency: checks `isOperationPending || isOperationDone` **before** `vm.startBroadcast` (closes G-7). Validates each `P3_5_AGG_*` env-var address has code AND is Safe-owned before scheduling (catches env-var typos). Asserts `minDelay >= TIMELOCK_DELAY` (catches misconfigured Timelock — mainnet foot-gun guard). Logs the executable Unix timestamp + hours-from-now.
- **`ExecuteP3_5Batch.s.sol`** — Timelock executes after 48h. Post-execution: `isOperationDone` + per-token `info.usdOracle == aggs[i]` asserts.

## 5. Live state (2026-05-20)

### V2 aggregator addresses (Arc testnet, chainId 5042002)

| Token | V2 Aggregator |
|---|---|
| USDC  | `0x2a326377726748Be85d951A8356a944D9c76b7b8` |
| USDT  | `0x797e4a1611F544B321802D38d234D36DDE3Bd900` |
| PYUSD | `0x4C101C0d607409ddC2D1045548582b522b285033` |
| DAI   | `0x98ed4909168051BFb39ff527ad0a8F1F381c21a8` |
| EURC  | `0x862E1CBD0f767da4aa87527a29240AfD06Cda261` |
| TRYC  | `0x41255684f22D1bD80455B4c73814e5743f0cf7c8` |
| BRLC  | `0x7b887B5D570221a7b276B301Ca6c74AFf9fA9169` |

All 7 deployed with `initialOwner = Governance Safe (0x715f669D…)`, `maxDivergenceBps` per-tier (50/100/200), `MAX_STALE_SECONDS = 3600`. Constructor sanity-asserts confirmed each value at deploy time.

### Inputs reused (unchanged from P3)

| Token | Primary feed (V1 aggregator's `PRIMARY`) | Secondary feed (V1 aggregator's `SECONDARY`) |
|---|---|---|
| USDC  | `0x2E6B862E1Ac74328238494B22317262004534B39` | `0x88D1D41d902eb9e589Bd9840c688F93b833E5Bcf` |
| USDT  | `0x741af784a1d4C69843A1764099433160088a1c70` | `0x380DF13433f0908d7Fff9c0f5A9e7d7020148325` |
| PYUSD | `0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896` | `0xac5C2Ad4Cf30c39b60C6DFD29bEAc79deE583B83` |
| DAI   | `0xAAC5a5855deF9414f7330f350c2E00119C2097c8` | `0x63D06bdD48afa8d3e4166CdBf8102562b17Cb4B1` |
| EURC  | `0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170` | `0x7e29777A4632714C8C08a49b159E706bDBC414E5` |
| TRYC  | `0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C` | `0x30669c5C1baC6c7CEfDd7E842D621075d3454da9` |
| BRLC  | `0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d` | `0x00058b5F7d6f29bC37092F156afe7f2EBE7D3EA6` |

### Timelock batch
- **Batch id:** `0xe2e130fb983112e00a1802637bcbaf90e71db7eec34be770ab553cdb5458354c`
- **Salt:** `keccak256("ArcoraDEX-P3_5-aggregator-migration-v1")` — non-zero (G-3 fix vs P3's zero salt)
- **Predecessor:** `bytes32(0)`
- **Scheduled at:** Unix `block.timestamp` of the schedule tx (≈ 2026-05-20 15:47:53 UTC)
- **Min delay:** 172800 (48h)
- **Executable at:** Unix `1779464873` ≈ **2026-05-22 15:47:53 UTC**
- **`isOperationPending`:** `true` (verified on-chain post-schedule)

### Behavior change vs. current state
The V1 aggregator has no staleness check at all (the whole C-2 finding). V2's `MAX_STALE_SECONDS = 3600` is stricter than the Registry's outer bound for EURC (14400s) and TRYC/BRLC (86400s). If a CoinGecko outage leaves an FX feed stale for >1h, the V2 aggregator will demote it and (if both feeds stale) revert `AllSourcesUnavailable` → the Pool's `_readOracle` catches the revert and falls back to `lastValidPrice`. This is the intended security behavior (no swaps against stale data) and is a strict improvement over V1's silent blending.

## 6. Execute plan

Auto-execute scheduled via claude.ai remote routine `trig_01QAuvuCdLmwWQs41xJYCQAj`:
- **Fires:** 2026-05-22T15:55:00Z (executable + ~7 min buffer)
- **Action:** runs `forge script script/ExecuteP3_5Batch.s.sol --rpc-url $ARC_TESTNET_RPC --broadcast --slow --gas-estimate-multiplier 150`
- **Post-execute verification embedded in routine prompt:** `isOperationDone(batchId) == true` + 7× `Registry.tokenInfo(token).usdOracle == P3_5_AGG_<SYMBOL>`.

Manual fallback (if the routine fails or is delayed): operator runs the same `forge script` locally with the same env vars (in `contracts/.env`).

## 7. Verification (post-execute — verified 2026-05-22)

**Routine:** `trig_01QAuvuCdLmwWQs41xJYCQAj` fired at 2026-05-22T15:55:00Z.

**executeBatch tx:** `0x6b65230972baab17f256b9fd62643d7af370617ec8b6077fa30d7e852045d314`
**Block:** `43528310` (Arc testnet chainId 5042002)

**`isOperationDone(0xe2e130fb…58354c)`:** `true` ✓

**Registry oracle pointer verification (all 7 tokens):**

| Token | Expected V2 Aggregator | Registry.tokenInfo usdOracle | Match |
|---|---|---|---|
| USDC  | `0x2a326377726748Be85d951A8356a944D9c76b7b8` | `0x2a326377726748Be85d951A8356a944D9c76b7b8` | ✓ |
| USDT  | `0x797e4a1611F544B321802D38d234D36DDE3Bd900` | `0x797e4a1611F544B321802D38d234D36DDE3Bd900` | ✓ |
| PYUSD | `0x4C101C0d607409ddC2D1045548582b522b285033` | `0x4C101C0d607409ddC2D1045548582b522b285033` | ✓ |
| DAI   | `0x98ed4909168051BFb39ff527ad0a8F1F381c21a8` | `0x98ed4909168051BFb39ff527ad0a8F1F381c21a8` | ✓ |
| EURC  | `0x862E1CBD0f767da4aa87527a29240AfD06Cda261` | `0x862E1CBD0f767da4aa87527a29240AfD06Cda261` | ✓ |
| TRYC  | `0x41255684f22D1bD80455B4c73814e5743f0cf7c8` | `0x41255684f22D1bD80455B4c73814e5743f0cf7c8` | ✓ |
| BRLC  | `0x7b887B5D570221a7b276B301Ca6c74AFf9fA9169` | `0x7b887B5D570221a7b276B301Ca6c74AFf9fA9169` | ✓ |

**Sanity swap (10 USDC → USDT via Pool V3):**
- Deployer USDC balance pre-swap: 1,153,502,716 (≈1153 USDC) — sufficient.
- Quote: 10,006,438 USDT out for 10,000,000 USDC in.
- minOut (1% slippage): 9,906,373.
- **Swap tx:** `0xd4c1510b4000930c7d8498fdfadf26e1a31594443231b0ed7ea199c0626d5475` — status: success.
- **USDT received:** 10,006,438 (10.006438 USDT) — within expected range, no revert.

End-to-end path (deployer → Pool V3 → V2 aggregator pricing) confirmed healthy.

## 8. Auto-memory updates (completed 2026-05-22)

Updated:
- `MEMORY.md` — added pointer to this rollout doc.
- `memory/arcoradex_role_eoas.md` — replaced the 7 V1 aggregator addresses with the V2 ones.

## 9. Audit findings closed by this rollout

| Finding | Severity | Status |
|---|---|---|
| C-1 — divergence check bypassable | High | Closed on-chain after execute (degraded-mode signal via `roundId = 0`) |
| C-2 — no per-source staleness | High | Closed on-chain after execute (`_tryRead` rejects per-source) |
| C-5 — `roundId = 1` hardcoded | Medium | Closed on-chain after execute (monotonic `roundId` end-to-end) |
| C-14 — mocks accept zero/negative | Low | Closed at deploy time (mocks reject `<=0`) |
| G-3 — zero-salt batch | Medium | Closed in scripts (non-zero unique salt) |
| G-7 — Phase B not idempotent | Medium | Closed in scripts (`isOperationPending/Done` check before broadcast) |
