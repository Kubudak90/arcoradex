# ArcoraDEX Mainnet Readiness Roadmap

**Date:** 2026-05-13
**Status:** Brainstorming complete — pending user review, then per-phase brainstorming begins
**Authors:** Hüseyin Arslan + Claude
**Audit context:** Combines findings from the 2026-05-12 post-cutover audit and the external review delivered 2026-05-13 (8 findings total + 3 additional Claude-surfaced economic-attack vectors).

**Target window:** 6-8 weeks (aggressive). Parallel-tracked across 5 phases.

---

## 1. Why This Roadmap

The 2026-05-10 key-separation cutover and the 2026-05-12 post-cutover cleanup closed the operational footguns around the keeper. A subsequent security review surfaced eight findings spanning smart-contract economics, governance, oracle dependence, dependency hygiene, and operational rate-limiting. A second-opinion pass added three more findings the original review missed — most importantly a first-depositor **inflation attack** (Uniswap V2 class) that is currently CRITICAL for any mainnet deploy.

The combined finding set covers four largely independent subsystems: protocol math, governance custody, oracle infrastructure, and ops/audit. Bundling them into a single PR would create coordination overhead and stretch reviewer attention. This roadmap decomposes the work into five parallel-trackable phases, each with its own brainstorming → spec → plan → implementation cycle.

This document is the **meta-spec**. It does not specify implementation details for any single fix — each phase's detailed spec lives in its own file under `docs/superpowers/specs/`.

---

## 2. Phase Map

```
Week   1   2   3   4   5   6   7   8
       │   │   │   │   │   │   │   │
P1 ────████████████─────────────────  Smart contract critical fixes
P2 ────████████████─────────────────  Governance migration (parallel)
P3 ────────████████████████──────────  Oracle hardening (P1 storage layout dependent)
P4 ────────────────████████████──────  Spearbit private review + cleanup
P5 ────────────────────────────████──  Mainnet deploy & operations
```

Approval gates between phases (see §9). Each phase has its own deliverable; subsequent phases unblock when their dependencies are explicitly met.

---

## 3. Phase 1 — Smart Contract Critical Fixes

**Duration:** 2–2.5 weeks (Weeks 1–3)
**Parallel with:** P2
**Blocks:** P3 (storage layout commit by end of Week 2), P4

### Findings addressed

| ID | Finding | Severity | Fix sketch |
|----|---------|----------|------------|
| #A | First-depositor inflation attack | **CRITICAL** | Virtual shares (ERC4626 offset pattern) OR `MINIMUM_LIQUIDITY` bump to 1e6 (USD-units); virtual shares preferred |
| #B | JIT/MEV sandwich on deposit/withdraw | HIGH | LP min-hold period (≥1 block, ideally ≥1 oracle update) and/or asymmetric deposit/withdraw fee |
| #C | Quote↔execute deviation gap | MEDIUM | `quote()` simulates `lastAcceptedPrice` ratchet so reverts are predictable |
| #4 | Stale-feed locks deposit/withdraw globally | MEDIUM | Per-token `maxStaleSeconds` (Registry schema extension) + graceful NAV handling (last-known-price fallback, no auto-deactivate) |

### Deliverables

- 4–5 PRs (one per finding), each with exploit PoC test
- Foundry test coverage ≥85% on `contracts/src/` (current baseline 77 tests)
- Slither warnings either fixed or explicitly suppressed with rationale
- Updated litepaper (`docs/litepaper/`) reflecting new mechanics

### Out of scope for P1

- New token listings or registry redesign beyond schema extension for `maxStaleSeconds`
- Gas optimization (deferred to post-audit if Spearbit recommends)
- Oracle aggregator changes (P3)

### Risks

- Storage layout change may require migration on testnet (Pool + Registry both ownable, upgradable via owner-mediated redeploy if necessary). Migration script tested by end of Week 2.

---

## 4. Phase 2 — Governance Migration

**Duration:** 1.5–2 weeks (Weeks 1–3)
**Parallel with:** P1
**Blocks:** P5

### Findings addressed

| ID | Finding | Severity | Fix sketch |
|----|---------|----------|------------|
| #3 | Deployer EOA is single point of failure for all owner operations | HIGH (mainnet blocker) | Safe 3/5 multisig + OpenZeppelin `TimelockController` (48h delay) + separate Pause Guardian multisig (2/3 hot) |

