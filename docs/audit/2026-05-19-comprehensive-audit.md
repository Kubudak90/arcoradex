# ArcoraDEX — Comprehensive Internal Security Audit

**Date:** 2026-05-19
**Auditor:** Internal review (automated tooling + multi-agent manual review)
**Commit:** `main` @ `3f133cb`
**Scope:** Full repository — contracts, oracle layer, deploy/governance scripts, off-chain keeper/ops, SDK, frontend
**Deliverable:** Findings report only — no code changes were made.

> This is a pre-external-audit internal review intended to feed the Spearbit
> engagement. It does **not** replace a third-party audit. Severities are
> intrinsic (rated as if mainnet); the **Testnet context** note on each finding
> states what currently mitigates it on the live Arc-testnet deployment.

---

## 1. Executive Summary

ArcoraDEX is an oracle-priced multi-stablecoin shared-vault AMM. The on-chain
core is small (1,350 LoC across 5 contracts + interfaces), well-tested, and
clean under static analysis. The review found **no Critical on-chain bug** and
**no fund-loss path reachable by an unprivileged actor on the current testnet
deployment**.

The material results are:

- **Smart contracts** are accounting-sound. All 128 tests pass; 4 invariant
  suites run 128k calls each with 0 reverts; Slither reports 0 findings;
  line/function coverage is 95%/98%. The weaknesses are concentrated in the
  **oracle layer** (Phase 3), where the two-source `OracleAggregator` is
  **over-credited by the audit docs** — its divergence cross-check can be
  bypassed (C-1, C-2) and several documented defenses are inert (C-5).
- **One Critical, mainnet-blocking item:** the governance Safes are derived
  from the public Foundry test mnemonic (G-1). This is accepted on testnet but
  **must not reach mainnet** — it is the single most important gate item.
- The **off-chain keeper** is the real residual risk surface: a single
  unauthenticated price source (K-1), unbounded cumulative price drift via the
  cap-walk (K-2), and Vault-secret handling weaknesses (K-3).
- The **SDK/frontend** has no Critical issue; the notable items are a bypassable
  testnet faucet limiter (F-1) and a `minOut = 0` slippage edge (F-2).

### Findings by severity

| Severity | Count | Notes |
|---|---|---|
| Critical | 1 | G-1 — testnet-accepted, **mainnet-blocking** |
| High | 7 | C-1, C-2, G-2, K-1, K-2, K-3, **F-13 (added in addendum)** |
| Medium | 25 | includes **F-14 (added in addendum)** |
| Low | 17 | |
| Informational / Gas | 7 | |
| **Total** | **57** | |

> See **§9 Addendum (2026-05-20)** — two findings added and three severity
> re-classifications applied after live-state verification by the project team.

### What is in good shape

- NAV accounting: donation-immune (`reserves[]`, never `balanceOf`), first-deposit
  inflation defended by virtual shares, rounding favors the pool. Invariants
  INV-1/2/5/8/10 hold under fuzzing.
- Reentrancy: `nonReentrant` on all mutating entry points, correct CEI ordering,
  `SafeERC20` throughout.
- Access control: `Ownable2Step` everywhere, correct `onlyOwner` /
  `onlyOwnerOrGuardian` split, deliberate pause/unpause asymmetry.
- No secret is logged or bundled into client JS; faucet key is server-side only.
- No XSS / open-redirect / injection vector in the frontend.

---

## 2. Scope & Methodology

**In scope:** `contracts/src/**`, `contracts/script/**`, `ops/keepalive/**`,
`packages/sdk/**`, `app/**`.

**Method:**
1. **Automated** — `forge build`, `forge test`, `forge coverage`, `slither`,
   `pnpm audit`.
2. **Manual** — five parallel specialist reviews (core contracts, oracle layer,
   deploy/governance scripts, keeper/ops, SDK/frontend), each cross-checked
   against the existing `docs/audit/` pack (`threat-model.md`, `invariants.md`,
   `known-acceptable-risks.md`, `architecture.md`) so that documented accepted
   risks (R1–R8) are not re-reported — except where a finding shows an accepted
   risk is **mis-characterized or under-mitigated**.

### Automated results

| Tool | Result |
|---|---|
| `forge build` | OK (1 lint warning — unsafe-typecast in `DeployGovernanceP2.s.sol:106`, benign) |
| `forge test` | **128 / 128 pass**, 0 failed |
| Invariant suites | 4 suites, 256 runs × 128k calls each, **0 reverts** |
| `slither` (core, 101 detectors) | **0 findings** |
| `forge coverage` | Lines 95.4% · Statements 90.4% · Branches 62.8% · Funcs 97.9% |
| `pnpm audit` (`app/`) | **3 moderate** advisories remain (see F-5) |

Coverage is strong on lines/functions. **Branch coverage on `ArcoraDexPool.sol`
is 55%** — the oracle-fallback and revert branches are under-exercised; see C-21
note and the recommendations.

---

## 3. Smart Contract Findings (`contracts/src/`)

### C-1 · [High] Aggregator divergence check is bypassable by disabling the honest source

- **Location:** `oracle/OracleAggregator.sol:61-79` (`latestRoundData`), `100-111` (`_tryRead`)
- **Description:** The two-source divergence guard (`SourcesDiverge`) only runs
  in the `pOk && sOk` branch. `_tryRead` returns `ok = false` for **any** of:
  revert, `answer <= 0`, `updatedAt == 0`, `roundId == 0`,
  `answeredInRound < roundId`. So an attacker who controls one feed does not
  need to move it — they can **disable the feed they do *not* control** by
  pushing it to `0` (mock feeds accept this, see C-14). That demotes the
  aggregator to single-source mode (`:67-68`), returning the
  attacker-controlled feed's price **with no divergence cross-check at all**.
- **Impact:** The primary Phase-3 mitigation for the TRYC/BRLC writer-compromise
  drain (`known-acceptable-risks.md` R6) is weaker than documented. "A single
  compromised keeper can only control one source; the divergence check catches
  a unilateral push" is false against the *disable-the-other-source* variant.
- **Testnet context:** A single keeper EOA writes both primary and secondary
  feeds today (R6), so the cross-check already provides no independence on
  testnet — this finding is about the **mainnet** model where sources are meant
  to be independent.
- **Recommendation:** Treat single-source operation as an explicit *degraded*
  mode the Pool can detect (distinguished `roundId`, or a `requireBothSources`
  flag for high-risk tokens that reverts instead of silently falling back).
  Document the attack in `known-acceptable-risks.md`.

### C-2 · [High] Aggregator performs no staleness check — a frozen feed is blended in as live

