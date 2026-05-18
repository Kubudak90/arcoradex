# ArcoraDEX — P5 Deferred-Work Register

**Date:** 2026-05-18
**Branch at authoring:** `phase4/audit-rollout`
**Audience:** Spearbit auditors + ArcoraDEX team

---

## Introduction

This document is the consolidated register of every work item deliberately deferred
during Phases 1–4 of the ArcoraDEX mainnet-readiness programme. Items were collected
from the following source documents:

- `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` (roadmap §§3–7,
  §10, "Out of scope" blocks)
- `docs/superpowers/specs/2026-05-14-phase1-contract-fixes-design.md` (§2
  Non-Goals)
- `docs/superpowers/specs/2026-05-14-phase2-governance-design.md` (§2 Non-Goals,
  §10 Out of Scope)
- `docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md` (§2
  Non-Goals, §6 off-chain monitoring note, §8 keeper-update note)
- `docs/superpowers/specs/2026-05-18-phase4-audit-readiness-design.md` (§3
  "Deliberately out of scope for Part A", §7 Out of scope)
- `docs/rollouts/2026-05-14-phase2-governance.md` ("Downstream tasks")
- `docs/rollouts/2026-05-14-phase3-oracle.md` ("Downstream tasks", "Tracking for P5")
- `docs/audit/threat-model.md` (§4 Residual Risks — items carried forward)
- `docs/audit/known-acceptable-risks.md` (R3, R4, R7, R8 — items explicitly
  tagged as P5 follow-ups)

No item in this register is invented. Every row traces to at least one section
reference listed above. When a source says an item is deferred, the entry below
cites that source's exact section so the traceability chain can be verified.

---

## Deferred-Work Register

