# Phase 4 — Audit Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare ArcoraDEX for the Spearbit private review — land three small pre-audit hardening changes on the contracts, produce the six-document audit pack, then freeze a tagged audit baseline.

**Architecture:** Part A is small TDD'd contract changes (`unpause()` access tightening, Slither warning hygiene, a `forge fmt` baseline). Part B is six Markdown documents under `docs/audit/`, each authored from the actual codebase and spec-reviewed for factual accuracy. After everything merges to `main`, the merge commit is tagged `audit/spearbit-p4`.

**Tech Stack:** Solidity 0.8.26, Foundry (forge build/test/fmt/coverage), Slither, Markdown.

**Spec:** `docs/superpowers/specs/2026-05-18-phase4-audit-readiness-design.md`
**Parent roadmap:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §6

---

## File Structure

### Files modified
| File | Changes |
|------|---------|
| `contracts/src/ArcoraDexPool.sol` | `unpause()` modifier `onlyOwnerOrGuardian` → `onlyOwner` (Task 2); Slither justification comments (Task 3); reformatted by `forge fmt` (Task 4) |
| `contracts/test/governance/P2Governance.t.sol` | Update the guardian-unpause test to expect a revert (Task 2) |
| Most files under `contracts/src`, `contracts/test`, `contracts/script` | `forge fmt` reformatting only (Task 4) |

### Files created
| File | Purpose |
|------|---------|
| `docs/audit/audit-scope.md` | In/out-of-scope contracts, LoC, frozen commit/tag, build & test instructions |
| `docs/audit/invariants.md` | Formal protocol invariants + test pointers |
| `docs/audit/threat-model.md` | Every original-review finding, the fix, residual risks |
| `docs/audit/known-acceptable-risks.md` | Knowingly accepted v1 risks + compensating controls |
| `docs/audit/architecture.md` | Deploy topology, governance stack, oracle layer |
| `docs/audit/p5-tracking.md` | Consolidated deferred-work register (P1–P5) |

### Branches
- `phase4/audit-readiness` (already exists with the spec; this plan is committed here)
- After the planning PR merges, implementation proceeds on `phase4/audit-rollout`

---

### Task 1: Branch setup and baseline verification

**Files:** none modified.

- [ ] **Step 1: Confirm the planning PR merged to main**

```bash
git checkout main && git pull --ff-only origin main
git log -1 --format='%h %s'
```
Expected: HEAD is the P4 planning merge (mentions `phase 4 audit readiness`).

- [ ] **Step 2: Create the implementation branch**

```bash
git checkout -b phase4/audit-rollout
```

- [ ] **Step 3: Establish the forge test baseline**

```bash
cd contracts && forge build && forge test 2>&1 | tail -3
```
Expected: `127 tests passed, 0 failed, 0 skipped` (post-P3 baseline).

- [ ] **Step 4: Confirm Slither is available**

```bash
cd contracts && slither --version 2>&1 | tail -1
```
Expected: a version string. If Slither is not installed, install it (`pip install slither-analyzer`) or report BLOCKED so the controller can advise — Task 3 needs it.

No commit — Task 1 is verification only.

---

### Task 2: A1 — pause/unpause asymmetry

**Files:**
- Modify: `contracts/src/ArcoraDexPool.sol`
- Modify: `contracts/test/governance/P2Governance.t.sol`

The Pause Guardian Safe (2/3, lower trust) must keep fail-safe `pause()` but must not be able to `unpause()`. Only the owner (governance Timelock) may unpause.

- [ ] **Step 1: Read the current code**

In `contracts/src/ArcoraDexPool.sol` find `pause()` and `unpause()` (around lines 509 and 514). Confirm both currently carry the `onlyOwnerOrGuardian` modifier, and that an `onlyOwner` modifier exists and is used elsewhere (e.g. `setSwapFeeBps`). Confirm the `onlyOwnerOrGuardian` modifier and the `NotAuthorized()` error.

- [ ] **Step 2: Update the failing test first**