- **Location:** `oracle/OracleAggregator.sol:100-111` (`_tryRead` — no `updatedAt` age check), `:78` (`latest = max(pAt, sAt)`)
- **Description:** `_tryRead` validates positivity and round completeness but
  never compares `updatedAt` to `block.timestamp`. A structurally-valid but
  stale answer is `ok = true`. When the primary feed is frozen and the secondary
  is fresh, the aggregator returns `mid = (stalePrimary + freshSecondary)/2` and
  reports `updatedAt = max(pAt, sAt)` — the *fresher* timestamp. The Pool's
  `_readOracle` staleness check (`ArcoraDexPool.sol:114`) therefore sees a fresh
  timestamp and accepts a 50/50 blend of a stale and a live price.
- **Impact:** During a single-feed outage — the most common real oracle failure
  — the pool prices every swap/deposit/withdraw at a stale-blended price while
  believing it is fresh. An actor who anticipates a feed freeze can trade the
  lag.
- **Recommendation:** Add a per-source staleness threshold to the aggregator so
  a stale source is treated as `ok = false`; or return `min(pAt, sAt)` so the
  Pool's existing `maxStaleSeconds` check catches the staler feed.

### C-3 · [Medium] Oracle-priced swaps/withdrawals have zero price impact — LP basis-arbitrage exposure is undocumented

- **Location:** `ArcoraDexPool.sol:470-516` (`swap`), `519-528` (`_grossOut`), `410-467` (`withdraw`)
- **Description:** Swaps are priced purely off oracle ratios with a flat
  `swapFeeBps` (≤ 1%) — no constant-product curve, no utilization penalty. An
  actor observing a real stablecoin de-peg (e.g. USDT trading at 0.97 off-chain
  while the oracle still reads ~1.00) can convert the mispriced token at the
  flat oracle rate with zero slippage, extracting the spread from LPs, bounded
  only by `reserves[tokenOut]`.
- **Impact:** LP value leaks to arbitrageurs on every de-peg / oracle-lag event.
  This is the dominant economic property of an oracle-priced AMM. It is **not**
  in `known-acceptable-risks.md` — the doc frames oracle risk as keeper
  compromise (R6) only, not honest-oracle-vs-market basis.
- **Recommendation:** This is largely *by design*. Either (a) document it as an
  accepted design property with the compensating controls (tight
  `maxOracleDeviationBps`, fast keeper cadence) stated explicitly, or (b) add a
  utilization-scaled dynamic fee / per-block swap-volume cap. At minimum, write
  it into the accepted-risk register so the Spearbit team is not surprised.

### C-4 · [Medium] Single-token withdrawal can drain one reserve to zero

- **Location:** `ArcoraDexPool.sol:410-467` (`withdraw`)
- **Description:** `withdraw(tokenOut, lpAmount, …)` redeems the LP's full
  proportional NAV share but pays it entirely in one chosen token. A large LP
  can debit `reserves[tokenOut]` by the USD value of their whole multi-token
  claim. The only backstop is an `InsufficientLiquidity` revert.
- **Impact:** (a) Economic — a withdrawer exits entirely in whichever token is
  oracle-cheap vs market, leaving remaining LPs the over-valued tokens. (b)
  Availability — zeroing `reserves[tokenOut]` blocks all subsequent swaps *out*
  of that token. Not an accounting break (INV-1 holds), but an economic and DoS
  hazard not covered by R2.
- **Recommendation:** Offer a proportional multi-token withdraw as the default;
  keep single-token withdraw as opt-in with a utilization-scaled fee, or a
  per-token reserve floor.

### C-5 · [Medium] Aggregator hardcodes `roundId = 1` — round-completeness defense is dead code

- **Location:** `oracle/OracleAggregator.sol:67,68,79`; `ArcoraDexPool.sol:110`; mock feeds `MockChainlinkFeedV2.sol`, `MockChainlinkFeed.sol`
- **Description:** The aggregator and both mock feeds return `roundId = 1` /
  `answeredInRound = 1` on every call. The Pool's `roundOk` check
  (`roundId != 0 && answeredInRound >= roundId`) and `_tryRead`'s identical
  check therefore always pass and convey zero information. `invariants.md` INV-7
  and `architecture.md` credit this as a freshness defense — it is inert against
  the deployed feeds. The only surviving liveness signal is `updatedAt`.
- **Impact:** A layer the audit docs credit as defense-in-depth is non-functional.
  The mocks are also not faithful Chainlink doubles (real feeds advance
  `roundId` monotonically), so round-rollover behavior is untested.
- **Recommendation:** Make `MockChainlinkFeedV2.setAnswer` increment a stored
  `roundId`; have the aggregator derive a meaningful `roundId`. Or remove the
  `roundOk` logic and the INV-7 claim so the report does not over-credit it.

### C-6 · [Medium] `OracleAggregator` has no min/max plausibility bounds

- **Location:** `oracle/OracleAggregator.sol:71-77`
- **Description:** The aggregator forwards any positive price as long as the two
  sources agree within `maxDivergenceBps`. There is no absolute sanity floor or
  ceiling. Two colluding/compromised feeds (the testnet single-keeper case, R6)
  set to the same absurd value pass the divergence check (divergence = 0).
- **Impact:** The aggregator adds no absolute sanity band. The absence of
  `minAnswer`/`maxAnswer`-style bounds was the root cause of the historical
  Chainlink LUNA de-peg incident.
- **Recommendation:** Add optional per-aggregator `minAnswer`/`maxAnswer`
  plausibility bounds (e.g. a stablecoin within [0.01, 100] USD).

### C-7 · [Medium] `CumulativeDeviationGuard` trip events can be *suppressed* via per-window re-anchoring

- **Location:** `oracle/CumulativeDeviationGuard.sol:62-92` (`record`), reset branch `:75-80`
- **Description:** `record` is permissionless and the first caller in a fresh
  tumbling window sets `startPrice1e18`. An attacker can front-run the keeper's
  first post-expiry `record` **every window** and re-anchor to the current
  drifted price — keeping the breaker from ever tripping even during a real
  slow-drain. `known-acceptable-risks.md` R3 documents spam and favorable-anchor,
  but **not suppression of a genuine trip**, which is the more dangerous gap:
  the off-chain monitor for slow drains relies on this event stream.
- **Recommendation:** Make `record` keeper-only now (currently deferred to P5),
  or have the off-chain monitor compute deviation itself from raw feed reads and
  treat this contract as redundant breadcrumbs only. Update R3 to add the
  suppression vector.

### C-8 · [Medium] NAV loop writes the price cache for all tokens without ratchet gating

