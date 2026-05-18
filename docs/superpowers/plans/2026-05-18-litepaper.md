# ArcoraDEX Litepaper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce the ArcoraDEX technical litepaper — a Markdown source of truth and a generated, self-contained styled HTML rendering that prints cleanly to PDF.

**Architecture:** A single Markdown file (`arcoradex-litepaper.md`) is authored section-group by section-group, each chunk accuracy-reviewed against the contracts and the `docs/audit/` pack. A small Node build script (`build.mjs`, using the `marked` library) converts the Markdown into one self-contained HTML file with embedded CSS and a print stylesheet. The HTML is a committed, generated artifact — never hand-edited.

**Tech Stack:** Markdown, Node.js (ESM), the `marked` npm package, HTML/CSS.

**Spec:** `docs/superpowers/specs/2026-05-18-litepaper-design.md`

---

## File Structure

### Files created
| File | Purpose |
|------|---------|
| `docs/litepaper/arcoradex-litepaper.md` | The litepaper — source of truth, 10 sections |
| `docs/litepaper/build.mjs` | Node build script: Markdown → styled self-contained HTML |
| `docs/litepaper/package.json` | Declares the one build dependency (`marked`) |
| `docs/litepaper/.gitignore` | Ignores `node_modules/` |
| `docs/litepaper/arcoradex-litepaper.html` | Generated self-contained HTML (committed deliverable) |
| `docs/litepaper/README.md` | How to regenerate the HTML and produce a PDF |

### Branches
- `docs/litepaper` (already exists with the spec; this plan is committed here)
- After the planning PR merges, implementation proceeds on `docs/litepaper-impl`

### Source material (read-only — the litepaper is sourced from these)
- `contracts/src/ArcoraDexPool.sol`, `ArcoraDexLP.sol`, `ArcoraDexRegistry.sol`, `oracle/OracleAggregator.sol`, `oracle/CumulativeDeviationGuard.sol`
- `docs/audit/audit-scope.md`, `invariants.md`, `threat-model.md`, `known-acceptable-risks.md`, `architecture.md`, `p5-tracking.md`
- `docs/rollouts/2026-05-14-phase2-governance.md`, `docs/rollouts/2026-05-14-phase3-oracle.md`
- `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md`

---

### Task 1: Branch setup and litepaper scaffold

**Files:**
- Create: `docs/litepaper/arcoradex-litepaper.md`

- [ ] **Step 1: Confirm the planning PR merged to main**

```bash
git checkout main && git pull --ff-only origin main
git log -1 --format='%h %s'
```
Expected: HEAD is the litepaper planning merge.

- [ ] **Step 2: Create the implementation branch**

```bash
git checkout -b docs/litepaper-impl
```

- [ ] **Step 3: Create the litepaper Markdown scaffold**

Create `docs/litepaper/arcoradex-litepaper.md` with the title block and the 10 section headers, each followed by a single HTML-comment placeholder line marking where that section's content goes. This locks the structure so later tasks slot content in without renumbering.

```markdown
# ArcoraDEX — Technical Litepaper

**Version:** draft — Phase 4 (pre-audit)
**Date:** 2026-05-18
**Status:** ArcoraDEX is deployed on the Arc testnet (chainId 5042002) and is undergoing a Spearbit private security review ahead of mainnet. This document describes the protocol as of the `audit/spearbit-p4` baseline.

---

## 1. Abstract

<!-- section 1 content — Task 2 -->

## 2. Protocol Overview

<!-- section 2 content — Task 2 -->

## 3. Mechanism Design

<!-- section 3 content — Task 2 -->

## 4. Oracle Architecture

<!-- section 4 content — Task 3 -->

## 5. Security Model

<!-- section 5 content — Task 3 -->

## 6. Governance & Operations

<!-- section 6 content — Task 4 -->

## 7. Risk Disclosures

<!-- section 7 content — Task 4 -->

## 8. Audit & Roadmap

<!-- section 8 content — Task 5 -->

## 9. Parameters & Addresses

<!-- section 9 content — Task 5 -->

## 10. References

<!-- section 10 content — Task 5 -->
```

- [ ] **Step 4: Commit**

