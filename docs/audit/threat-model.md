# ArcoraDEX — Threat Model & Finding History

**Date:** 2026-05-18
**Branch at authoring:** `phase4/audit-rollout`
**Audience:** Spearbit auditors

---

## 1. Introduction

ArcoraDEX underwent a two-pass security review in May 2026: an external audit pass on 2026-05-12 that surfaced eight findings (spanning smart-contract economics, governance, oracle dependence, dependency hygiene, and operational configuration), followed immediately by a second-opinion internal pass that added three further economic-attack vectors the original review had not raised. The combined eleven findings drove a three-phase remediation programme (P1 — contract fixes, P2 — governance migration, P3 — oracle hardening) executed before the code was submitted to Spearbit. This document maps every finding to its fix, names the contract and function where the fix lives, and states the residual risk that persists after remediation.

**Note on finding counts across source documents.** The mainnet-readiness roadmap (`docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md`) is the authoritative reconciliation point: §1 states "8 findings total + 3 additional Claude-surfaced economic-attack vectors", §6 references "all 11 findings". The original audit-cleanup design (`docs/superpowers/specs/2026-05-12-audit-cleanup-design.md`) records only the three operational footguns it addressed (P2 #1, P2 #2, P3) and does not enumerate the full set — it pre-dates the 2026-05-13 external review. The P4 design spec (`docs/superpowers/specs/2026-05-18-phase4-audit-readiness-design.md`) explicitly asks this document to reconcile the count against the source docs rather than assert a number. The count this document uses is **11**, derived from the tables in the roadmap §3–§6 plus the ops-level items in the audit-cleanup design.

---

## 2. Findings Table

| ID | Title | Severity | Status | Phase | Fix location |
|----|-------|----------|--------|-------|--------------|
| **#A** | First-depositor inflation attack | CRITICAL | Fixed | P1 | `ArcoraDexPool.sol` — virtual-shares math in `deposit()`, `withdraw()`, `quoteDeposit()`, `quoteWithdraw()` |
| **#B** | JIT/MEV sandwich on deposit/withdraw | HIGH | Fixed | P1 | `ArcoraDexPool.sol` — `lastMintAt` mapping + `EarlyWithdraw` revert in `withdraw()` |
| **#1** | TRYC/BRLC iterative writer-compromise drain | HIGH | Mitigated | P3 | `OracleAggregator.sol` (two-source median + `SourcesDiverge` revert) + `ArcoraDexRegistry.sol` `setDeviation()` (caps reduced from 5 000 bps to 200 bps) |
| **#3** | Deployer EOA — single point of failure for all owner actions | HIGH | Fixed | P2 | `ArcoraDexPool.sol` — `pauseGuardian` + `onlyOwnerOrGuardian` modifier + `setPauseGuardian()`; governance: `TimelockController` (48 h) + Governance Safe 3/5 |
| **#C** | Quote↔execute deviation gap | MEDIUM | Fixed | P1 | `ArcoraDexPool.sol` — `_readUsdPrice1e18WithGuard()` applied to `quote()`, `quoteDeposit()`, `quoteWithdraw()` |
| **#4** | Stale feed locks deposit/withdraw globally | MEDIUM | Fixed | P1 | `ArcoraDexRegistry.sol` — per-token `maxStaleSeconds` field; `ArcoraDexPool.sol` — `lastValidPrice`/`lastValidPriceAt` cache + fallback path in `_readOracle()` |
| **#P3-R** | Reverting oracle call bricks pool globally | MEDIUM | Fixed | P3 | `ArcoraDexPool.sol` — try/catch wrapping `info.usdOracle.latestRoundData()` and `info.usdOracle.decimals()` inside `_readOracle()` |
| **#P3-G** | Gas-redundant double oracle read in quote path | LOW | Fixed | P3 | `ArcoraDexPool.sol` — `_readUsdPrice1e18WithGuard()` refactored to single `_readOracle()` call |
| **#P3-O** | No on-chain rolling-deviation observability | LOW | Mitigated | P3 | `CumulativeDeviationGuard.sol` — `record()` + `PriceObserved` / `CircuitBreakerTripped` events; tumbling 24 h window per token |
| **#5** | Frontend dependency vulnerabilities (35 vulns incl. 1 critical, 13 high) | MEDIUM | Accepted / Deferred | P4/P5 | Not in contract audit scope; tracked in `docs/audit/p5-tracking.md` |
| **#OPS** | Operational footguns: `DEPLOYER_PRIVATE_KEY` rename, legacy v07 keeper unit, `KEEPER_EOA` zero-address guard | LOW | Fixed | Pre-P1 | `ops/keepalive/multi-feed-push.mjs`, `ops/keepalive/fetch-keeper-secret.sh`, `contracts/script/MigrateFeedsToV2.s.sol` |

---

## 3. Per-Finding Detail

### #A — First-depositor inflation attack (CRITICAL → Fixed, P1)

**Attack.** `MINIMUM_LIQUIDITY` was 1 000 USD-wei — effectively zero. An attacker could make the smallest possible first deposit to receive one LP unit, then directly transfer a large token balance to the pool contract (inflating NAV without minting LP). Any subsequent depositor's LP amount would round to zero, permanently locking their tokens in the pool. This is the Uniswap V2 inflation-attack class and would be first-day exploitable on any mainnet deploy.

**Fix.** The ERC4626 virtual-offset pattern was applied in `ArcoraDexPool.sol`. Constants `VIRTUAL_SHARES = 1e6` and `VIRTUAL_ASSETS = 1` are added at lines 37–38. The LP mint formula in `deposit()` (line 390) is `lpMinted = (usdIn * (supply + VIRTUAL_SHARES)) / (navBefore + VIRTUAL_ASSETS)` and the symmetric formula is applied in `withdraw()` (line 427). The same virtual-offset is applied in `quoteDeposit()` and `quoteWithdraw()`. Additionally, `MINIMUM_LIQUIDITY = 1000` is still burned to `DEAD_ADDRESS` (line 400) on the first deposit as defense-in-depth: the attacker must sacrifice at least 1 000 USD-wei LP to initiate the attack, which combined with virtual shares makes the attack economically self-defeating.

**Verify.** Read `ArcoraDexPool.sol` lines 37–38 (constants), 384–390 (first-deposit branch and general formula), 427 (withdraw formula). Run `forge test --match-test test_inflation_attack_fails_after_fix`.

---

### #B — JIT/MEV sandwich on deposit/withdraw (HIGH → Fixed, P1)

**Attack.** Atomic deposit-then-withdraw across an oracle update lets an MEV bot capture the NAV delta with no capital at risk. `totalReservesUSD()` always reads the current oracle; a bot could deposit just before the keeper's `setAnswer` oracle push and withdraw immediately after, extracting the price-delta gain.

**Fix.** A `lastMintAt` mapping (line 59 of `ArcoraDexPool.sol`) records `block.timestamp` for every depositor at the end of `deposit()`. `withdraw()` enforces `block.timestamp >= lastMintAt[msg.sender] + MIN_HOLD_SECONDS` (line 422), where `MIN_HOLD_SECONDS = 1 hours` (line 43). The 1-hour hold covers at least two keeper cycles (keeper fires every 30 minutes), making atomic same-MEV-bundle extract impossible. A violation reverts with `EarlyWithdraw(unlockAt, block.timestamp)`. LP token transfer to a fresh address resets `lastMintAt` to zero, allowing immediate withdrawal by the recipient — this is documented as intentional (the JIT pattern requires the same account to deposit and extract).

**Verify.** `ArcoraDexPool.sol` lines 43–44 (constants), 59 (mapping), 418–422 (withdraw guard). Run `forge test --match-test test_jit_mev_blocked_by_min_hold`.

---

### #1 — TRYC/BRLC iterative writer-compromise drain (HIGH → Mitigated, P3)

**Attack.** `maxOracleDeviationBps` for TRYC and BRLC was 5 000 bps (50%). A compromised keeper EOA could iteratively push the oracle price ~50% per transaction; two such transactions walk the `lastAcceptedPrice` cache to ~2.25× real-world price. Subsequent withdrawals would over-pay the attacker. The attack required only a compromised keeper key plus patience.

**Fix — two-part.**
1. `OracleAggregator.sol` (deployed per-token by P3) wraps a primary and a secondary `MockChainlinkFeedV2` feed. `latestRoundData()` (line 61 of `OracleAggregator.sol`) tries both sources, returns their average when they agree within `maxDivergenceBps`, and reverts `SourcesDiverge` when they diverge. A single compromised keeper can only control one source; the divergence check catches a unilateral price push. Initial `maxDivergenceBps` for TRYC and BRLC is 200 bps.
2. `ArcoraDexRegistry.sol` `setDeviation()` (line 68) was called via governance to reduce `maxOracleDeviationBps` for TRYC and BRLC from 5 000 bps to 200 bps. An attacker now needs ~50 sequential transactions, each passing the aggregator's divergence check, to walk the cache 100%—providing significant off-chain monitoring lead time.

**Residual risk.** Two colluding keepers (one per source) could still execute the walk at 200 bps/tx. This is a genuine residual; see §4.

**Verify.** `OracleAggregator.sol` lines 61–80 (aggregation algorithm). `ArcoraDexRegistry.sol` line 68 (`setDeviation`). Run `forge test --match-test test_aggregator_reverts_on_sources_diverge`.

---

### #3 — Deployer EOA single point of failure (HIGH → Fixed, P2)

**Attack.** Before P2, all owner-only functions on `ArcoraDexPool`, `ArcoraDexRegistry`, and the seven mock feeds were controlled by a single deployer EOA. A compromise of that key would allow an attacker to rotate oracle addresses to attacker-controlled feeds, set deviation caps to bypass economic protections, sync `lastAcceptedPrice` to any value, withdraw protocol fees, and drain the pool over multiple transactions with no on-chain delay.

**Fix.** Ownership transferred to a Safe 3/5 Governance multisig fronted by an OpenZeppelin `TimelockController` (48 h minimum delay). `ArcoraDexPool.sol` was extended with:
- `address public pauseGuardian` (line 63)
- `modifier onlyOwnerOrGuardian()` (line 83), used only by `pause()`
- `function setPauseGuardian(address newGuardian) external onlyOwner` (line 646)
- `pause()` (line 616) is `onlyOwnerOrGuardian`; `unpause()` (line 626) is `onlyOwner` only (P4/A1 asymmetry fix — see below)

A separate Pause Guardian Safe 2/3 holds only the guardian role: it can pause instantly but cannot unpause (a P4 hardening that prevents a compromised 2/3 guardian from restarting a deliberately paused pool).

The seven `MockChainlinkFeedV2` feeds are owned directly by the Governance Safe (no Timelock), so emergency feed-writer rotation does not require a 48 h delay.

**Verify.** `ArcoraDexPool.sol` lines 63, 83–85, 616, 626, 646–649. Deployment scripts: `contracts/script/DeployGovernanceP2.s.sol`.

---

### #C — Quote↔execute deviation gap (MEDIUM → Fixed, P1)

**Attack.** `quote()` used `_readUsdPrice1e18` (no ratchet check) while `swap()` used `_readAndGuardPrice` (ratchet check). Users and integrators called `quote()` as a preflight, received a valid price, then submitted `swap()` which reverted with `PriceDeviation` — a broken UX and a broken promise to SDK consumers.

**Fix.** `_readUsdPrice1e18WithGuard()` (line 243 of `ArcoraDexPool.sol`) is a view-only function that runs the same deviation-ratchet logic as the stateful path but without writing to `lastAcceptedPrice`. It is applied to all three quote entry-points: `quote()` (line 538), `quoteDeposit()` (line 546), `quoteWithdraw()` (line 573). A quote now reverts with `PriceDeviation` under exactly the same conditions that would cause the corresponding execute to revert.

**Verify.** `ArcoraDexPool.sol` lines 243–310 (`_readUsdPrice1e18WithGuard`), 530–580 (quote functions). Run `forge test --match-test test_quote_reverts_when_swap_would_revert`.

---

### #4 — Stale feed locks deposit/withdraw globally (MEDIUM → Fixed, P1)

**Attack.** A single stale active feed caused `totalReservesUSD()` to revert, blocking every deposit and withdrawal globally. Additionally, the global `MAX_STALE_SECONDS = 3 600` constant meant an exotic-FX feed with a 24 h heartbeat (e.g., TRYC, BRLC) would lock the pool once per day under normal operating conditions.

**Fix — two-part.**
1. `ArcoraDexRegistry.sol`: `TokenInfo` struct extended with `uint32 maxStaleSeconds` field (line 38). `listToken()` validates `60 ≤ maxStaleSeconds ≤ 7 days`. `setMaxStaleSeconds()` (line 77) allows governance to retune post-deploy. Default values: USDC/USDT/PYUSD/DAI = 3 600 s; EURC = 14 400 s; TRYC/BRLC = 86 400 s.
2. `ArcoraDexPool.sol`: `lastValidPrice[token]` and `lastValidPriceAt[token]` mappings (lines 57–58) cache the last known good price per token. `_readOracle()` (line 98) writes the cache on every fresh oracle read, and falls back to it when the oracle is stale, returning `isFresh = false` rather than reverting. A `NoValidPrice(token)` revert only occurs if the cache has never been seeded (first-read scenario for a never-traded token).

**Verify.** `ArcoraDexRegistry.sol` lines 38, 45, 77–83. `ArcoraDexPool.sol` lines 57–58, 98–140. Run `forge test --match-test test_stale_feed_falls_back_to_cache` and `test_no_valid_price_reverts_when_never_seeded`.

---

### #P3-R — Reverting oracle call bricks pool globally (MEDIUM → Fixed, P3)

**Attack.** `_readOracle()` in `ArcoraDexPool` originally called `info.usdOracle.latestRoundData()` directly. If the oracle contract reverted for any reason — a deactivated Chainlink AccessControlled aggregator, ABI mismatch, or a malicious aggregator — the revert would propagate through `totalReservesUSD()` and block all deposits and withdrawals. This is the same availability class as #4 but triggered by revert rather than staleness.

**Fix.** `_readOracle()` in `ArcoraDexPool.sol` (lines 107–131) wraps both `info.usdOracle.latestRoundData()` and `info.usdOracle.decimals()` in `try`/`catch` blocks. A revert from either call sets `isFresh = false`, and the function falls through to the `lastValidPrice` cache (introduced in P1 for #4). If the cache is empty, the existing `NoValidPrice(token)` revert fires — same as the stale-no-cache path.

**Verify.** `ArcoraDexPool.sol` lines 107–131. Run `forge test --match-test test_pool_handles_reverting_oracle`.

---

### #P3-G — Gas-redundant double oracle read in quote path (LOW → Fixed, P3)

**Attack.** `_readUsdPrice1e18WithGuard()` as originally written after P1 called `_readOracle()` once for the fresh-branch, then called `_readUsdPrice1e18View()` again for the cache-branch, resulting in up to four external Chainlink calls per token per quote leg.

**Fix.** `_readUsdPrice1e18WithGuard()` (line 243 of `ArcoraDexPool.sol`) was refactored to a single `_readOracle()` call that resolves both fresh and cached branches internally. The quote gas cost was reduced accordingly without behavioural change.

**Verify.** `ArcoraDexPool.sol` lines 243–310: exactly one `_readOracle(token)` call at line 250. Run `forge test --match-test test_pool_quote_gas_reduction` (snapshot assertion).

---

### #P3-O — No on-chain rolling-deviation observability (LOW → Mitigated, P3)

**Attack.** Without an on-chain record of historical prices, an off-chain monitoring script had no deterministic reference for a 24 h rolling deviation. A slow keeper-compromise drain (many small oracle pushes, each within the per-tx cap) would be invisible to a monitor that only watched individual oracle updates.

**Fix.** `CumulativeDeviationGuard.sol` (deployed by P3) implements a permissionless `record(address token, uint256 price1e18)` function (line 62). Anyone — off-chain keeper, monitoring script, or EOA — calls `record` after an oracle update. The contract tracks a per-token tumbling 24 h window with `(startPrice1e18, startTimestamp)` storage and emits `PriceObserved(token, price1e18, timestamp)` on every call and `CircuitBreakerTripped(token, deviationBps, timestamp)` when the window deviation exceeds `maxCumulativeBps`. Initial caps: 200 bps for stables, 300 bps for EURC, 500 bps for TRYC/BRLC (24 h window).

**Residual.** `record` is permissionless: anyone can call it, including with a fabricated price. This is a design decision; see §4.

**Verify.** `CumulativeDeviationGuard.sol` lines 62–85. Run `forge test --match-test test_guard_emits_Trip_when_deviation_exceeds_cap`.

---

### #5 — Frontend dependency vulnerabilities (MEDIUM → Accepted/Deferred, P4/P5)

**Finding.** `pnpm audit` on the frontend repository reported 35 vulnerabilities including 1 critical and 13 high in Next.js, axios, and happy-dom chains.

**Status.** This is a frontend/SDK repository issue, not a smart-contract audit target. It is documented in `docs/audit/p5-tracking.md` and must be resolved before the G3 gate (Spearbit sign-off → mainnet). It is not in scope for this contract review.

---

### #OPS — Operational footguns (LOW → Fixed, pre-P1)

**Findings** (from `docs/superpowers/specs/2026-05-12-audit-cleanup-design.md`):

1. **`DEPLOYER_PRIVATE_KEY` / `KEEPER_PRIVATE_KEY` confusion** — the keeper's `.env` used the same key name as the deployer EOA, creating an environment-variable override trap if any operator accidentally re-populated the variable. Fixed by renaming to `KEEPER_PRIVATE_KEY` in `ops/keepalive/fetch-keeper-secret.sh` and `ops/keepalive/multi-feed-push.mjs`.

2. **Legacy v07 keeper unit** — `ops/keepalive/arcora-v07-feeds.service` shared the same `RuntimeDirectory=arcora` as the live ArcoraDEX keeper, creating a latent race if both were ever re-enabled. Fixed by deleting the legacy unit file from the repository (the VPS was already free of the unit at audit time).

3. **`KEEPER_EOA` zero-address guard** — `contracts/script/MigrateFeedsToV2.s.sol` accepted `KEEPER_EOA = address(0)` silently; all seven feeds would deploy with `writer = 0x0`, causing `setAnswer` to revert `NotWriter` forever. Fixed by adding `require(keeperEOA != address(0), "zero keeper EOA")` after the `vm.envAddress` read.

---

## 4. Residual Risks

### R1 — Governance multisig compromise

**Risk.** A 3/5 Governance Safe could be compromised by an attacker who controls three of five signing keys. That attacker could propose any owner action — rotating oracles to attacker-controlled feeds, withdrawing protocol fees, changing deviation caps.

**Why it persists.** The 3/5 threshold is a deliberate tradeoff between liveness and security. Requiring 4/5 or 5/5 signatures would make coordinated governance impractical for frequent low-stakes actions.

**Compensating controls.**
- All owner actions on Pool and Registry require 48 h delay via `TimelockController.getMinDelay()`. A pending malicious proposal is publicly visible on-chain for 48 h; any watcher can alert the community, and the remaining keyholders can cancel it via `TimelockController.cancel()` (proposer role, which the Governance Safe holds).
- Emergency pause via the Pause Guardian Safe (2/3 threshold, separate key set) can freeze the pool immediately, limiting the damage window to whatever the attacker could execute in those 48 h before the proposal executes. Crucially, `unpause()` is `onlyOwner` (P4/A1 fix, `ArcoraDexPool.sol` line 626), so a compromised 2/3 Pause Guardian cannot restart a deliberately paused pool.
- Feed `setWriter` calls are via the Governance Safe directly (no Timelock), so a compromised governance Safe could rotate keeper keys instantly. This is the accepted fast-response posture for emergency feed-writer rotation.

---

### R2 — Oracle keeper compromise

**Risk.** A compromised keeper EOA can push malicious prices to the primary feed for any token. Before P3 this was a direct drain vector (#1); P3 introduced a secondary feed and divergence cap to narrow but not eliminate the attack.

**Why it persists.** The testnet configuration uses the same keeper key to push both primary and secondary feeds (on a slightly offset schedule). If an attacker compromises the single keeper EOA, they control both sources and can bypass the aggregator's divergence check. On mainnet the intent is for primary and secondary to be independent sources (Chainlink for primary, Pyth or DEX TWAP for secondary with a different key), but this is deferred to P5.

**Compensating controls.**
- `OracleAggregator.sol` `SourcesDiverge` revert caps single-transaction deviation at `maxDivergenceBps` (200 bps for TRYC/BRLC). Even with one source compromised, the aggregator falls back to the honest source.
- `ArcoraDexRegistry.sol` per-token `maxOracleDeviationBps` (200 bps for TRYC/BRLC, set via `setDeviation()`) limits how far `lastAcceptedPrice` can walk per swap. An attacker still needs many transactions to drain the pool, giving monitoring time to respond.
- `CumulativeDeviationGuard.sol` emits `CircuitBreakerTripped` events that off-chain monitoring can subscribe to and respond by submitting a Pause Guardian Safe transaction. This is human-in-the-loop for P3; on-chain auto-pause is deferred to P5.
- The `EarlyWithdraw` hold (`MIN_HOLD_SECONDS = 1 hours`, `ArcoraDexPool.sol` line 43) means a keeper-compromised attacker cannot deposit to an inflated position and exit atomically.

---

### R3 — Permissionless `CumulativeDeviationGuard.record`

**Risk.** Anyone can call `CumulativeDeviationGuard.record(token, fabricatedPrice)` to emit `PriceObserved` and `CircuitBreakerTripped` events with arbitrary prices. A griever could spam the event stream, causing alert fatigue or false-positive pauses if the off-chain monitor auto-pauses on trip events.

**Why it persists.** Adding a keeper allowlist now would introduce a new failure mode (a stuck allowlist) with no functional gain: `record` has no on-chain effect other than emitting events. Nothing on-chain is gated on the guard's state. Making it permissioned becomes meaningful only when on-chain auto-pause is wired to it (P5 scope, per `docs/audit/p5-tracking.md`).

**Compensating controls.**
- The P3 design spec (`docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md` §6) and the `CumulativeDeviationGuard.sol` NatSpec (lines 26–30) explicitly document that the off-chain monitor must treat events as untrusted hints and re-validate the price against the actual aggregator before acting.
- No on-chain action (pause, freeze, price change) can be triggered by `record` alone in the current implementation.
- When on-chain auto-pause is wired to the guard in P5, `record` must be made keeper-only at that time.

---

## 5. Trust Assumptions

The following roles exist in the post-P3 system. Each row states who can do what and what a compromise of that role yields.

| Role | Identity | Trusted with | Compromise yields |
|------|----------|-------------|-------------------|
| **Owner** | `TimelockController` (minDelay = 48 h), proposed by Governance Safe 3/5 | All `onlyOwner` functions on Pool and Registry: fee changes, oracle rotation, token listing, deviation caps, staleness limits, `syncAcceptedPrice`, `setPauseGuardian`, `transferOwnership` | Any owner action the attacker proposes executes after 48 h unless cancelled; up to 48 h window to alert community and cancel |
| **Governance Safe** | 3/5 Safe multisig (proposer role on Timelock); direct owner of MockChainlinkFeedV2 × 7 and OracleAggregator × 7 | Scheduling and cancelling Timelock proposals; instant `setWriter` and `transferOwnership` on feeds and aggregators | Malicious governance proposals (48 h delay for pool/registry); instant feed/aggregator writer rotation |
| **Pause Guardian** | 2/3 Safe multisig | `pool.pause()` only (instant, no Timelock) | Pool paused; but cannot be unpaused by guardian — requires `onlyOwner` path |
| **Oracle keepers** | EOA(s) that call `MockChainlinkFeedV2.setAnswer()` | Updating oracle prices within the bounds of `maxOracleDeviationBps` per swap and `maxDivergenceBps` per aggregator | Slow cache-walk attack on `lastAcceptedPrice`; bounded by 200 bps/tx + aggregator divergence check; detected by `CumulativeDeviationGuard` events |
| **LPs** | Any address holding LP tokens | Withdraw proportional share of pool NAV; transfer LP tokens freely | LP tokens represent a fungible claim; a compromised LP key loses only that LP's position |
| **Swappers** | Any address | Call `swap()` with tokens approved to the pool; consume oracle prices bounded by ratchet and caps | None beyond their own token balance |
| **`record` callers** | Anyone | Emit `PriceObserved` / `CircuitBreakerTripped` events via `CumulativeDeviationGuard.record()` | Alert noise; no on-chain state change |

---

*All claims above are verifiable against the contract source files in `contracts/src/`, the design specs in `docs/superpowers/specs/`, and the deployment scripts in `contracts/script/`.*