- **Location:** `ArcoraDexPool.sol:331-343` (`_totalReservesUSDMut`), `142-179` (`_readUsdPrice1e18Mut`)
- **Description:** `deposit`/`withdraw` call `_totalReservesUSDMut`, which loops
  every active token through the **state-mutating** `_readUsdPrice1e18Mut` —
  writing `lastValidPrice` for *every* token, not just the operated one. The
  `lastAcceptedPrice` ratchet (`_readAndGuardPrice`) is applied only to the
  operated token. An attacker can therefore walk the *cache* of an un-traded
  token via repeated deposits/withdrawals of an *unrelated* token, never
  triggering the target token's ratchet. The cache-deviation guard still caps
  each step at `maxOracleDeviationBps`, so it is bounded — but the
  `architecture.md` "three deviation knobs" model implies the ratchet gates
  every cache movement, which is inaccurate.
- **Recommendation:** Make NAV iteration use the *view* reader
  (`_readUsdPrice1e18View`) so NAV computation never writes the cache; restrict
  cache writes to the operated token.

### C-9 · [Medium] Quote↔execute divergence on the NAV term

- **Location:** `ArcoraDexPool.sol:559,576` (`quoteDeposit`/`quoteWithdraw` → `totalReservesUSD()`) vs the execution path's `_totalReservesUSDMut`
- **Description:** Quotes compute the NAV denominator via the view reader; the
  execution path uses the mutating reader, which *writes* `lastValidPrice`
  mid-execution and shifts the cache baseline for subsequent NAV tokens. A quote
  computed against the pre-update cache can mismatch the executed `lpOut` /
  `amountOut` even when no revert occurs.
- **Impact:** Breaks the quote↔execute guarantee; integrators sizing slippage
  params off quotes can see unexpected reverts or unfavorable fills. Not a fund
  loss. (`invariants.md` INV-5 already flags this area.)
- **Recommendation:** Make the quote NAV term apply the same guard semantics as
  execution, or document quotes as best-effort for the NAV term. Add a fuzz test
  asserting `quoteDeposit` == executed `lpMinted` across random oracle states.

### C-10 · [Medium] Oracle/guard config is not Timelock-gated — divergence check can be disabled instantly

- **Location:** `oracle/OracleAggregator.sol:90-94` (`setMaxDivergenceBps`); `CumulativeDeviationGuard` `setConfig`
- **Description:** Aggregators and the guard are owned by the Governance Safe
  **directly, with no Timelock** (per `architecture.md`, deliberate for
  emergency rotation). `setMaxDivergenceBps` accepts up to `10_000` (100%),
  which effectively disables the cross-check. A compromised Governance Safe can
  disable the fast oracle protections with **zero delay**, while the Pool-side
  ratchet they complement *is* 48h-delayed — an asymmetry the threat model does
  not call out.
- **Recommendation:** Cap `setMaxDivergenceBps` at a sane ceiling (e.g.
  1000 bps) so even compromised governance cannot fully disable the cross-check;
  or place aggregator/guard ownership behind the Timelock. Document the
  asymmetry in R5.

### C-11 · [Medium] Oracle rotation can mis-scale price — `setOracle` has no decimals guard

- **Location:** `ArcoraDexRegistry.sol:59-67` (`setOracle`); `ArcoraDexPool.sol:121-124`
- **Description:** `setOracle` only checks `newOracle != address(0)`. The Pool
  re-reads `oracleDec` every call and normalizes — so swapping to an aggregator
  whose source decimals differ changes the price *scale* instantly, while
  `lastValidPrice`/`lastAcceptedPrice` remain in the old scale. The mismatch
  either always trips `PriceDeviation` (DoS) or accepts a wildly wrong price.
- **Recommendation:** Have `setOracle` (or the Pool) reject an oracle whose
  `decimals()` differs from the prior one, or force a `syncAcceptedPrice` as
  part of the rotation runbook.

### C-12 · [Low] `deactivateToken` with live reserves strands LP funds

- **Location:** `ArcoraDexRegistry.sol:86-91`; `ArcoraDexPool.sol:331-358`
- **Description:** `deactivateToken` does not require `reserves[token] == 0`.
  NAV computation `continue`s past inactive tokens, so a deactivated token's
  reserves vanish from NAV; LPs cannot withdraw that token (`_readOracle` reverts
  `TokenNotActive`) and every LP's redemption value drops.
- **Recommendation:** Require `pool.reserves(token) == 0` in `deactivateToken`,
  or add a Pool-side sweep path. Document as an operational constraint otherwise.

### C-13 · [Low] Withdraw exit fee is not surfaced in the `Withdrew` event

- **Location:** `ArcoraDexPool.sol:435-445,582-589`
- **Description:** `withdraw` applies `swapFeeBps` to redeemed USD; the portion
  not taken as protocol fee is retained in reserves (a silent exit fee
  redistributed to remaining LPs). The `Withdrew` event emits only
  `protocolFee`, not the LP-retained component.
- **Recommendation:** Emit the LP-retained fee in `Withdrew`, or split a distinct
  `withdrawFeeBps`. Add NatSpec describing the exit-fee semantics.

### C-14 · [Low] Mock feeds accept zero/negative answers

- **Location:** `testnet/MockChainlinkFeedV2.sol:41-46`; `MockChainlinkFeed.sol:25-30`
- **Description:** `setAnswer` does no validation on `newAnswer`. Setting `0` /
  negative is the enabling primitive for C-1. Real Chainlink aggregators clamp
  to `minAnswer`/`maxAnswer`.
- **Recommendation:** `revert` on `newAnswer <= 0` in the mocks so they faithfully
  model a real feed's positivity guarantee.

### C-15 · [Low] Deviation guard skips evaluation of the window-boundary observation

- **Location:** `oracle/CumulativeDeviationGuard.sol:75-80`
- **Description:** On window expiry, `record` resets and `return`s before
  evaluating the resetting observation against the prior window. A price spike
  aligned to a window boundary is invisible — the old window never sees it, the
  new one adopts it as a clean anchor. R4's claim that the tumbling window
  "catches acute intra-window spikes" is not true for boundary-aligned spikes.
- **Recommendation:** On reset, still evaluate the new observation against the
  previous window's anchor before overwriting. Correct the R4 rationale text.

### C-16 · [Informational] `MINIMUM_LIQUIDITY` mischaracterized as an economic floor

- **Location:** `ArcoraDexPool.sol:377-394`; `threat-model.md` §A, `known-acceptable-risks.md` R1
- **Description:** `MINIMUM_LIQUIDITY = 1000` is in 1e18-scaled USD-wei — i.e.
  ~1e-15 USD. It is satisfied by any deposit ≥ 1 token-wei. The real
  first-deposit protection is `VIRTUAL_SHARES`. The docs overstate
  `MINIMUM_LIQUIDITY` as a meaningful sacrifice.
- **Recommendation:** Correct the docs; `MINIMUM_LIQUIDITY` only seeds the supply
  denominator. Consider a fixed USD first-deposit floor if a real one is wanted.

### C-17 · [Informational] `notifyLPTransfer` JIT defense is narrower than documented