```bash
git add docs/litepaper/arcoradex-litepaper.md
git commit -m "$(cat <<'EOF'
docs(litepaper): scaffold — title block + 10-section skeleton

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Sections 1–3 — Abstract, Protocol Overview, Mechanism Design

**Files:**
- Modify: `docs/litepaper/arcoradex-litepaper.md`

Replace the `<!-- section 1/2/3 content -->` placeholders with the written sections. Read the source material first: `contracts/src/ArcoraDexPool.sol` (deposit / withdraw / swap / fee logic), `ArcoraDexLP.sol`, `ArcoraDexRegistry.sol`, and `docs/audit/architecture.md` (for the verified mechanism descriptions and data flows).

- [ ] **Step 1: Write Section 1 — Abstract**

2–4 paragraphs. ArcoraDEX is an oracle-priced, multi-stablecoin vault AMM. The problem: swapping between pegged stablecoins on a constant-product AMM incurs slippage and fragments liquidity across many pairs. ArcoraDEX prices swaps from external oracles and holds a single shared liquidity pool spanning 7 stablecoins, so an LP provides liquidity once and every pair is served from the same reserves. State plainly that it is pre-mainnet and under audit.

- [ ] **Step 2: Write Section 2 — Protocol Overview**

The vault model. The 7 listed stablecoins (USDC, USDT, PYUSD, DAI, EURC, TRYC, BRLC). A single shared LP token (`ArcoraDexLP`). NAV (net asset value) accounting: the pool's value is the USD sum of its reserves; LP shares are claims on NAV. Reserves are held in an explicit `reserves[]` mapping, updated on every deposit/withdraw/swap — NOT derived from `token.balanceOf(pool)` — which makes the pool immune to balance-donation manipulation. The Registry holds per-token configuration (decimals, oracle pointer, deviation cap, staleness bound). Verify the contract and mapping names against the source before writing.

- [ ] **Step 3: Write Section 3 — Mechanism Design**

Four subsections, each citing the governing contract function (verify names/behaviour against `ArcoraDexPool.sol`):
- **Oracle pricing vs. constant-product** — why a stablecoin vault prices from oracles instead of an `x*y=k` curve; the trade-off (oracle dependence, addressed in §4–§5).
- **Deposits & LP shares** — `deposit()`: the deposited token is valued in USD via its oracle, LP shares are minted proportional to the NAV increase, using the virtual-shares offset (introduced in §5). The first deposit burns `MINIMUM_LIQUIDITY` to a dead address.
- **Swaps** — `swap()`: both legs priced by oracle; the swap fee is taken; output is reserve-checked.
- **Withdrawals** — `withdraw()`: LP shares burned for a proportional share of a chosen token's reserves; the LP min-hold applies (introduced in §5).
- **Fee model** — a per-swap fee in basis points; the protocol retains a configurable share of it, the rest accrues to LPs as NAV growth. State the fee-cap constants (`MAX_SWAP_FEE_BPS`, `MAX_PROTOCOL_FEE_SHARE_BPS`) — read the real values.

- [ ] **Step 4: Verify factual accuracy**

Re-read your three sections against the contracts. Every constant, function name, and mechanism claim must match the source. Fix anything that does not.

- [ ] **Step 5: Commit**

```bash
git add docs/litepaper/arcoradex-litepaper.md
git commit -m "$(cat <<'EOF'
docs(litepaper): sections 1-3 — abstract, overview, mechanism design

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Sections 4–5 — Oracle Architecture, Security Model

**Files:**
- Modify: `docs/litepaper/arcoradex-litepaper.md`

Replace the `<!-- section 4/5 content -->` placeholders. Source material: `contracts/src/oracle/OracleAggregator.sol`, `oracle/CumulativeDeviationGuard.sol`, the oracle-read path in `ArcoraDexPool.sol` (`_readOracle`, `_readUsdPrice1e18Mut`, `_readUsdPrice1e18WithGuard`, `_readAndGuardPrice`), `docs/audit/architecture.md` §3, `docs/audit/threat-model.md`, `docs/audit/invariants.md`.

- [ ] **Step 1: Write Section 4 — Oracle Architecture**

Cover, verifying each against the code:
- The per-token 2-source `OracleAggregator` — returns the average of two feeds when they agree within `maxDivergenceBps`; falls back to the surviving source when one reverts/returns a bad round; reverts `SourcesDiverge` on full divergence and `AllSourcesUnavailable` when both fail. Note `sourceHealth()` as the monitoring hook.
- The Pool's `_readOracle` try/catch + `lastValidPrice` cache fallback — a reverting or stale oracle never bricks deposits/withdrawals.
- The `lastAcceptedPrice` per-operation ratchet — limits how far the accepted price can move per call.
- The `CumulativeDeviationGuard` — event-only tumbling-window deviation tracker for off-chain monitoring; no on-chain auto-pause.
- The three distinct deviation controls and what each measures (aggregator `maxDivergenceBps` = primary-vs-secondary spread; Registry `maxOracleDeviationBps` = aggregator-output vs cached/last-accepted price; guard `maxCumulativeBps` = rolling-window observability). Be precise — this is the most error-prone section.