### Deliverables

- **Safe multisig deployed** on testnet first, mainnet later
  - Signers: founder + 2 advisors + 2 community/trusted
  - Hardware wallet (Ledger Nano) required per signer
- **Standard OZ `TimelockController`** as Safe module
  - 48 h delay for normal owner actions
  - `pause()` and `unpause()` exempt (immediate execution via separate guardian)
- **Pause Guardian** multisig — 2/3 hot wallet, **only** `pause`/`unpause` permission
- **Migration scripts** (Forge) that transfer ownership of Pool, Registry, all 7 feeds, and (post-faucet-sunset) the faucet from deployer EOA to the governance multisig
- **Testnet dry-run report**: full ownership transfer + simulated emergency pause + simulated parameter change

### Out of scope for P2

- Custom Safe modules beyond standard TimelockController (not worth the audit surface)
- DAO token / on-chain voting (not in scope for first mainnet)
- Fee-collector multisig separation (deferred — current governance multisig collects fees)

### Risks

- Hardware wallet procurement lead time ~1 week. **Mitigation:** order Week 1 day 1; if delayed, deploy testnet multisig with software wallets and rotate later (zero on-chain risk pre-mainnet).
- Signer coordination (5 people) for first ownership transfer may take longer than budgeted. **Mitigation:** schedule rehearsal in Week 2.

---

## 5. Phase 3 — Oracle Hardening

**Duration:** 2–2.5 weeks (Weeks 2–4)
**Parallel with:** P1 (tail), P2 (tail)
**Depends on:** P1 Registry storage layout commit (end Week 2)
**Blocks:** P4

### Findings addressed

| ID | Finding | Severity | Fix sketch |
|----|---------|----------|------------|
| #1 | TRYC/BRLC deviation cap 5000 bps + iterative writer-compromise drain | HIGH | Per-token cap recalibration (50–300 bps), multi-source aggregator, cumulative deviation circuit breaker |
| #4 (cont.) | Per-token staleness + graceful fallback | MEDIUM | Picks up from P1's `maxStaleSeconds` schema |

### Deliverables

- **`OracleAggregator.sol`** — new contract
  - Primary feed: Chainlink (mainnet) / current MockChainlinkFeedV2 (testnet)
  - Secondary feed: TWAP-from-on-chain-DEX or Pyth pull oracle (TBD per token availability)
  - Aggregation rule: median of primary + secondary; if either stale or out-of-band, fall back to the other with a flag
- **Per-token deviation cap recalibration**
  - Survey Chainlink mainnet heartbeats for each candidate listing
  - Set on-chain `maxOracleDeviationBps` to 2× the natural feed heartbeat tolerance, capped at 300 bps for any token
  - Migration: Registry `setDeviation()` calls from governance multisig
- **Circuit breaker** — `CumulativeDeviationGuard.sol`
  - Tracks 24h rolling max deviation per token
  - If exceeded, emits event and triggers Pause Guardian alert (off-chain monitor decides whether to pause)
- **Monitoring metrics export** — feed age, deviation drift, aggregator divergence

### Out of scope for P3

- Pyth integration if no mainnet support for TRY/BRL pairs (fall back to TWAP-only secondary)
- Anomaly-detection ML models (out of scope; threshold-based is sufficient)
- Multi-chain oracle reads (mainnet is single-chain for v1)

### Risks

- Pyth or alternative feed unavailable for exotic FX (TRY, BRL). **Mitigation:** P3 MVP = tighten caps + TWAP-only secondary; full multi-source becomes a P5+ enhancement.
- Aggregator gas cost increase. **Mitigation:** budget +30k gas per swap; if exceeded, optimize before merge.

---

## 6. Phase 4 — Spearbit Private Review + Cleanup

**Duration:** 2.5–3 weeks (Weeks 4–6)
**Depends on:** P1, P2, P3 done
**Blocks:** P5

### Findings addressed