- **Location:** `ArcoraDexPool.sol:636-644`; `ArcoraDexLP.sol:36-41`
- **Description:** The min-hold lock attaches to accounts, not LP units. LP
  acquired from a long-aged holder carries an already-expired timestamp and can
  be withdrawn immediately — so the JIT/MEV defense (`threat-model.md` §B)
  covers freshly-*minted* LP only, not LP sourced from an aged holder.
- **Recommendation:** Document the scope. Flag for P5 if ADEX-LP ever becomes
  loanable (flash-loaned LP reopens the JIT vector).

### C-18 · [Informational] `withdrawProtocolFees` is callable while paused

- **Location:** `ArcoraDexPool.sol:606` (no `whenNotPaused`)
- **Description:** Fee withdrawal works during an incident pause. Harmless — it
  touches only `protocolFeesAccrued`, never `reserves[]` — but the pause surface
  is asymmetric and undocumented.
- **Recommendation:** No change required; optionally document as intentional.

### C-19 · [Informational] Legacy `MockChainlinkFeed` (V1) still in `src/`

- **Location:** `testnet/MockChainlinkFeed.sol`
- **Description:** The pre-P3 single-role feed remains compilable in `src/`. No
  in-scope deploy script references it, but its presence increases audit surface
  and risks accidental re-use (it lacks the `writer`/`owner` role split).
- **Recommendation:** Delete it or move it under `test/`.

### C-20 · [Gas] Repeated `REGISTRY.tokenInfo()` / `decimals()` calls in the NAV loop

- **Location:** `ArcoraDexPool.sol:101,121,156,194,244,312`
- **Description:** A single deposit into the 7-token pool makes ~16 external
  registry `STATICCALL`s; `_readUsdPrice1e18Mut` re-fetches the whole
  `TokenInfo` struct just for `maxOracleDeviationBps` after `_readOracle` already
  fetched it.
- **Recommendation:** Have `_readOracle` return the needed `TokenInfo` fields to
  its callers; cache token decimals in the Pool at `listToken` time.

---

## 4. Governance & Deployment Script Findings (`contracts/script/`)

### G-1 · [Critical — testnet-accepted, MAINNET-BLOCKING] Governance Safes derived from the public Foundry test mnemonic

- **Location:** `DeployGovernanceP2.s.sol:18`; `P3GovernanceActions.s.sol:31`; `MigrateSecondaryWriters.s.sol:22-23`
- **Description:** The 3/5 Governance Safe owners and the 2/3 Pause-Guardian
  owners are derived from `"test test test … junk"`, the universally-known
  Foundry default mnemonic. Anyone can derive these keys. The Governance Safe
  owns the Timelock (sole proposer), all 21 feeds/aggregators, and the deviation
  guard; the Pool/Registry are owned by the Timelock. An attacker with these
  keys can schedule + (after 48h) execute any governance action — the Timelock
  provides **zero** protection because the attacker controls the only proposer.
- **Testnet context:** Explicitly accepted — these are throwaway testnet wallets,
  consistent with the project's standing security note. The risk is **carrying
  this construction pattern into a mainnet/production deploy**.
- **Recommendation:** **Mainnet gate.** Replace with per-signer keys from a
  funded keystore / env vars; add a `require(block.chainid == 5042002)` guard on
  the mnemonic path and a loud console warning. This is the #1 item that must be
  resolved before any mainnet deployment.

### G-2 · [High] `DeployGovernanceP2` feed-ownership transfer is non-atomic and non-idempotent

- **Location:** `DeployGovernanceP2.s.sol:166-181` (`_transferFeedOwnership`)
- **Description:** Step 9 does a raw `.call("transferOwnership(address)")` from
  the deployer then a Safe `acceptOwnership()`. This relies on the deployer
  being the current owner of every feed and on every feed being `Ownable2Step`.
  If a feed is plain `Ownable`, `acceptOwnership()` reverts — aborting the
  broadcast *after* steps 6-8 already handed Pool/Registry ownership to the
  Timelock, leaving the system half-migrated with no resume path. The step is
  not re-runnable.
- **Recommendation:** Use the typed `MockChainlinkFeedV2` interface, assert
  `feed.owner() == deployer` before transferring, skip feeds already owned by
  the Safe (mirror the `P3GovernanceActions._accept` pattern), and order feed
  transfers before the irreversible Pool/Registry→Timelock handoff.

### G-3 · [Medium] P3 Timelock batch uses a zero salt — front-run / grief, non-recoverable on collision

- **Location:** `P3BatchBuilder.sol:16-20`; `P3GovernanceActions.s.sol:83-87`; `ExecuteP3Batch.s.sol:25-31`
- **Description:** `hashOperationBatch(…, predecessor=0, salt=0)` makes the
  operation id fully deterministic from public data. Combined with G-1 (public
  proposer keys), anyone can `scheduleBatch` the same parameters first; the
  legitimate run then reverts `OperationAlreadyScheduled` with no way to
  reschedule (zero salt → non-repeatable). An attacker can also schedule it
  earlier, shifting the 48h window.
- **Testnet context:** The P3 batch has already been scheduled/executed on
  testnet; this is a process finding for future batches.
- **Recommendation:** Use a non-zero, deployment-unique salt
  (`keccak256("ArcoraDEX-P3-registry-migration-v1")`) shared via env so both
  scripts agree; this also restores re-runnability after a cancel.

### G-4 · [Medium] P3 Timelock executor role is open to everyone

- **Location:** `ExecuteP3Batch.s.sol:11-13`; `DeployGovernanceP2.s.sol:158-160` (`executors[0] = address(0)`)
- **Description:** The Timelock is constructed with the executor role granted to
  `address(0)` (everyone). With G-3, the full schedule→execute pipeline is
  permissionless — a third party controls *when* a ready batch executes.
- **Recommendation:** Grant the executor role to a known set (Governance Safe
  and/or keeper EOA). If open execution is intended for testnet, document it as
  an accepted risk in the deploy runbook.

### G-5 · [Medium] Four scripts lack a chain-id guard; key env-var name is inconsistent

- **Location:** `DeployArcoraDex.s.sol`, `SmokeArcoraDex.s.sol`, `MigrateFeedsToV2.s.sol`, `TransferTokenOwnershipToFaucet.s.sol` (no `require(block.chainid == …)`)
- **Description:** Most scripts assert `block.chainid == 5042002`; these four do
  not. `MigrateFeedsToV2` and `TransferTokenOwnershipToFaucet` deploy contracts
  / transfer token ownership — a wrong `--rpc-url` broadcasts on the wrong
  network with no abort. The broadcasting-key env var is `PRIVATE_KEY` in two
  scripts and `DEPLOYER_PRIVATE_KEY` everywhere else.