- [ ] **Step 2: Write Section 5 — Security Model**

Two parts, sourced from `docs/audit/threat-model.md`:
- **Economic-attack defenses** — the virtual-shares offset against the first-depositor inflation attack (explain the attack and why `VIRTUAL_SHARES`/`VIRTUAL_ASSETS` + `MINIMUM_LIQUIDITY` neutralize it); the 1-hour LP min-hold (`MIN_HOLD_SECONDS`) plus the `ArcoraDexLP._update` → `notifyLPTransfer` transfer hook against JIT/MEV sandwiching (explain that the hook propagates the hold to a transfer recipient, closing the transfer-to-fresh-wallet bypass).
- **Oracle defenses** — staleness bounds, deviation caps, source diversity, revert tolerance (cross-reference §4).
Frame these as the defenses the P1–P3 hardening program put in place; do not claim the protocol is "unhackable" — describe the specific mitigations and let §7 carry the residual risks.

- [ ] **Step 3: Verify factual accuracy**

Re-read §4–§5 against the contracts and the audit pack. The three-deviation-controls description and the inflation-attack / JIT-attack mechanics are the highest-risk claims — verify them precisely.

- [ ] **Step 4: Commit**

```bash
git add docs/litepaper/arcoradex-litepaper.md
git commit -m "$(cat <<'EOF'
docs(litepaper): sections 4-5 — oracle architecture, security model

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Sections 6–7 — Governance & Operations, Risk Disclosures

**Files:**
- Modify: `docs/litepaper/arcoradex-litepaper.md`

Replace the `<!-- section 6/7 content -->` placeholders. Source material: `docs/audit/architecture.md` §2, `docs/audit/known-acceptable-risks.md`, `docs/rollouts/2026-05-14-phase2-governance.md`, the access-control modifiers in `ArcoraDexPool.sol` and `ArcoraDexRegistry.sol`.

- [ ] **Step 1: Write Section 6 — Governance & Operations**

- The ownership model: the Governance Safe (3/5 multisig) acts through an OpenZeppelin `TimelockController` with a 48-hour delay; the Timelock owns the Pool and the Registry. All owner actions (fee changes, listing tokens, setting oracles/deviation caps, withdrawing protocol fees, unpausing) therefore carry the 48-hour delay.
- The Pause Guardian Safe (2/3 multisig) holds the `pauseGuardian` role: it can `pause()` the pool instantly (fail-safe). The pause/unpause **asymmetry**: `unpause()` is owner-only — a compromised guardian cannot un-protect a deliberately-paused pool.
- The parameter-change process and the emergency-pause path.
Verify the modifiers (`onlyOwner` vs `onlyOwnerOrGuardian`) against the source.

- [ ] **Step 2: Write Section 7 — Risk Disclosures**

Sourced directly from `docs/audit/known-acceptable-risks.md`. Disclose, honestly and without minimizing: oracle dependence (the protocol's correctness rests on the feeds); liquidity-thin behaviour at very low TVL; governance-trust assumptions (a 3/5 Safe compromise, bounded by the 48-hour Timelock); the permissionless `CumulativeDeviationGuard.record`; the pre-bug-bounty exposure window. Each as: the risk, why it is accepted for v1, the compensating control.

- [ ] **Step 3: Verify factual accuracy**

Re-read §6–§7. The governance roles/delays and the risk list must match the audit pack and the contract modifiers. Fix any drift.

- [ ] **Step 4: Commit**

```bash
git add docs/litepaper/arcoradex-litepaper.md
git commit -m "$(cat <<'EOF'
docs(litepaper): sections 6-7 — governance & operations, risk disclosures

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Sections 8–10 — Audit & Roadmap, Parameters & Addresses, References

**Files:**
- Modify: `docs/litepaper/arcoradex-litepaper.md`

Replace the `<!-- section 8/9/10 content -->` placeholders. Source material: `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md`, `docs/audit/p5-tracking.md`, `docs/audit/audit-scope.md`, `docs/rollouts/2026-05-14-phase2-governance.md` and `2026-05-14-phase3-oracle.md` (for addresses), and the contract constants.

- [ ] **Step 1: Write Section 8 — Audit & Roadmap**

A concise summary of the P1–P4 mainnet-readiness program: P1 contract fixes, P2 governance migration, P3 oracle hardening, P4 audit readiness. State that a Spearbit private review is underway/pending against the `audit/spearbit-p4` baseline. Then the forward look: P5 mainnet deployment and operations, and the deferred future work (rolling-window deviation detection, on-chain auto-pause, additional independent feeds, fee-collector separation) — sourced from `docs/audit/p5-tracking.md`.