| ID | Finding | Severity | Fix sketch |
|----|---------|----------|------------|
| #5 | Frontend dependency vulnerabilities (35 vulns, 1 critical, 13 high per `pnpm audit`) | MEDIUM | Update Next 16.2.5+, axios chain, happy-dom 20.8.9+; rerun audit |
| — | SDK test suite hang on full run | LOW | Debug & fix; observed: tests run individually but full suite stalls |
| — | Slither benign warnings (rounding/calls-loop/reentrancy-benign) | LOW | Either refactor or `slither-disable-next-line` with justification comment |
| — | All P1+P2+P3 work | (review-only) | Spearbit auditors review the merged state |

### Engagement details

- **Audit firm:** Spearbit (or Cantina) — outreach Week 1 day 1
- **Lead time:** typically 2–3 weeks from booking to start
- **Review duration:** 2 weeks
- **Auditors:** 2–3 senior, mixed expertise (DeFi + Solidity + oracle)
- **Budget envelope:** $30k–$50k

### Documentation pack prepared for auditors

- This roadmap doc
- Latest litepaper (produced or updated during P1)
- **Invariants document** (new) — formal invariants the protocol promises:
  - `NAV ≥ 0` and monotonic with respect to in-flow (deposits + fees retained)
  - `LP.totalSupply() ≥ MINIMUM_LIQUIDITY` once any deposit has occurred
  - `Σ reserves[t] × price[t] / 10^dec[t] = totalReservesUSD()` (no off-chain drift)
  - `protocolFeesAccrued[t] ≤ reserves[t]` strictly
- **Threat model document** (new) — combines all 11 findings + acknowledged residual risks (e.g. governance multisig compromise)
- **Known-acceptable-risks** list — liquidity-thin freeze; centralized initial liquidity; pre-bug-bounty exposure window

### Deliverables

- Spearbit report (private until protocol agrees to publish)
- All Critical/High findings fixed and re-verified
- Medium findings triaged: fix if cheap, document as known-acceptable if not
- Frontend deps green via `pnpm audit --audit-level moderate`

### Out of scope for P4

- Code4rena / Cantina public contest (potential post-mainnet phase)
- Formal verification (Certora) — defer to v2

### Risks

- Spearbit calendar full. **Mitigation:** parallel outreach to Cantina/Sigma Prime/OpenZeppelin during Week 1.
- Auditors find Critical/High blocker. **Mitigation:** Week 6 has 1-week fix buffer; if blocker is large, P5 slips by 1–2 weeks (acceptable to total 8–10 weeks).

---

## 7. Phase 5 — Mainnet Deploy & Operations

**Duration:** 1–1.5 weeks (Weeks 7–8)
**Depends on:** P4 sign-off

### Deliverables

#### Mainnet deployment runbook
- Step-by-step Forge script sequence: deploy Registry → deploy Pool (which deploys LP) → list tokens → set oracles → `transferOwnership` to governance multisig (24h timelock pending) → bootstrap liquidity → governance unpause
- Pre-deploy dry run on Sepolia or Holesky
- Gas estimates per step, total deploy budget

#### Monitoring & alerting (off-chain, on VPS)
- **Feed freshness watcher** — per token, every 60s; alert if `block.timestamp - updatedAt > maxStaleSeconds × 0.8`
- **Reserves imbalance** — daily 24h delta; alert on >3σ deviation
- **Multisig pending tx** — Slack/Discord webhook
- **Deviation breach** — per-token alert when current oracle is within 80% of `maxOracleDeviationBps` vs `lastAcceptedPrice`
- **NAV daily snapshot** — internal dashboard

#### Incident response playbook
- Emergency pause procedure (Pause Guardian signer rota + decision tree)
- Oracle compromise scenario
- Multisig key loss scenario (signer replacement procedure)
- Public-communication templates (Twitter, Discord, status page)

#### Bug bounty launch (Immunefi)
- Initial scope: Pool, Registry, OracleAggregator, governance contracts
- Reward tiers: Low $1k, Medium $5k, High $25k, Critical $50k (scales with TVL)
- Out-of-scope explicit list: third-party Chainlink feeds, frontend XSS, RPC provider issues

#### Faucet sunset
- Mainnet frontend: faucet route disabled
- Testnet faucet remains for QA + integration partner work
- Mock token contracts not deployed on mainnet