- **Recommendation:** Add the chain-id guard as the first line of `run()` in all
  four; standardize on `DEPLOYER_PRIVATE_KEY`.

### G-6 · [Medium] `MigrateFeedsToV2` is not re-runnable — silent double-migration

- **Location:** `MigrateFeedsToV2.s.sol:34-67` (`_migrateOne`, no skip logic)
- **Description:** Every run unconditionally deploys a new `MockChainlinkFeedV2`
  and re-points the registry. A re-run after a partial failure orphans the first
  set, wastes gas, and copies `latestRoundData()` from the already-migrated feed.
- **Recommendation:** Add a per-token "already migrated" skip guard (mirror
  `MigrateSecondaryWriters`, which correctly skips at `:53`).

### G-7 · [Medium] `P3GovernanceActions` Phase B is not idempotent

- **Location:** `P3GovernanceActions.s.sol:78-95`
- **Description:** The header claims the script is re-runnable; that holds for
  Phase A only. Phase B has no guard — a re-run after Phase B's `scheduleBatch`
  succeeded reverts `OperationAlreadyScheduled`.
- **Recommendation:** Before Phase B, check
  `TIMELOCK.isOperationPending(batchId) || isOperationDone(batchId)` and skip.
  Scope the "re-runnable" header claim accurately.

### G-8 · [Low] `setOracle` does not validate the new aggregator in the P3 batch

- **Location:** `P3BatchBuilder.sol:58-62`; `ArcoraDexRegistry.sol:59-67`
- **Description:** A typo'd-but-valid `P3_AGG_*` address passes the non-zero
  check and is encoded into the batch; detection only happens post-execution.
- **Recommendation:** Sanity-check each aggregator off-chain (`latestRoundData`,
  `decimals`) before scheduling; add a post-`executeBatch` NAV-invariant check.

### G-9 · [Low] Shared addresses duplicated across scripts

- **Location:** `DeployOraclesP3.s.sol:21`, `P3GovernanceActions.s.sol:33-34`, `MigrateSecondaryWriters.s.sol:24`, `P3BatchBuilder.sol:14`, `ExecuteP3Batch.s.sol:16`
- **Description:** Governance Safe / Timelock / Registry addresses are
  copy-pasted into 3+ files. A future address change risks one file targeting a
  stale contract.
- **Recommendation:** Centralize in a single `P3Addresses` constants library.

### G-10 · [Low] `SafeSigHelpers._buildPackedSigs` does not deduplicate signers

- **Location:** `test/governance/SafeSigHelpers.sol:28-49`
- **Description:** The signer-address sort does not check for duplicates; a
  caller passing the same key twice produces a Safe blob that reverts opaquely.
  Not currently triggered.
- **Recommendation:** `require` adjacent sorted signers are strictly increasing.

### G-11 · [Low] Funds sent to mnemonic addresses that already have code

- **Location:** `DeployGovernanceP2.s.sol:111-119`
- **Description:** 0.8 ARC is sent to the 8 public-mnemonic signer addresses; a
  code comment notes they already have contract code on Arc testnet. Tied to G-1.
- **Recommendation:** With real per-signer keys (G-1), fund fresh EOAs; assert
  `addr.code.length == 0` before funding.

---

## 5. Keeper & Ops Findings (`ops/keepalive/`)

### K-1 · [High] Single unauthenticated CoinGecko price source reaches the chain

- **Location:** `multi-feed-push.mjs:85-118` (`fetchAllPrices`), consumed `:185-209`
- **Description:** Every non-USDC feed price comes from one HTTP endpoint with
  no signature, no quorum, no second source. Defenses are the static per-feed
  sanity `band` and the on-chain deviation cap. The FX bands are very wide
  (EURC `[1.00,1.30]`, TRYC `[0.01,0.10]` — a 10× range) so almost any value
  passes. A wrong-but-in-band or MITM'd response mis-prices every swap.
- **Testnet context:** A genuine independent second provider (e.g. Pyth) is
  already tracked as a **P5 item** in `docs/rollouts/2026-05-18-phase3-operationalization.md`.
- **Recommendation:** Add an independent second source and require agreement
  within a tight tolerance before pushing; tighten the FX bands to ±5–10% of the
  live rate.

### K-2 · [High] Deviation cap-walk allows unbounded cumulative drift from the peg

- **Location:** `multi-feed-push.mjs:136-145` (cap logic in `pushFeedAddress`)
- **Description:** The cap bounds only *per-tick* movement
  (`|new-prev| ≤ prev × maxDevBps/10000`), never cumulative drift from a trusted
  anchor. A wrong in-band price sustained over consecutive ticks walks the
  on-chain answer 50 bps (USD) / 150 bps (FX) per tick with no ratchet — ~6% in
  ~6 hours. The cap that protects swap liveness doubles as a slow-manipulation
  amplifier.
- **Recommendation:** Cap against the peg/anchor (band midpoint) in addition to
  `prev`; alert after N consecutive `capped` pushes; consider freezing a feed
  after K consecutive capped ticks pending operator review.

### K-3 · [High] `fetch-keeper-secret.sh` — Vault `secret_id` exposed via argv; no `set +x`; no token revoke

- **Location:** `fetch-keeper-secret.sh:15-39`
- **Description:** (1) `SECRET_ID` (an AppRole bearer credential) is passed as a
  command-line argument to `vault write` — visible in `/proc/<pid>/cmdline` to
  any local user. (2) `set -x` is not explicitly disabled — a debug trace would
  dump `VAULT_TOKEN`, `KEEPER_KEY`, `ROLE_ID`, `SECRET_ID` to the journal. (3)
  The Vault token is never revoked (`vault token revoke -self`) — only the shell
  var is `unset`. (4) No validation that the fetched key is well-formed
  `0x`-prefixed 64-hex.
- **Recommendation:** Pass `secret_id` via stdin / response-wrapping, not argv;
  add explicit `set +x`; `vault token revoke -self` before exit; validate the
  key with `^0x[0-9a-fA-F]{64}$`; minimize the AppRole policy + token TTL.

### K-4 · [Medium] Keeper `package-lock.json` is not committed — supply chain unpinned

- **Location:** `ops/keepalive/package.json:11-13`; `.gitignore` ignores `ops/keepalive/package-lock.json`
- **Description:** `viem` is pinned as `^2.21.0` (caret) and the lockfile is
  gitignored, so a VPS `npm install` resolves whatever the registry serves.
  A compromised viem patch or transitive dep runs inside the keeper process,
  which holds `KEEPER_PRIVATE_KEY`.
- **Recommendation:** Commit `package-lock.json`; deploy with
  `npm ci --ignore-scripts`; pin `viem` to an exact version.

### K-5 · [Medium] Failed/partial keeper run silently bricks swaps — no alerting or backoff