- [ ] **Step 2: Write Section 9 — Parameters & Addresses**

Two tables, all values read from the actual source:
- **Key parameters** — `VIRTUAL_SHARES`, `VIRTUAL_ASSETS`, `MINIMUM_LIQUIDITY`, `MIN_HOLD_SECONDS`, `MAX_SWAP_FEE_BPS`, `MAX_PROTOCOL_FEE_SHARE_BPS`, the Timelock delay (48h), and the per-token deviation/divergence caps (cite the per-tier values from the P3 rollout doc). Each row: name, value, meaning.
- **Arc testnet deployment addresses** — Pool, Registry, LP, Governance Safe, TimelockController, Pause Guardian Safe, and the 7 aggregators (from the P2/P3 rollout docs). Add an explicit note: these are Arc testnet (chainId 5042002) addresses; mainnet addresses will differ and will be published at the P5 deployment.

- [ ] **Step 3: Write Section 10 — References**

A list of pointers: the mainnet-readiness roadmap, the `docs/audit/` pack (all six documents), the rollout docs, and the external standards relied on — the Chainlink `AggregatorV3`-shape interface, OpenZeppelin (`Ownable2Step`, `TimelockController`, `ERC20`, `ReentrancyGuard`), Safe v1.4.1. Use relative repo paths for internal docs.

- [ ] **Step 4: Verify factual accuracy**

Re-read §8–§10. Every parameter value and every address must match the source docs/contracts exactly. This section is pure facts — zero tolerance for a wrong number or address.

- [ ] **Step 5: Commit**

```bash
git add docs/litepaper/arcoradex-litepaper.md
git commit -m "$(cat <<'EOF'
docs(litepaper): sections 8-10 — roadmap, parameters & addresses, references

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: HTML build script

**Files:**
- Create: `docs/litepaper/package.json`
- Create: `docs/litepaper/.gitignore`
- Create: `docs/litepaper/build.mjs`
- Create: `docs/litepaper/README.md`

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "arcoradex-litepaper",
  "private": true,
  "type": "module",
  "description": "Build script for the ArcoraDEX litepaper HTML rendering.",
  "scripts": {
    "build": "node build.mjs"
  },
  "dependencies": {
    "marked": "^14.1.0"
  }
}
```

- [ ] **Step 2: Create `.gitignore`**

```
node_modules/
```

- [ ] **Step 3: Create `build.mjs`**

Create `docs/litepaper/build.mjs`. It reads `arcoradex-litepaper.md`, converts it to HTML with `marked`, wraps it in a self-contained HTML template with embedded CSS (screen + print styles), and writes `arcoradex-litepaper.html`.