| # | Item | Origin | Why deferred | Target |
|---|------|--------|--------------|--------|
| D1 | **On-chain auto-pause wired to `CumulativeDeviationGuard`** — when the guard emits `CircuitBreakerTripped`, automatically trigger `pool.pause()` on-chain rather than relying on a human operator to submit a Pause Guardian Safe transaction. | P3 design spec §2 Non-Goals; P3 rollout "Tracking for P5"; threat-model §4 R2; KAR R3 | No operational experience yet with false-positive trip rate. Wiring auto-pause to an event that any address can trigger (see D2) without first making `record` keeper-only would create a trivial griefing path. The sequence — D2 first, then D1 — is required for safety. | P5 |
| D2 | **Keeper-only access control on `CumulativeDeviationGuard.record`** — restrict the `record(address, uint256)` function to a whitelisted keeper EOA. Currently permissionless: anyone can call it with a fabricated price to emit spurious `CircuitBreakerTripped` events. | P4 design spec §3 "Deliberately out of scope for Part A"; P3 design spec §6 ("Who calls `record`?"); threat-model §4 R3; KAR R3 | No functional benefit while `record` has no on-chain action gated on it. Adding a keeper allowlist now introduces a new failure mode (stuck allowlist) with zero gain. Becomes meaningful and necessary once D1 (auto-pause) is wired. | P5 |
| D3 | **Rolling (vs tumbling) deviation window in `CumulativeDeviationGuard`** — upgrade the 24 h tumbling window to a true rolling window to close the boundary-straddling manipulation vector (an attacker can push just below `maxCumulativeBps` in every window, drifting the price indefinitely without ever tripping the breaker). | P3 rollout "Tracking for P5"; P3 design spec §6 ("Why tumbling window over rolling"); threat-model §4 note on #P3-O; KAR R4 | Tumbling window was the deliberate P3 MVP choice: simpler, cheaper (stores only two values per token), and sufficient to catch acute intra-window spikes. A rolling window requires either a circular buffer or a two-checkpoint scheme — more audit surface and materially higher per-call gas. | P5 |
| D4 | **Independent hardware-wallet signer keys for the Governance Safe and Pause Guardian Safe** — the current testnet governance rehearsal uses keys derived from the standard Foundry test mnemonic ("test test test … junk"), which is public knowledge. All 8 signer addresses and their private keys are known. | P2 design spec §5, §10 Out of Scope; P2 rollout "Mainnet rotation (P5)" note; roadmap §4 Risks | This is a testnet rehearsal; software keys are sufficient to validate the governance flow. Procuring, provisioning, and onboarding hardware wallets (Ledger Nano per signer) requires a separate procurement and signer-coordination process that is a P5 mainnet pre-flight step. | P5 |
| D5 | **Mainnet deployment of the governance stack** — deploying `TimelockController`, Governance Safe (3/5 with real signer identities), and Pause Guardian Safe (2/3) to mainnet with the real hardware-wallet-backed addresses. | P2 design spec §10 Out of Scope; roadmap §4 | All governance contracts on-chain today are testnet rehearsal instances. The mainnet deploy requires real signer identities, hardware wallets (D4), and a public announcement period. | P5 |
| D6 | **Fee-collector multisig separation from governance ownership** — introduce a dedicated fee-collector role or multisig so that `withdrawProtocolFees` does not require the same governance key-set that controls oracle rotation and parameter changes. | Roadmap §4 Out of scope ("Fee-collector multisig separation (deferred — current governance multisig collects fees)"); KAR R7 | Would require a dedicated fee-withdrawal module and adds governance audit surface before the Spearbit review. The Timelock 48 h delay on `withdrawProtocolFees` is an accepted compensating control for v1. | P5 |
| D7 | **Frontend dependency vulnerability remediation** (finding #5) — `pnpm audit` on the frontend/app repository reported 35 vulnerabilities including 1 critical and 13 high in the Next.js, axios, and happy-dom dependency chains. | Roadmap §6 (P4 findings table, finding #5); P4 design spec §3 "Deliberately out of scope for Part A"; threat-model §2 finding #5 | This is a frontend/app repository issue, not a smart-contract audit target. It is not in scope for the Spearbit contract review but must be resolved before the G3 gate (Spearbit sign-off → mainnet). | ✅ DONE 2026-05-18 — `next` 16.2.6 + `pnpm.overrides` for axios/happy-dom/esbuild/vite/postcss; `pnpm audit` clean. |
| D8 | **SDK full-suite test hang** — the SDK test suite passes when tests are run individually but stalls when the full suite runs. | Roadmap §6 (P4 findings table, "SDK test suite hang on full run") | Different repository from the contract suite; identified as a low-severity ops issue for the SDK team to investigate. Not a contract-audit blocker. | P5 |
| D9 | **Pyth / independent secondary mainnet feed sourcing for exotic FX pairs (TRYC, BRLC)** — replace the testnet `MockChainlinkFeedV2` secondary feeds with Pyth or an on-chain TWAP (a genuinely independent price source with a separate custody chain) to provide real source independence on mainnet. | Roadmap §5 Risks ("Pyth or alternative feed unavailable for TRY/BRL"); roadmap §5 Out of scope; roadmap §11 Open Question #6; P3 design spec §2 Non-Goals; P3 rollout "Tracking for P5"; threat-model §4 R2 | No Chainlink or Pyth mainnet coverage for TRYC/BRLC was available at P3 implementation time. P3 MVP = tighten per-token caps + add a secondary testnet mock feed for structural diversity. Full source independence (separate custody chain, different oracle provider) becomes a P5 enhancement once mainnet feed availability is confirmed. | P5 / P5+ |
| D10 | **Off-chain deviation-recorder monitoring script** (`ops/monitoring/cumulative-deviation-recorder.mjs`) — the script that calls `guard.record(token, price)` every keeper cycle so `CumulativeDeviationGuard` tracks the rolling price drift and can emit `CircuitBreakerTripped` events. | P3 design spec §6 ("Off-chain monitoring integration"), §8 ("Keeper updates — operational, not in this PR"); P3 rollout "Downstream tasks" | Operational tooling outside the contract PR scope. The guard is live on-chain but has no caller yet; the monitoring script is the first deliverable that makes D1 practically meaningful. | ✅ DONE 2026-05-18 — `ops/keepalive/guard-record.mjs` + systemd timer (Phase 3 Operationalization). |
| D11 | **Keeper: migrate secondary-feed writer from deployer EOA to keeper EOA** — after the P3 Timelock batch executes, the Governance Safe must call `<secondaryFeed>.setWriter(keeperEOA)` for each of the 7 secondary `MockChainlinkFeedV2` feeds. Until this is done, secondary feed prices go stale and the `OracleAggregator`'s divergence check may revert. | P3 rollout "Downstream tasks" (first item) | Operational follow-up requiring a Governance Safe transaction, tracked separately from the Timelock batch. Not a code change; not a contract-audit blocker. | ✅ DONE 2026-05-18 — `MigrateSecondaryWriters.s.sol` broadcast; 7/7 secondary feeds' writer = keeper EOA (Phase 3 Operationalization). |
| D12 | **Monitoring and alerting infrastructure** (feed freshness, reserves imbalance, multisig pending-tx, deviation breach, NAV daily snapshot) — the complete off-chain monitoring stack described in the mainnet operations plan. | Roadmap §7 ("Monitoring & alerting") | P5 mainnet operations deliverable. The on-chain contracts are observable but the watcher scripts, Slack/Discord webhooks, and Prometheus probes require a dedicated ops build that is separate from the P1–P4 contract work. | P5 |
| D13 | **Incident response playbook and drill** — the written emergency-response procedures (pause decision tree, oracle-compromise scenario, multisig key-loss scenario) plus a live drill with all Pause Guardian signers before TVL goes live. | Roadmap §7 ("Incident response playbook"); roadmap §9 Gate G4 ("IR drill completed; all signers tested for emergency pause") | Requires real signer participation (D4) and is a readiness check against the mainnet governance stack (D5). Cannot be meaningfully rehearsed with throwaway testnet keys and mock governance. | P5 |
| D14 | **Immunefi bug-bounty program launch** — publishing the scope, reward tiers, and out-of-scope list on Immunefi and funding the initial reward pool. | Roadmap §7 ("Bug bounty launch (Immunefi)"); KAR R8 | Must be launched against the audited, mainnet-deployed code with finalized contract addresses and TVL commitments. The sequence is: Spearbit audit → mainnet deploy → Immunefi launch. | P5 (first week post-mainnet) |
| D15 | **Faucet sunset** — disabling the faucet route in the mainnet frontend; mock token contracts are not deployed on mainnet; testnet faucet remains for QA. | Roadmap §7 ("Faucet sunset") | Operational step that depends on the mainnet deployment being live. Testnet faucet is kept for integration partner QA. | P5 |
| D16 | **Initial-liquidity bootstrap** — onboarding founding LPs, agreeing TVL-floor commitments, and seeding the mainnet pool with initial reserves. | Roadmap §7 ("Initial liquidity bootstrap"); roadmap §7 Risks ("Initial LP traffic too thin"); KAR R2 | Requires real capital, commercial agreements with founding LPs, and a live mainnet deployment. The bootstrap amount and LP distribution mechanics are unresolved stakeholder decisions. | P5 |
| D17 | **Gas optimization** — profiling and optimizing hot-path gas costs (swap, deposit, withdraw, quote) after Spearbit may highlight areas. Intentionally not performed pre-audit to avoid introducing logic changes after the audit pack is frozen. | Roadmap §3 Out of scope; roadmap §10 ("Gas optimization beyond audit recommendations"); P1 design spec §2 Non-Goals | Pre-audit gas optimization risks introducing subtle logic changes that invalidate the audit. Spearbit's recommendations will guide the scope of any post-audit optimization pass. | P5 / v2 |
| D18 | **Formal verification (Certora)** — machine-checked proofs of the core invariants (NAV monotonicity, LP supply floor, reserves integrity). | Roadmap §6 Out of scope ("Formal verification (Certora) — defer to v2"); roadmap §10 | Significant cost and lead time; not justifiable before the first Spearbit review establishes a finding baseline. Targeted at v2 as the protocol matures. | v2 |
| D19 | **Multi-chain expansion** (Layer 2s, Cosmos, Solana) and **cross-chain bridge integration** — deploying ArcoraDEX on networks other than the initial mainnet chain. | Roadmap §7 Out of scope; roadmap §10 ("Multi-chain expansion"; "Cross-chain bridge integration") | Out of scope for v1; separate architecture, separate audit surface. Standalone future workstream. | v2 / future |
| D20 | **Real-yield strategies on idle reserves** (Aave, Morpho, Yearn integration) — earning yield on pool reserves between swaps. | Roadmap §7 Out of scope; roadmap §10 ("Real-yield strategies on idle reserves (Aave, Morpho, Yearn integration)") | Adds substantial audit surface (integration risk, re-entrancy surface, liquidation/withdrawal-timing risk). Not in scope for v1 pool. | v2 / future |
| D21 | **DAO governance token / TGE** — an on-chain governance token and token-generation event; compound-style governor replacing the Safe-based governance model. | Roadmap §7 Out of scope; roadmap §10 ("DAO governance token / TGE"); P2 design spec §2 Non-Goals ("On-chain DAO token / Compound-style governor") | Separate legal, financial, and technical workstream. Safe-based governance is sufficient for the initial mainnet. | future |
| D22 | **SDK v2 and frontend redesign** — a second-generation SDK with a stable API contract and a UX-overhaul of the frontend. | Roadmap §10 ("SDK v2"; "Frontend redesign / UX overhaul") | Deferred pending mainnet stabilization and user feedback. The current SDK is a testnet integration tool; a production SDK design iteration follows once the protocol is live. | future |

---

## Items Completed in P4 (for traceability)

The following items were explicitly in scope for P4 and are **DONE**. They are
listed here so the deferred-work register is complete and readers can confirm
nothing in this section is still open.

| Item | Status | Notes |
|------|--------|-------|
| **A1 — pause/unpause asymmetry fix** — `unpause()` modifier changed from `onlyOwnerOrGuardian` to `onlyOwner`; guardian retains `pause()` only. | DONE (P4, Part A) | `ArcoraDexPool.sol` line 626. Test updated: guardian-initiated `unpause()` now reverts `OwnableUnauthorizedAccount` (OZ `Ownable`). |
| **A2 — Slither hygiene** — benign Slither warnings (rounding, calls-in-loop, reentrancy-benign categories) either refactored away or suppressed with inline justification comments visible to auditors. | DONE (P4, Part A) | All remaining Slither items carry a `// slither-disable-next-line` with a one-line rationale. No unexplained warnings remain. |
| **A3 — `forge fmt` baseline** — formatting pass across `contracts/src/`, `contracts/test/`, `contracts/script/` committed as a standalone formatting-only commit. | DONE (P4, Part A) | Full test suite passes unchanged. No logic modifications. |
| **Audit documentation pack** — `docs/audit/audit-scope.md`, `docs/audit/invariants.md`, `docs/audit/threat-model.md`, `docs/audit/known-acceptable-risks.md`, `docs/audit/architecture.md`, `docs/audit/p5-tracking.md` (this file). | DONE (P4, Part B) | All six documents committed on `phase4/audit-rollout`. |

---

*All claims above are verifiable against the source documents cited in the
"Origin" column. No item in the deferred register is speculative — every row
derives directly from an explicit out-of-scope, deferred, or downstream-task
statement in the cited source.*