- **Location:** `multi-feed-push.mjs:88-98,189-213`; `arcoradex-feeds.timer`
- **Description:** A CoinGecko 429/gap skips both feeds for that token; the
  on-chain answer ages. The pool reverts swaps past `MAX_STALE_SECONDS` (1h). On
  a 30-min timer, two consecutive failed runs brick swaps for that token.
  `fetchAllPrices` has no retry/backoff on 429; the only failure signal is a
  non-zero exit code + a journal line — no paging.
- **Recommendation:** Add retry-with-backoff on 429/5xx; add an `OnFailure=`
  systemd unit that pages; surface per-feed staleness as a metric/alert before
  the 1h cliff.

### K-6 · [Medium] systemd `EnvironmentFile` / secret-script permissions not enforced in-repo

- **Location:** `arcoradex-feeds.service:15,17`; `arcoradex-guard-record.service:15,17`
- **Description:** `/run/arcora/keeper.env` is well-handled (tmpfs, 0600,
  deleted on stop). But the static `.env` holding `COINGECKO_API_KEY` has no
  enforced mode, and `fetch-keeper-secret.sh` runs as `ExecStartPre` with the
  unit's privileges — if it or its parent dir is writable by another user, the
  Vault key can be exfiltrated. Nothing in the repo verifies these modes.
- **Recommendation:** Document + enforce `chmod 600`/`chown arcora` on `.env`
  and `chmod 700` (non-group-writable) on `fetch-keeper-secret.sh` and its dir.
  Consider moving `COINGECKO_API_KEY` into the Vault fetch.

### K-7 · [Medium] systemd units lack hardening directives and `TimeoutStartSec`

- **Location:** `arcoradex-feeds.service:7-26`, `arcoradex-guard-record.service:7-26`
- **Description:** Good baseline (`User=`, `NoNewPrivileges`, `ProtectSystem=strict`,
  `PrivateTmp`). Missing: `ProtectHome`, `PrivateDevices`, `ProtectKernel*`,
  `RestrictAddressFamilies`, `RestrictNamespaces`, `LockPersonality`,
  `SystemCallFilter=@system-service`, `CapabilityBoundingSet=` (empty), `UMask=0077`,
  and `TimeoutStartSec=` (a hung RPC call can block the oneshot indefinitely).
- **Recommendation:** Add the directives; verify with `systemd-analyze security`.

### K-8 · [Medium] `ARC_TESTNET_RPC` scheme is not validated — cleartext RPC possible

- **Location:** `multi-feed-push.mjs:25,178-179`; `guard-record.mjs:25,59-60`
- **Description:** The default RPC is HTTPS, but `ARC_TESTNET_RPC` can be set to
  plain `http://` with no validation — signed transactions then traverse
  cleartext. `http()` is called with no explicit `timeout`/`retryCount`.
- **Recommendation:** Reject non-`https` `ARC_TESTNET_RPC` at startup; pass
  explicit `http(url, { timeout, retryCount })`.

### K-9 · [Low] `guard-record` records the smoothed/capped price, not ground truth

- **Location:** `guard-record.mjs:69-79`
- **Description:** `guard-record` reads the aggregator output (the keeper's
  already-capped value) and records *that* into `CumulativeDeviationGuard`. The
  guard's event stream only ever sees the smoothed series — a slow manipulation
  the keeper walks in 50 bps/tick may never trip it.
- **Recommendation:** Also record/compare against a raw second source so the
  guard sees the un-smoothed signal.

### K-10 · [Low] `guard-record` hardcodes addresses divergent from the keeper's env config

- **Location:** `guard-record.mjs:29-40` (hardcoded) vs `multi-feed-push.mjs:42-48` (env-driven)
- **Description:** The two keepers use different configuration styles with no
  cross-check; a feed migration would leave `guard-record` recording a stale
  aggregator.
- **Recommendation:** Drive both from one shared config; assert consistency at
  startup.

### K-11 · [Low] `.env.example` omits the `P3_SECONDARY_*` variables

- **Location:** `.env.example:19-25` vs `multi-feed-push.mjs:42-48`
- **Description:** The keeper reads 7 `P3_SECONDARY_*` vars; `.env.example`
  documents only the 7 primary `FEED_*`. An operator copying the example
  produces a `.env` where every secondary feed is skipped and silently goes
  stale.
- **Recommendation:** Add the 7 `P3_SECONDARY_*` entries; make a missing
  secondary address a hard startup failure rather than a per-feed skip.

### K-12 · [Informational] `CumulativeDeviationGuard.record()` is permissionless

- **Location:** `guard-record.mjs:1-9,76-79`
- **Description:** Anyone can call `record(token, arbitraryPrice)` and inject
  `PriceObserved`/`CircuitBreakerTripped` events. (See also C-7.)
- **Recommendation:** Off-chain monitoring must filter events to the known
  keeper EOA; consider an allowlist on `record` (P5).

---

## 6. SDK & Frontend Findings (`packages/sdk/`, `app/`)

### F-1 · [Medium] Faucet rate-limiter is trivially bypassable — gas drain / unbounded mock-token mint

- **Location:** `app/app/api/faucet/route.ts:38-39,65-77`
- **Description:** Rate limiting uses an in-memory `Map` keyed by recipient
  address — per-serverless-instance, reset on cold start, and per-address (a
  free-to-generate value). An attacker supplies a fresh address per request,
  bypassing the 24h cooldown. Each call broadcasts 7 mints signed by
  `FAUCET_PRIVATE_KEY`, draining the faucet's gas and minting unbounded mock
  tokens — which back the live oracle-priced pool.
- **Testnet context:** Testnet faucet, mock tokens; the code comment
  acknowledges the limiter is "fine for testnet."
- **Recommendation:** Use a shared store (Vercel KV / Upstash) keyed by address
  **and** IP; add a global per-hour mint budget; consider a PoW/captcha.

### F-2 · [Medium] SDK builds `minOut = 0` for slippage ≥ 100% — unprotected swap

- **Location:** `packages/sdk/src/slippage/index.ts:3`
- **Description:** `if (slippageBps >= 10_000) return 0n;` — a `minOut`/`minLpOut`
  of `0` means no on-chain slippage protection. The SDK actions pass
  `slippageBps` through with no upper-bound clamp; only the app UI caps custom
  input at 50%. A direct SDK consumer can build a fully unprotected swap.
- **Recommendation:** Throw on `slippageBps` above a sane ceiling (e.g.
  > 5000 bps) instead of silently producing `minOut = 0`.

### F-3 · [Medium] `swap()` recomputes `minOut` from a re-fetched quote, not the confirmed one

- **Location:** `packages/sdk/src/actions/swap.ts:32-37`
- **Description:** `swap()` ignores the quote the UI showed and re-calls
  `quoteSwap` at execution time, deriving `minOut` from that fresh value. The
  oracle can move in between, so the user can sign a swap whose protection floor
  is lower than what `ConfirmSwapModal` displayed.
