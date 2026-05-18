# Phase 4 — Spearbit Audit Readiness — Design

**Date:** 2026-05-18
**Branch:** `phase4/audit-readiness`
**Parent roadmap:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §6
**Status:** design — awaiting implementation plan

## 1. Goal

Prepare ArcoraDEX for the Spearbit private review. Two parts:

- **Part A — Pre-audit hardening:** land a small set of cheap, clearly-beneficial
  contract changes on `main` so the audited code is closer to mainnet-final, then
  freeze a tagged commit.
- **Part B — Audit documentation pack:** produce the documents Spearbit's auditors
  receive on day one — scope, invariants, threat model, accepted risks,
  architecture, and a consolidated deferred-work register.

The actual security review is performed by Spearbit; this phase produces only the
inputs to that engagement. Findings come back and are triaged in the P4 tail /
P5 (out of scope for this spec).

## 2. Context

P1 (contract fixes), P2 (governance migration), P3 (oracle hardening) are merged
to `main`. The testnet deployment on Arc (chainId 5042002) is a rehearsal; mainnet
will deploy the audited code fresh. Therefore contract changes folded in here do
**not** require redeploying the testnet stack — they change the code that goes to
the audit and then to mainnet.

Current `main` after P3: 127 forge tests passing; core contracts
`ArcoraDexPool`, `ArcoraDexLP`, `ArcoraDexRegistry`, `OracleAggregator`,
`CumulativeDeviationGuard`.

## 3. Part A — Pre-audit hardening

### A1 — pause/unpause asymmetry

**Problem.** `ArcoraDexPool.pause()` and `unpause()` are both `onlyOwnerOrGuardian`
(`ArcoraDexPool.sol:509,514`). The Pause Guardian is a lower-threshold Safe (2/3)
intended for fast fail-safe response. A compromised guardian can therefore
*unpause* a pool the owner deliberately paused during an incident.

**Fix.** Guardian keeps `pause()` (fail-safe direction — pausing can only reduce
activity). `unpause()` becomes `onlyOwner` (the Timelock-fronted governance Safe).
This is the standard pause-guardian asymmetry: the low-trust role can stop the
system but only the high-trust role can restart it.

**Surface.** `unpause()` modifier `onlyOwnerOrGuardian` → `onlyOwner`. No new
errors/events. The `onlyOwnerOrGuardian` modifier remains (still used by `pause()`).

**Tests.** Update the P2 governance tests: a guardian-initiated `unpause()` must now
revert `NotAuthorized`; an owner-initiated `unpause()` still succeeds; guardian
`pause()` unchanged.

### A2 — Slither hygiene

Resolve the benign Slither warnings the project currently emits (rounding,
calls-in-loop, reentrancy-benign categories). For each: either a targeted
refactor, or a `// slither-disable-next-line <detector>` line with a one-line
justification comment. Acceptance: a Slither run produces no unexplained
warnings — every remaining item is either gone or has an inline justification an
auditor can read.

### A3 — `forge fmt` baseline

Run `forge fmt` across `contracts/src`, `contracts/test`, `contracts/script`,
commit the result as a single formatting baseline so the audit commit is not
polluted by style noise and post-audit diffs stay clean. This is a formatting-only
commit — no logic changes; the full suite must stay green with identical results.

### Deliberately out of scope for Part A

- **Keeper-only `CumulativeDeviationGuard.record`.** `record` is permissionless.
  This is only a meaningful hardening once on-chain auto-pause is gated on it
  (P5). Adding a keeper allowlist now is a design change with no functional gain
  and a new failure mode (a stuck allowlist). It stays permissionless and is
  documented as an accepted risk in `known-acceptable-risks.md`.
- **On-chain auto-pause, rolling (vs tumbling) deviation window, independent
  HW-wallet signer keys, Pyth/secondary mainnet feed sourcing.** All P5. Captured
  in `p5-tracking.md`.
- **Frontend `pnpm audit` / SDK test-hang cleanup.** Different repositories, not
  the contract audit target. Recorded in `p5-tracking.md` as a separate G3-gate
  track; not performed in this phase.

## 4. Part B — Audit documentation pack

All documents live in a new `docs/audit/` directory.

### `docs/audit/audit-scope.md`

- **In scope:** `ArcoraDexPool.sol`, `ArcoraDexLP.sol`, `ArcoraDexRegistry.sol`,
  `oracle/OracleAggregator.sol`, `oracle/CumulativeDeviationGuard.sol`, plus the
  `interfaces/` they depend on.
- **Out of scope:** `testnet/` mocks (`MockChainlinkFeedV2`, `MintableERC20`) —
  testnet-only, never deployed to mainnet; `script/` deploy scripts; OpenZeppelin
  `TimelockController`, `Ownable2Step`, `ERC20`; Safe v1.4.1 contracts — all
  upstream-audited.