Open `contracts/test/governance/P2Governance.t.sol`. Find the test that exercises the Pause Guardian unpausing the pool (named like `test_pauseGuardian_canUnpauseInstantly` or similar — search for `unpause`). That test currently asserts the guardian CAN unpause. Change it so the guardian-initiated `unpause()` is now expected to revert `NotAuthorized`, and rename it accordingly (e.g. `test_pauseGuardian_cannotUnpause`). Keep/confirm there is still a test that the OWNER can unpause, and that the guardian can still `pause()`.

The guardian-cannot-unpause assertion should look like (adapt to the file's existing Safe-exec / prank pattern — read the surrounding tests):
```solidity
vm.expectRevert(ArcoraDexPool.NotAuthorized.selector);
// ...guardian-initiated unpause call, using the same mechanism the old test used...
```
If the old test drove the guardian via the Pause Guardian Safe, keep that mechanism — only the expectation changes (revert instead of success). If the owner-unpause path is not already covered by a separate test, add `test_owner_canUnpause` that pauses (via guardian or owner) then unpauses via the owner and asserts `paused() == false`.

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd contracts && forge test --match-contract P2Governance -vv 2>&1 | tail -15
```
Expected: the updated guardian-unpause test FAILS — the guardian unpause currently succeeds, so `vm.expectRevert` is not satisfied.

- [ ] **Step 4: Tighten `unpause()`**

In `contracts/src/ArcoraDexPool.sol`, change the `unpause()` function modifier from `onlyOwnerOrGuardian` to `onlyOwner`. Leave `pause()` as `onlyOwnerOrGuardian`. Do not remove the `onlyOwnerOrGuardian` modifier (still used by `pause()`). Update the NatSpec on `unpause()` to state it is owner-only.

- [ ] **Step 5: Run the governance tests**

```bash
cd contracts && forge test --match-contract P2Governance -vv 2>&1 | tail -15
```
Expected: all P2 governance tests pass — guardian-unpause reverts, owner-unpause succeeds, guardian-pause still works.

- [ ] **Step 6: Run the full suite**

```bash
cd contracts && forge test 2>&1 | tail -3
```
Expected: 127 tests passing, 0 failed (test count unchanged unless you added `test_owner_canUnpause`, in which case 128).

- [ ] **Step 7: Commit**

```bash
git add contracts/src/ArcoraDexPool.sol contracts/test/governance/P2Governance.t.sol
git commit -m "$(cat <<'EOF'
feat(contracts): unpause() is owner-only — pause/unpause asymmetry (A1)

The Pause Guardian Safe (2/3, lower trust) keeps fail-safe pause()
but can no longer unpause(). A compromised guardian must not be able
to un-protect a pool the owner deliberately paused during an incident.
unpause() is now onlyOwner (the governance Timelock); pause() remains
onlyOwnerOrGuardian.

Spec: docs/superpowers/specs/2026-05-18-phase4-audit-readiness-design.md A1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: A2 — Slither hygiene

**Files:**
- Modify: `contracts/src/ArcoraDexPool.sol` and any other `contracts/src` file Slither flags.

Goal: a Slither run produces no *unexplained* warnings — every remaining warning is either eliminated by a small refactor or carries an inline `slither-disable-next-line` justification an auditor can read.

- [ ] **Step 1: Capture the current Slither output**

```bash
cd contracts && slither . 2>&1 | tee /tmp/p4-slither-before.txt | tail -40
```
Read the full `/tmp/p4-slither-before.txt`. Enumerate every warning: detector name, file:line, and category. Ignore warnings in `contracts/test/` and `contracts/script/` and in `lib/` (out of audit scope) — focus only on `contracts/src`.

- [ ] **Step 2: Classify and handle each `contracts/src` warning**

For each warning in a `contracts/src` file:
- **If it is a genuine issue** (even minor) — fix it with a minimal, behaviour-preserving refactor.
- **If it is a benign false positive** (rounding that is intended, a call-in-loop that is bounded, reentrancy flagged on a `nonReentrant`-guarded or effect-before-interaction path) — add an inline comment directly above the flagged line:
  ```solidity
  // slither-disable-next-line <detector-id>
  // Justification: <one concrete sentence — why this is safe here>
  ```
  Use the exact detector id Slither prints (e.g. `divide-before-multiply`, `calls-loop`, `reentrancy-benign`).

Do NOT use a repo-wide `slither.config.json` filter or a blanket `// slither-disable-start` block — per-line justified disables only, so an auditor sees the reasoning at each site.

- [ ] **Step 3: Re-run Slither and confirm**

```bash
cd contracts && slither . 2>&1 | tee /tmp/p4-slither-after.txt | tail -40
```
Expected: every remaining `contracts/src` warning is one you added a justification for; no new warnings introduced. If a warning you intended to suppress still shows, the disable comment is misplaced (it must be the line immediately before the flagged line) or the detector id is wrong — fix it.

- [ ] **Step 4: Run the full suite — no behaviour change**

```bash
cd contracts && forge test 2>&1 | tail -3
```
Expected: same pass count as after Task 2, 0 failed. Any refactor in Step 2 must be behaviour-preserving.

- [ ] **Step 5: Commit**

```bash
git add contracts/src/
git commit -m "$(cat <<'EOF'
chore(contracts): resolve or justify all Slither warnings (A2)

Audit hygiene: every Slither warning in contracts/src is now either
eliminated by a minimal behaviour-preserving refactor or carries an
inline slither-disable-next-line with a one-sentence justification, so
the Spearbit auditors see no unexplained static-analysis noise. No
repo-wide filter is used — justifications are per-site.

Full test suite unchanged and green.

Spec: docs/superpowers/specs/2026-05-18-phase4-audit-readiness-design.md A2

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If Step 1 found that `contracts/src` already produces zero warnings, skip Steps 2–3, make no code change, and report DONE_WITH_CONCERNS noting "no Slither warnings to resolve" — do not invent changes.

---

### Task 4: A3 — `forge fmt` baseline

**Files:**
- Modify: any file under `contracts/src`, `contracts/test`, `contracts/script` that `forge fmt` reformats.

- [ ] **Step 1: Check the formatting delta**

```bash
cd contracts && forge fmt --check 2>&1 | tail -20
```
This lists files that are not formatting-clean. If it reports nothing, the codebase is already formatted — skip to Step 5 and report DONE_WITH_CONCERNS ("already fmt-clean, no baseline commit needed").

- [ ] **Step 2: Apply formatting**

```bash
cd contracts && forge fmt
```

- [ ] **Step 3: Confirm the suite is unaffected**

```bash
cd contracts && forge build 2>&1 | tail -3 && forge test 2>&1 | tail -3
```
Expected: clean build; same pass count as after Task 3, 0 failed. `forge fmt` is whitespace/layout only — zero behaviour change. If any test result changes, something is wrong — investigate before committing.

- [ ] **Step 4: Review the diff is formatting-only**

```bash
git diff --stat
```
Spot-check a couple of files with `git diff <file>` — confirm the changes are purely whitespace, line-wrapping, and punctuation layout. If any diff hunk changes an identifier, a literal, or logic, revert that file and investigate.

- [ ] **Step 5: Commit**

```bash
git add contracts/
git commit -m "$(cat <<'EOF'
style(contracts): forge fmt baseline (A3)

Apply `forge fmt` across contracts/src, contracts/test, contracts/script
so the audit commit and post-audit diffs are not polluted by style
noise. Formatting only — no logic change; full suite unchanged.

Spec: docs/superpowers/specs/2026-05-18-phase4-audit-readiness-design.md A3

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Doc — `docs/audit/audit-scope.md`

**Files:**
- Create: `docs/audit/audit-scope.md`

- [ ] **Step 1: Gather the facts**

Read these to source the document (do not guess — read the files):
- `contracts/src/ArcoraDexPool.sol`, `ArcoraDexLP.sol`, `ArcoraDexRegistry.sol`, `oracle/OracleAggregator.sol`, `oracle/CumulativeDeviationGuard.sol`, and the `contracts/src/interfaces/` they import.
- `contracts/foundry.toml` for the Solidity version / config.
- Run `cd contracts && cloc src/ArcoraDexPool.sol src/ArcoraDexLP.sol src/ArcoraDexRegistry.sol src/oracle/OracleAggregator.sol src/oracle/CumulativeDeviationGuard.sol 2>/dev/null || wc -l <those files>` for LoC.
- Run `cd contracts && forge test 2>&1 | tail -3` for the current test count.

- [ ] **Step 2: Write the document**

Create `docs/audit/audit-scope.md` with:
- **System overview** — 1 paragraph: oracle-priced multi-stablecoin vault, single shared LP token, NAV-based accounting, explicit `reserves[]` mapping (not `balanceOf`-derived), 7 stablecoins.
- **In scope** — a table of the 5 core contracts + the in-scope interfaces, each with its path and LoC.
- **Out of scope** — `contracts/src/testnet/` mocks (testnet-only, never mainnet), `contracts/script/` deploy scripts, OpenZeppelin (`TimelockController`, `Ownable2Step`, `ERC20`, etc.), Safe v1.4.1 — each with a one-line reason (upstream-audited / testnet-only / operational).
- **Frozen baseline** — the audit reviews the commit tagged `audit/spearbit-p4`; instruct the reader to run `git rev-parse audit/spearbit-p4` for the exact hash. Do NOT hardcode a commit hash (the tag is created after this branch merges — Task 11).
- **Build & test** — exact commands: `forge build`, `forge test`, `forge coverage --report summary`, and the current test count from Step 1.
- **Solidity / toolchain** — version 0.8.26, Foundry, the optimizer settings from `foundry.toml`.

- [ ] **Step 3: Commit**

```bash
git add docs/audit/audit-scope.md
git commit -m "docs(audit): audit scope document for Spearbit review

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Doc — `docs/audit/invariants.md`

**Files:**
- Create: `docs/audit/invariants.md`

- [ ] **Step 1: Source the invariants from code and tests**

Read `contracts/src/ArcoraDexPool.sol` (NAV accounting, `totalReservesUSD`, `reserves`, `protocolFeesAccrued`, fees), `ArcoraDexLP.sol` (`MINIMUM_LIQUIDITY` / virtual shares), and `contracts/test/ArcoraDexPool.invariant.t.sol` + `ArcoraDexPool.fuzz.t.sol` to see which invariants already have test coverage.

- [ ] **Step 2: Write the document**

Create `docs/audit/invariants.md`. For each invariant: a precise statement, a one-line rationale, and a pointer to the test(s) that exercise it (file + test name) or an explicit "no direct test — suggested target for Spearbit". Cover at least:
- `NAV ≥ 0`, monotonic with respect to in-flow (deposits + retained fees).
- `LP.totalSupply() ≥ MINIMUM_LIQUIDITY` once any deposit has occurred.
- `Σ (reserves[t] × price[t] / 10^decimals[t]) == totalReservesUSD()` — reserves are an explicit mapping, no `balanceOf` drift.
- `protocolFeesAccrued[t] ≤ reserves[t]` strictly.
- Oracle availability: a reverting or stale oracle never bricks deposit/withdraw (cache fallback in `_readOracle`).
- Aggregator bound: `OracleAggregator.latestRoundData()` never returns a price outside `[min, max]` of its live sources (it returns their average or reverts).

Use only invariants the code actually guarantees — verify each against the source before writing it. If a stated invariant is not actually enforced, either correct it or drop it.

- [ ] **Step 3: Commit**

```bash
git add docs/audit/invariants.md
git commit -m "docs(audit): protocol invariants document

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Doc — `docs/audit/threat-model.md`

**Files:**
- Create: `docs/audit/threat-model.md`

- [ ] **Step 1: Reconcile the finding list**

Read `docs/superpowers/specs/2026-05-12-audit-cleanup-design.md` and the P1/P2/P3 design docs (`2026-05-14-phase1-contract-fixes-design.md`, `2026-05-14-phase2-governance-design.md`, `2026-05-14-phase3-oracle-hardening-design.md`) and the roadmap §3–§5. Build the authoritative list of every security finding from the original review. The earlier docs record the count inconsistently — derive the actual list from these sources and state the real count; do not assert a number the sources do not support.

- [ ] **Step 2: Write the document**

Create `docs/audit/threat-model.md` with:
- A **findings table**: ID, title, severity, the phase that addressed it, and the contract/commit where the fix lives. One row per finding from Step 1.
- A **residual risk** section: risks that remain after P1–P3 — governance-multisig compromise (bounded by 3/5 + 48h Timelock), oracle-keeper compromise (reduced but not eliminated by P3 source diversity), permissionless `CumulativeDeviationGuard.record`. For each: the risk, why it remains, and the compensating control.
- A short **trust assumptions** section: who can do what (owner = governance Timelock, guardian = Pause Guardian Safe, oracle keepers, LPs, swappers).

Every claim must be checkable against the codebase — cite contract/function names.

- [ ] **Step 3: Commit**

```bash
git add docs/audit/threat-model.md
git commit -m "docs(audit): threat model — findings, fixes, residual risk

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Doc — `docs/audit/known-acceptable-risks.md`

**Files:**
- Create: `docs/audit/known-acceptable-risks.md`

- [ ] **Step 1: Write the document**

Create `docs/audit/known-acceptable-risks.md`. For each accepted risk: a statement, the rationale for accepting it for v1, and the compensating control. Cover at least:
- **Liquidity-thin freeze** — a near-empty pool can round small deposits to zero shares. Control: virtual shares + `MINIMUM_LIQUIDITY` (P1).
- **Centralized initial liquidity** — founding LP holds most of the supply at launch. Control: bootstrap/decentralization plan (P5).
- **Permissionless `CumulativeDeviationGuard.record`** — anyone can call it / anchor the window. Control: event-only, nothing on-chain gated on it; off-chain monitor re-validates against its own feed.
- **Tumbling (not rolling) deviation window** — slow cross-window drift is not detected. Control: MVP; rolling detector is P5.
- **Governance-multisig compromise** — a 3/5 Safe compromise. Control: 48h Timelock delay on all owner actions; Pause Guardian can still pause.
- **Pre-bug-bounty exposure window** — no Immunefi program at launch. Control: Immunefi launch scheduled in P5.

Source the controls from the actual P1–P3 implementation — verify each before writing it.

- [ ] **Step 2: Commit**

```bash
git add docs/audit/known-acceptable-risks.md
git commit -m "docs(audit): known acceptable risks for v1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Doc — `docs/audit/architecture.md`

**Files:**
- Create: `docs/audit/architecture.md`

- [ ] **Step 1: Source the topology**

Read the P2 and P3 rollout docs (`docs/rollouts/2026-05-14-phase2-governance.md`, `docs/rollouts/2026-05-14-phase3-oracle.md`) for the live deployment topology and governance addresses, and the core contracts for the on-chain relationships.

- [ ] **Step 2: Write the document**

Create `docs/audit/architecture.md` with:
- **Contract topology** — Registry → Pool → LP; the 7 stablecoins; the 7 `OracleAggregator`s each over 2 feeds; the `CumulativeDeviationGuard`. An ASCII or Mermaid diagram.
- **Governance stack** — Governance Safe 3/5 → `TimelockController` (48h delay) owns Pool + Registry; Pause Guardian Safe 2/3 holds the guardian role; what each can do and the delay that applies.
- **Oracle layer** — per-token 2-source aggregator consumed by the Registry; the Pool reads via `IChainlinkAggregator`; the `_readOracle` try/catch + `lastValidPrice` cache fallback; the deviation/divergence/cumulative caps and what each measures (reuse the three-caps explanation from the P3 rollout doc).
- **Data flow** — a deposit and a swap traced through Pool → Registry → aggregator → underlying feeds.

- [ ] **Step 3: Commit**

```bash
git add docs/audit/architecture.md
git commit -m "docs(audit): architecture — topology, governance, oracle layer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Doc — `docs/audit/p5-tracking.md`

**Files:**
- Create: `docs/audit/p5-tracking.md`

- [ ] **Step 1: Collect every deferred item**

Read the "Tracking for P5" / "Out of scope" / "downstream tasks" sections of: the roadmap §6–§7 and §10, the P1/P2/P3 design docs, and the P2/P3 rollout docs. Also include the items the P4 spec explicitly defers (`docs/superpowers/specs/2026-05-18-phase4-audit-readiness-design.md` §3 "Deliberately out of scope for Part A").

- [ ] **Step 2: Write the document**

Create `docs/audit/p5-tracking.md` — a single consolidated register. A table with columns: **Item**, **Origin** (which review/phase/doc raised it), **Why deferred**, **Target phase**. Include at minimum: on-chain auto-pause wired to the guard; keeper-only `record`; rolling (vs tumbling) deviation window; independent HW-wallet signer keys; fee-collector multisig separation; frontend `pnpm audit` cleanup (finding #5); SDK full-suite test hang; any Slither items deferred rather than fixed in Task 3; Pyth / secondary mainnet feed sourcing for exotic FX; pause/unpause already done in P4 (mark as DONE for traceability or omit). Do not invent items — every row must trace to a source doc or a P1–P4 review.

- [ ] **Step 3: Commit**

```bash
git add docs/audit/p5-tracking.md
git commit -m "docs(audit): consolidated P5 deferred-work register

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Final checks and freeze

**Files:** none modified (tagging happens post-merge).

- [ ] **Step 1: Full suite + build**

```bash
cd contracts && forge build 2>&1 | tail -3 && forge test 2>&1 | tail -3
```
Expected: clean build; 127 (or 128 if Task 2 added `test_owner_canUnpause`) tests passing, 0 failed.

- [ ] **Step 2: Confirm the audit pack is complete**

```bash
ls docs/audit/
```
Expected: exactly the 6 files — `audit-scope.md`, `invariants.md`, `threat-model.md`, `known-acceptable-risks.md`, `architecture.md`, `p5-tracking.md`.

- [ ] **Step 3: Branch summary**

```bash
git log --oneline main..HEAD
git diff main --stat
```
Expected: ~9 commits (Task 2 + Task 3 + Task 4 + Tasks 5–10). Task 3 and Task 4 may be skipped if there was nothing to do (DONE_WITH_CONCERNS) — that is acceptable; note it.

- [ ] **Step 4: Slither final check**

```bash
cd contracts && slither . 2>&1 | tail -15
```
Expected: every `contracts/src` warning is justified inline (from Task 3). No new HIGH/MEDIUM.

- [ ] **Step 5: STOP — hand back to the controller for PR + merge + tag**

This plan does not push, open the PR, or create the tag. The controller:
1. opens the implementation PR and merges it to `main`;
2. tags the merge commit `audit/spearbit-p4` and pushes the tag;
3. confirms `git rev-parse audit/spearbit-p4` resolves — this is the hash auditors use with `docs/audit/audit-scope.md`.

---

## Rollback

Each task is its own commit. `git revert <sha>` cleanly undoes any single change:
- **A1** — reverting restores `unpause()` to `onlyOwnerOrGuardian`. No on-chain effect (Pool not redeployed in P4).
- **A2 / A3** — reverting restores the prior Slither comments / formatting. No behaviour change either way.
- **Docs (Tasks 5–10)** — reverting removes the doc file; no code impact.

For a planning-stage rollback (before the implementation PR merges), discard the local branch — `main` stays at the post-P3 state.