```javascript
// Builds the self-contained HTML rendering of the ArcoraDEX litepaper.
// Usage: npm install && node build.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { marked } from 'marked';

const here = dirname(fileURLToPath(import.meta.url));
const mdPath = join(here, 'arcoradex-litepaper.md');
const htmlPath = join(here, 'arcoradex-litepaper.html');

const md = readFileSync(mdPath, 'utf8');
const body = marked.parse(md, { mangle: false, headerIds: true });

const css = `
  :root { color-scheme: light; }
  body {
    font-family: Georgia, "Times New Roman", serif;
    line-height: 1.6; color: #1a1a1a; background: #ffffff;
    max-width: 820px; margin: 0 auto; padding: 56px 32px;
  }
  h1, h2, h3 { font-family: -apple-system, Segoe UI, Roboto, sans-serif; line-height: 1.25; }
  h1 { font-size: 2rem; border-bottom: 2px solid #1a1a1a; padding-bottom: .3em; }
  h2 { font-size: 1.4rem; margin-top: 2.4em; border-bottom: 1px solid #ccc; padding-bottom: .2em; }
  h3 { font-size: 1.12rem; margin-top: 1.6em; }
  code { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: .88em;
    background: #f3f3f3; padding: .1em .35em; border-radius: 3px; }
  pre { background: #f6f8fa; padding: 14px 16px; border-radius: 6px; overflow-x: auto; }
  pre code { background: none; padding: 0; }
  table { border-collapse: collapse; width: 100%; margin: 1.2em 0; font-size: .92rem;
    font-family: -apple-system, Segoe UI, Roboto, sans-serif; }
  th, td { border: 1px solid #d0d0d0; padding: 7px 10px; text-align: left; }
  th { background: #f3f3f3; }
  blockquote { border-left: 3px solid #bbb; margin: 1em 0; padding: .2em 1em; color: #444; }
  a { color: #0b5fa5; }
  hr { border: none; border-top: 1px solid #ddd; margin: 2em 0; }
  @media print {
    body { max-width: none; padding: 0; font-size: 11pt; }
    h1, h2 { page-break-after: avoid; }
    h3 { page-break-after: avoid; }
    pre, table, blockquote { page-break-inside: avoid; }
    a { color: #1a1a1a; text-decoration: none; }
  }
`;

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ArcoraDEX — Technical Litepaper</title>
<style>${css}</style>
</head>
<body>
${body}
</body>
</html>
`;

writeFileSync(htmlPath, html);
console.log('wrote', htmlPath, `(${html.length} bytes)`);
```

If the installed `marked` version rejects the `{ mangle: false, headerIds: true }` options object (the option set changed across `marked` major versions), adapt the call to whatever the installed version accepts — `marked.parse(md)` with no options is an acceptable fallback. The goal is correct HTML output; the options are cosmetic.

- [ ] **Step 4: Install and run the build**

```bash
cd docs/litepaper && npm install 2>&1 | tail -3 && node build.mjs
```
Expected: `npm install` succeeds; `build.mjs` prints `wrote .../arcoradex-litepaper.html`.

If `npm` or `node` is unavailable in the environment, report BLOCKED so the controller can advise — do not fake the artifact.

- [ ] **Step 5: Sanity-check the HTML**

```bash
head -c 200 docs/litepaper/arcoradex-litepaper.html
grep -c "<h2" docs/litepaper/arcoradex-litepaper.html
```
Expected: the file starts with `<!doctype html>`; the `<h2` count is 10 (one per section).

- [ ] **Step 6: Create `README.md`**

Create `docs/litepaper/README.md`:

```markdown
# ArcoraDEX Litepaper

`arcoradex-litepaper.md` is the source of truth. `arcoradex-litepaper.html`
is a generated, self-contained rendering — **do not edit it by hand**.

## Regenerate the HTML

```bash
cd docs/litepaper
npm install
node build.mjs
```

## Produce a PDF

Open `arcoradex-litepaper.html` in a browser and use **Print → Save as PDF**.
The stylesheet includes print rules (sensible page breaks, no orphaned
headings).
```

- [ ] **Step 7: Commit**

```bash
git add docs/litepaper/package.json docs/litepaper/package-lock.json docs/litepaper/.gitignore docs/litepaper/build.mjs docs/litepaper/README.md docs/litepaper/arcoradex-litepaper.html
git commit -m "$(cat <<'EOF'
docs(litepaper): HTML build script + generated rendering

build.mjs converts the Markdown source to a self-contained styled
HTML file (embedded CSS, print stylesheet) via the `marked` library.
The HTML is a committed generated artifact; node_modules is ignored.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Final review and consistency pass

**Files:**
- Possibly modify: `docs/litepaper/arcoradex-litepaper.md` (+ regenerate HTML)

- [ ] **Step 1: Read the full litepaper end to end**

Read `docs/litepaper/arcoradex-litepaper.md` start to finish. Check: consistent voice and tense across the section groups (they were authored by separate tasks); no contradictions between sections; every cross-reference ("see §4") points to the right section; the abstract's claims are all substantiated by later sections.

- [ ] **Step 2: Final factual spot-check**

Pick 10 concrete claims spread across the document (constants, contract names, addresses, governance delays) and verify each against `contracts/src/` or the `docs/audit/` pack. Fix any inaccuracy.

- [ ] **Step 3: Regenerate the HTML if the Markdown changed**

```bash
cd docs/litepaper && node build.mjs
```
Only needed if Step 1 or 2 edited the Markdown. If edited, re-run and confirm the `<h2` count is still 10.

- [ ] **Step 4: Commit (only if changes were made)**

```bash
git add docs/litepaper/arcoradex-litepaper.md docs/litepaper/arcoradex-litepaper.html
git commit -m "$(cat <<'EOF'
docs(litepaper): final consistency and accuracy pass

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If Step 1–2 found nothing to change, make no commit and report that the litepaper passed the final pass clean.

- [ ] **Step 5: STOP — hand back to the controller**

The controller opens the implementation PR and merges it.

---

## Rollback

Each task is its own commit. The litepaper is documentation only — no contract code is touched, so reverting any commit has zero on-chain or build-system impact. To discard the whole effort before merge, delete the `docs/litepaper-impl` branch; `main` is unaffected.