- Per-file LoC, the frozen commit hash + `audit/spearbit-p4` tag, Solidity version
  (0.8.26), build/test/coverage commands, current test count and coverage numbers.
- A short system overview: oracle-priced multi-stablecoin vault, single shared LP
  token, NAV-based accounting, explicit `reserves[]` mapping.

### `docs/audit/invariants.md`

The formal invariants the protocol promises, each with a one-line rationale and a
pointer to the test(s) that exercise it:

- `NAV ≥ 0`, and monotonic with respect to in-flow (deposits + retained fees).
- `LP.totalSupply() ≥ MINIMUM_LIQUIDITY` once any deposit has occurred.
- `Σ (reserves[t] × price[t] / 10^decimals[t]) == totalReservesUSD()` — no
  off-chain drift; reserves are an explicit mapping, not `balanceOf`-derived.
- `protocolFeesAccrued[t] ≤ reserves[t]` strictly.
- Oracle-layer invariants from P1/P3: a reverting/stale oracle never bricks
  deposit/withdraw (cache fallback); the aggregator never returns a price outside
  `[min(sources), max(sources)]` of its live sources.

Where an invariant maps to an existing Foundry invariant/fuzz test, cite it; where
it does not, note it as a suggested target for Spearbit.

### `docs/audit/threat-model.md`

Every finding from the original security review (the pentester findings + the
additional findings Claude raised — reconcile the exact list and count against
`docs/superpowers/specs/2026-05-12-audit-cleanup-design.md` and the P1/P2/P3
design docs; do not assert a count not supported by those sources). For each
finding: ID, severity, description, which phase fixed it, and the commit/contract
where the fix lives. Then a residual-risk section: governance-multisig
compromise, oracle-keeper compromise (mitigated, not eliminated, by P3),
permissionless `record`.

### `docs/audit/known-acceptable-risks.md`

Risks the protocol knowingly accepts for v1, each with rationale and the
compensating control:

- Liquidity-thin freeze (a near-empty pool can round deposits to zero shares) —
  mitigated by virtual shares + `MINIMUM_LIQUIDITY`.
- Centralized initial liquidity (founding LP) — mitigated by the bootstrap plan.
- Permissionless `CumulativeDeviationGuard.record` — event-only, no on-chain
  action gated on it; off-chain monitor re-validates.
- Tumbling-window (not rolling) deviation guard — MVP; rolling detector is P5.
- Governance-multisig compromise — 3/5 threshold + 48h Timelock delay bounds it.
- Pre-bug-bounty exposure window — Immunefi launch is P5.

### `docs/audit/architecture.md`

- Deployment topology: Registry → Pool → LP, the 7 stablecoins, the 7
  aggregators + 14 underlying feeds, the guard.
- Governance stack: Governance Safe 3/5 → `TimelockController` (48h) owns
  Pool + Registry; Pause Guardian Safe 2/3 holds the guardian role.
- Oracle layer: per-token 2-source `OracleAggregator` consumed by the Registry;
  Pool reads via `IChainlinkAggregator`; cache fallback in `_readOracle`.
- ASCII or Mermaid diagrams where they aid comprehension.

### `docs/audit/p5-tracking.md`

A single consolidated register of every deferred item surfaced across P1–P4
reviews, so nothing is lost between now and P5: on-chain auto-pause wired to the
guard, keeper-only `record`, rolling deviation window, independent HW-wallet
signer keys, fee-collector multisig separation, frontend `pnpm audit` cleanup
(#5), SDK full-suite test hang, Slither items deferred rather than fixed (if
any), Pyth/secondary mainnet feed sourcing. Each row: item, origin (which
review/phase), why deferred, target phase.

## 5. Freeze

After Part A merges to `main`, tag the merge commit `audit/spearbit-p4`. Every
document in Part B references that tag and its commit hash. If Part B is authored
on the same branch before the tag exists, the scope doc uses a placeholder that
is replaced with the real hash immediately after the tag is cut.

## 6. Execution approach

Subagent-driven development, consistent with P1–P3: sonnet implementers and
spec-compliance reviewers, opus code-quality and final-branch reviews. Part A is
test-driven contract code; Part B is documentation (each doc authored by a
subagent, spec-reviewed for accuracy against the actual codebase, not just style).

Ordering: Part A first (A1 → A2 → A3) so the codebase is stable, then Part B
documents the frozen state, then the tag.

## 7. Out of scope

- The Spearbit engagement itself (outreach, contracting, the review).
- Triaging/fixing findings the audit returns (P4 tail / P5).
- Any frontend or SDK repository work.
- Mainnet deployment (P5).