- **Recommendation:** Pass the confirmed quote (or a caller-supplied
  `minAmountOut`) into `swap()` so the floor matches what the user approved.

### F-4 · [Medium] Infinite (`maxUint256`) token approval is the silent default

- **Location:** `packages/sdk/src/allowance.ts:29`; `swap.ts:29`, `deposit.ts:30`
- **Description:** `ensureAllowance` defaults `exactApproval = false`, approving
  `maxUint256`. The spender is correct (the pool), but unlimited approval is an
  unnecessary blast radius if the pool is ever compromised.
- **Recommendation:** Default to exact-amount approvals; make infinite approval
  opt-in.

### F-5 · [Medium] Three moderate dependency advisories remain after the prior `pnpm audit` cleanup

- **Location:** `app/package.json` dependency tree; root `package.json` `pnpm.overrides`
- **Description:** `pnpm audit` in `app/` still reports **3 moderate**
  advisories — notably `ws < 8.20.1` (GHSA-58qx-3vcg-4xpx, uninitialized memory
  disclosure, reachable at runtime via viem's transport) and `brace-expansion`
  5.0.0–5.0.5 (GHSA-jxxr-4gwj-5jf2, ReDoS). The earlier "all vulns cleared"
  status (finding #5) is incomplete.
- **Recommendation:** Add `pnpm.overrides` for `ws` (`>=8.20.1`) and
  `brace-expansion` (`>=5.0.6`); re-run `pnpm install` + `pnpm audit` to clean.

### F-6 · [Low] Faucet rate-limit timestamp is written after broadcasting — retry/race enables double mint

- **Location:** `app/app/api/faucet/route.ts:84-127` (`lastClaim.set` at `:127`)
- **Description:** The cooldown timestamp is recorded only after the mint loop
  succeeds. A mid-flight throw leaves it unset (immediate retry re-broadcasts
  all 7 mints); two concurrent same-address requests both read an empty
  `lastClaim` (check-then-act race).
- **Recommendation:** Reserve the slot atomically *before* broadcasting.

### F-7 · [Low] No IP throttle or origin check on the faucet

- **Location:** `app/app/api/faucet/route.ts:42`
- **Description:** The route accepts any POST from anywhere — no IP rate limit,
  no `Origin`/`Referer` check.
- **Recommendation:** Throttle per source IP independently of recipient address.

### F-8 · [Low] Faucet leaks raw RPC error strings to the client

- **Location:** `app/app/api/faucet/route.ts:112-114`
- **Description:** Raw viem/RPC error messages are returned and rendered
  verbatim, exposing RPC internals / nonce / gas detail.
- **Recommendation:** Return a generic message; log detail server-side only.

### F-9 · [Low] `ConfirmSwapModal` "minimum received" uses lossy `Number()` math

- **Location:** `app/components/swap/ConfirmSwapModal.tsx:40-42`
- **Description:** The displayed minimum reimplements `minOut` with a
  `bigint → Number` conversion that loses precision above 2^53 and can disagree
  with the on-chain floor.
- **Recommendation:** Render the minimum by calling the SDK `minOut()` and
  `fmtUnits`.

### F-10 · [Low] No chain-id assertion before `writeContract`

- **Location:** `packages/sdk/src/react/ArcoraDexProvider.tsx:18-24`; addresses keyed only to `arcTestnet`
- **Description:** The swap/deposit/withdraw paths do not assert the executing
  wallet is on chain `5042002` (the `FaucetButton` does). A wallet on the wrong
  network could submit against the testnet pool address on that chain.
- **Recommendation:** Assert `walletClient.chain?.id === client.chain.id` before
  `writeContract`; surface a clear "wrong network" error.

### F-11 · [Low] Negative slippage is silently coerced to "no slippage"

- **Location:** `packages/sdk/src/slippage/index.ts:2`
- **Description:** `slippageBps <= 0` returns the exact quote — masking a caller
  bug (e.g. `-50`).
- **Recommendation:** Throw on `slippageBps < 0`.

### F-12 · [Informational] Default deadline is computed from the client clock

- **Location:** `packages/sdk/src/slippage/index.ts:7-9`; `app/components/swap/SwapCard.tsx:97`
- **Description:** `deadline()` uses `Date.now()`; a skewed client clock yields
  an instantly-expired or over-long deadline. The 120-min max is fairly long for
  an MEV window.
- **Recommendation:** Acceptable for testnet; consider deriving the deadline
  from the latest block timestamp and tightening the max.

---

## 7. Recommendations & Mainnet Gate

### Before any mainnet deployment (blocking)

1. **G-1** — Replace the Foundry-test-mnemonic governance with real per-signer
   keys. *Single most important item.*
2. **C-1, C-2** — Fix the `OracleAggregator`: per-source staleness rejection and
   an explicit detectable degraded mode. The aggregator is the load-bearing
   oracle defense and is currently over-credited.
3. **K-1** — Provision a genuinely independent second price source (Pyth or
   similar) with quorum before pushing. Already P5-tracked; promote it to a
   mainnet gate.
4. **K-3** — Harden `fetch-keeper-secret.sh` (no argv secret, `set +x`, token
   revoke, key validation).

### High-value, non-blocking

- **C-3** — Decide and document: accept the zero-price-impact basis exposure, or
  add a utilization-scaled fee. Update `known-acceptable-risks.md` either way.
- **C-5, C-8, C-9, C-10, C-11** — Oracle-layer correctness/consistency fixes.
- **K-2** — Bound cumulative keeper drift to the peg anchor.
- **G-3..G-7** — Deploy-script robustness: non-zero salt, idempotency guards,
  chain-id guards on all scripts.
- **F-2, F-4** — SDK: refuse `minOut = 0`; default to exact-amount approvals.
- **F-5** — Finish the dependency cleanup (`ws`, `brace-expansion`).

### Documentation corrections (the audit pack itself)

The review found the existing `docs/audit/` pack **over-credits** several
defenses. Before handing the pack to Spearbit, correct:

- `invariants.md` INV-7 / `architecture.md` — the round-completeness check is
  inert (C-5).
- `known-acceptable-risks.md` R3 — add the breaker-suppression vector (C-7);
  R5 — add the no-Timelock-on-aggregator asymmetry (C-10); R6 — add the
  disable-the-honest-source variant (C-1).
- `threat-model.md` §A — correct the `MINIMUM_LIQUIDITY` characterization
  (C-16); §B — narrow the JIT-defense claim (C-17).
- `architecture.md` — the "three deviation knobs" model omits the NAV-loop
  cache write (C-8).

### Testing

- Raise `ArcoraDexPool.sol` branch coverage (currently 55%) — the oracle
  fallback / revert branches are under-exercised.
- Add the quote↔execute equivalence fuzz test (C-9).
- Make the mock feeds faithful Chainlink doubles (monotonic `roundId`, positive
  answer — C-5, C-14) so the security tests exercise the real defense paths.

---

## 8. Appendix — Files Reviewed

- **Contracts:** `ArcoraDexPool.sol`, `ArcoraDexRegistry.sol`, `ArcoraDexLP.sol`,
  `oracle/OracleAggregator.sol`, `oracle/CumulativeDeviationGuard.sol`,
  `testnet/Mock*.sol`, `interfaces/*.sol`.
- **Scripts:** all 12 files in `contracts/script/` + `test/governance/SafeSigHelpers.sol`.
- **Ops:** `ops/keepalive/*` (keeper scripts, systemd units, secret script).
- **SDK:** `packages/sdk/src/**`.
- **Frontend:** `app/app/**`, `app/components/**`, `app/lib/**`.

*No files were modified during this audit. This report is advisory; finding
acceptance and remediation are for the team to triage.*

---

## 9. Addendum (2026-05-20) — post-team-review verification

The project team verified the findings against live on-chain state and the
current source tree, confirming the bulk of the report. Two findings missed in
the original review and three severity re-classifications are recorded here.

### 9.1 New findings

#### F-13 · [High] SDK default addresses point at the paused V1 pool — frontend default config is broken

- **Location:** `packages/sdk/src/addresses.ts:9-17`
- **Description:** `DEFAULT_ADDRESSES[arcTestnet.id]` is `ARC_TESTNET_V1` —
  registry `0x920E3E59…`, pool `0x3051d24D…`, lp `0x7CEAbF41…`. These are the
  **V1 deploy** addresses recorded in `docs/rollouts/2026-05-06-arcoradex-deploy.md`,
  superseded by V2 and then V3. The file has only ever had **one commit**
  (`dae32d1`); it was never updated through the V2 or V3 redeploys.
  Live state verified by the team:
  - Live V3 pool (`0x1ce1ef94…`): `paused() == false`, `tokensLength() == 7`,
    USDC→USDT quote succeeds.
  - SDK-default V1 pool (`0x3051d24D…`): `paused() == true`, `quoteSwap` reverts
    with `PriceDeviation`.
- **Impact:** The frontend's `ArcoraDexProvider` and any external SDK consumer
  using the published package's defaults points at a paused, stale pool. Quotes
  revert; swap/deposit/withdraw transactions revert. This is a **deployment
  correctness** issue rather than a security vulnerability, but it effectively
  breaks the live app for any user on default config — which is why this is
  promoted to High. It also retroactively weakens the report's original
  "SDK/frontend — no Critical" framing.
- **Recommendation:** Update `addresses.ts` to the V3 addresses
  (registry `0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB`, pool
  `0x1ce1ef94e7ebe70727bd69003d61a3f0c9a331bc`, lp
  `0x17B47173C457069E53B3B75Ef42773041B79523e`). Refresh the rollout-doc
  reference in the file comment. Cut a new SDK release. Add a CI check (e.g.
  on tag) that calls `paused()` and `tokensLength()` against `DEFAULT_ADDRESSES`
  and fails if the default pool is paused or has zero tokens — this would have
  caught every redeploy gap. Long term, derive SDK defaults from a single
  on-chain registry-of-registries or from `docs/rollouts/*` rather than a
  hand-edited constant.

#### F-14 · [Medium] SDK test suite is broken — `vitest` setup fails at module load

- **Location:** `packages/sdk/test/setup.ts:1` (per the stack trace);
  `packages/sdk/vitest.config.ts`
- **Description:** `pnpm --filter @arcoralabs/dex-sdk test` fails immediately
  with `ReferenceError: __vite_ssr_exportName__ is not defined` at
  `test/setup.ts:1:1`. The error originates in `vite-node@2.1.9`'s SSR loader
  and indicates a version-skew bug between `vitest 2.1.9` and the surrounding
  Vite/Node toolchain (pnpm hoisting picks a `vite-node` resolution that
  produces output the runner cannot execute). `pnpm --filter @arcoralabs/dex-sdk build`
  still passes, so the production artifact is unaffected — but the entire
  JS-side validation path (unit tests for slippage/format/tokens/errors and the
  integration tests against an Anvil fork) is non-runnable. This does **not**
  affect the contract test results in §2 (those are Foundry, 128/128 green).
- **Impact:** No SDK regression has been caught by tests since the breakage
  was introduced. F-2 / F-3 / F-4 / F-9 / F-11 (all SDK-level findings) would
  be straightforward to add regression tests for once the suite runs. CI
  cannot be trusted to gate SDK changes today.
- **Recommendation:** Pin `vite-node` and `vitest` to a known-compatible
  pairing in `packages/sdk/package.json` (or in the root `pnpm.overrides`),
  or upgrade both to a matched recent release. Restore the suite to green and
  add it to CI as a required check. Add regression tests covering the SDK
  findings above (`minOut`-when-slippage≥100% guardrail, exact-amount approval
  default, chain-id assertion).

### 9.2 Severity re-classifications (no factual change)

The following findings are correctly *identified* but were filed in categories
that overstate the security impact. The team's framing is adopted:

- **C-3 (oracle-priced zero-impact swaps) and C-4 (single-token full-pool
  withdrawal):** These are *design properties* of an oracle-priced
  shared-vault AMM, not bugs. They remain in the report at Medium, but the
  recommendation is **acceptance + documentation in
  `known-acceptable-risks.md`**, not remediation. Spearbit should see them as
  declared design trade-offs rather than vulnerabilities.
- **C-16 / C-17 / C-18 (MINIMUM_LIQUIDITY characterization; JIT scope;
  fee-withdrawal-while-paused):** Reclassified as **documentation-accuracy**
  items rather than security findings. They feed into the §7 "Documentation
  corrections" recommendation; they should not be in Spearbit's security
  funnel.
- **F-10 (no chain-id assertion before `writeContract`):** Correctly identified
  at the SDK level. Note for completeness that the **app** does perform a
  wrong-chain switch in `FaucetButton` and via wagmi's connector — the gap is
  specifically in the SDK write path, so the finding remains valid but is
  scoped to direct SDK consumers, not the live frontend's normal flow.

### 9.3 Mainnet-gate items — updated list

§7's blocking list is unchanged in priority. F-13 is **not** a mainnet-gate
item (a V3-correct `addresses.ts` is a one-line release fix), but it **is** a
*release-gate* item — the SDK release shipped against the live testnet is
broken today and must be corrected before any external integrator is pointed
at the package.

*Verified against the source tree and live on-chain state at the time of the
team review. No source files were modified by this audit — F-13 / F-14 require
team action to remediate.*