#### Initial liquidity bootstrap
- Founding LPs onboarding (TBD how many, what size)
- Target initial pool seed: $X — to be discussed with stakeholders
- LP token distribution mechanics for founding contributors (vesting? bonus? — separate decision)

### Out of scope for P5

- Token launch / TGE / governance token (separate workstream)
- Multi-chain expansion (Layer 2s, other EVM chains)
- Cross-chain bridge integration
- Real-yield strategies on idle reserves (e.g. Aave deposit)

### Risks

- Mainnet gas spikes during deploy. **Mitigation:** schedule deploy for low-gas window (weekend UTC); have abort path if base fee > $X.
- Initial LP traffic too thin → liquidity-thin freeze on FX legs (same pattern we saw on testnet). **Mitigation:** founding LPs commit to weekly EURC/TRYC/BRLC volume floor; governance multisig calls `syncAcceptedPrice` as needed in first month.

---

## 8. Cross-Cutting Concerns

### Per-phase cycle
Each phase has its own complete cycle:
1. Brainstorming session (this skill) — exploring per-phase design choices
2. Spec doc — `docs/superpowers/specs/2026-05-XX-phase-N-<topic>-design.md`
3. Implementation plan — `docs/superpowers/plans/2026-05-XX-phase-N-<topic>.md`
4. Subagent-driven implementation
5. Final code review
6. Merge to main

### Parallelization rules
- **P1 + P2 paralel from Week 1.** Different code paths (contracts vs governance scripts), no merge conflict expected.
- **P3 starts Week 2** after P1 commits Registry storage extension. If P1 delays, P3 absorbs the slip.
- **P4 booking Week 1, engagement Week 4.** Hard external dependency on auditor calendar.
- **Hardware wallet procurement Week 1 day 1** (P2 unblocker).

### Documentation coordination
- Litepaper kept current with each phase's changes (architectural-level updates only)
- Invariants and threat-model docs first drafted in P1, hardened in P4
- This roadmap is updated at end of each phase with actuals (durations, slips, scope changes)

---

## 9. Approval Gates

Each gate must pass before the next phase begins:

| Gate | From → To | Pass criteria |
|------|-----------|---------------|
| G1 | P1 → P3 storage commit | Registry schema extension PR merged; all P1 exploit-PoC tests fail before fix, pass after fix; Slither clean |
| G2 | P1+P2+P3 → P4 | All Critical/High findings from internal review have merged fixes + tests; testnet running stably for ≥3 days; governance multisig active on testnet |
| G3 | P4 → P5 | All Critical/High findings from Spearbit have merged fixes; Spearbit final report received; frontend `pnpm audit` clean at moderate+ level |
| G4 | P5 deploy | Monitoring + IR drill completed; all signers tested for emergency pause; founding LPs committed |

---

## 10. Out of Scope (Deferred)

- Multi-chain expansion (Layer 2s, Cosmos, Solana)
- Cross-chain bridge integration
- Real-yield strategies on idle reserves (Aave, Morpho, Yearn integration)
- DAO governance token / TGE
- Gas optimization beyond audit recommendations
- Frontend redesign / UX overhaul
- SDK v2
- Formal verification (Certora)

---

## 11. Open Questions for Stakeholders

These need decisions before or during P1/P2:

1. **Inflation-attack fix:** virtual shares (more invasive but cleaner) vs MIN_LIQUIDITY bump (1 line, less effective)?
2. **MEV mitigation:** LP min-hold period (UX friction) vs asymmetric fees (cap upside but smoother)?
3. **Governance multisig signers:** specific names + jurisdictions for the 5 signers?
4. **Founding LP bootstrap:** target $ size, how many founding LPs, vesting/bonus terms?
5. **Audit firm selection:** Spearbit vs Cantina vs others — based on availability + price quote in Week 1?
6. **Pyth vs TWAP-only secondary:** acceptable to start with TWAP-only and add Pyth as P5+ enhancement?

These will be resolved in each phase's brainstorming session.

---

## 12. Document History

| Date | Author | Change |
|------|--------|--------|
| 2026-05-13 | Hüseyin + Claude | Initial roadmap; brainstorming session captured all 11 findings + agreed phase boundaries + aggressive 6-8 week target |

This document will be amended at the end of each phase with actuals vs estimates and any scope changes.
