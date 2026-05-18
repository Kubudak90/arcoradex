# ArcoraDEX Litepaper — Design

**Date:** 2026-05-18
**Branch:** `docs/litepaper`
**Status:** design — awaiting implementation plan

## 1. Goal

Produce a detailed technical litepaper for ArcoraDEX: a versionable Markdown
source plus a self-contained styled HTML rendering that prints cleanly to PDF.
The document targets developers, auditors, and sophisticated liquidity
providers — it is a technical reference, not marketing material. Every factual
claim is sourced from the actual contracts and the `docs/audit/` pack so the
litepaper cannot drift from or overclaim the implementation.

## 2. Deliverable

A new `docs/litepaper/` directory containing:

| File | Purpose |
|------|---------|
| `arcoradex-litepaper.md` | Source of truth — the full litepaper in Markdown, reviewable in git like the audit docs. |
| `arcoradex-litepaper.html` | Self-contained single-file HTML: embedded CSS, a print stylesheet, inline diagrams. Renders in a browser and prints to PDF without a LaTeX toolchain. **Generated** from the Markdown — never hand-edited. |
| `build.mjs` | Node build script: reads the Markdown, converts it to HTML, wraps it in the styled template, writes `arcoradex-litepaper.html`. So the two files never drift. |
| `README.md` | One short page: how to regenerate the HTML (`node build.mjs`), how to produce a PDF (browser "Print → Save as PDF"). |

**HTML generation approach.** The build script converts Markdown → HTML using a
standalone, dependency-light converter. Preference order, resolved at
implementation time: (a) a pinned npm Markdown library (`marked` or
`markdown-it`) if a Node package context is acceptable; (b) `pandoc`'s
HTML-only mode if pandoc is already available. The plan picks one concretely
after checking the environment. Either way: no LaTeX, single output file, CSS
embedded.

**Styling.** Clean technical-document styling: readable serif or system font,
generous margins, styled tables and code blocks, a print stylesheet that
paginates sensibly (page breaks before `h1`/`h2`, no orphaned headings). The
CSS lives inside `build.mjs` as the HTML template — there is no separate CSS
file to keep in sync.

## 3. Litepaper structure (10 sections)

1. **Abstract** — ArcoraDEX is an oracle-priced, multi-stablecoin vault AMM.
   The problem: capital-efficient swaps among pegged stablecoins without the
   slippage and fragmented liquidity of constant-product pools. The approach: a
   single shared liquidity pool across 7 stablecoins, priced by external
   oracles, with NAV-based LP accounting.

2. **Protocol overview** — the vault model: the 7 listed stablecoins
   (USDC, USDT, PYUSD, DAI, EURC, TRYC, BRLC); a single shared LP token; NAV
   (net asset value) accounting; reserves held in an explicit `reserves[]`
   mapping rather than derived from `balanceOf` (donation-resistant).

3. **Mechanism design** — oracle pricing contrasted with constant-product
   AMMs; deposits and NAV-proportional LP-share minting; oracle-priced swaps;
   withdrawals and redemption; the fee model (per-swap fee + the protocol's
   share of it). Each subsection cites the governing contract function.

4. **Oracle architecture** — the per-token 2-source `OracleAggregator`
   (average within a divergence cap, single-source fallback, revert on full
   divergence); the Pool's `_readOracle` try/catch and `lastValidPrice` cache
   fallback; the `lastAcceptedPrice` per-operation ratchet; the
   `CumulativeDeviationGuard` event-only circuit breaker; the three distinct
   deviation controls and what each measures.

5. **Security model** — the economic-attack defenses: virtual-shares offset
   against the first-depositor inflation attack; the 1-hour LP min-hold plus
   the transfer hook against JIT/MEV sandwiching. The oracle defenses:
   staleness bounds, deviation caps, source diversity, revert tolerance. Maps
   to the findings the P1–P3 hardening closed.

6. **Governance & operations** — ownership: the Governance Safe (3/5) behind
   an OpenZeppelin `TimelockController` (48 h delay) owns the Pool and
   Registry; the Pause Guardian Safe (2/3) holds the guardian role. The
   pause/unpause asymmetry (guardian may pause, only the owner may unpause).
   The parameter-change process and the emergency-pause path.

7. **Risk disclosures** — the knowingly-accepted risks: oracle dependence,
   liquidity-thin behavior at very low TVL, governance-trust assumptions,
   the pre-bug-bounty window. Sourced directly from
   `docs/audit/known-acceptable-risks.md` — honest, not minimized.

8. **Audit & roadmap** — a summary of the P1–P4 hardening program, the
   Spearbit private review, the planned P5 mainnet deployment, and future work
   (rolling-window deviation detection, on-chain auto-pause, additional
   independent feeds, fee-collector separation).

9. **Parameters & addresses** — a table of the key on-chain constants
   (virtual-shares offset, `MINIMUM_LIQUIDITY`, min-hold duration, fee caps,
   per-token deviation/divergence caps, Timelock delay) and the current Arc
   testnet deployment addresses, with an explicit note that these are testnet
   values pending the mainnet deployment.

10. **References** — pointers to the specs, the `docs/audit/` pack, and the
    external standards relied on (Chainlink aggregator interface, OpenZeppelin
    `Ownable2Step` / `TimelockController` / `ERC20`, Safe v1.4.1).

## 4. Accuracy constraints

- Every numeric constant, contract name, and mechanism description is verified
  against `contracts/src/` and the `docs/audit/` documents at authoring time.
- The litepaper does not assert security properties beyond what the audit pack
  states; where the audit pack flags a residual risk or an accepted risk, the
  litepaper discloses it.
- The litepaper states plainly that the protocol is pre-audit / pre-mainnet at
  the time of writing and that the Spearbit review is in progress or pending.
- No token, tokenomics, fundraising, or yield-projection content — none exists
  in the protocol and none will be invented. (An LP earns the retained share
  of swap fees; that is the only yield mechanism and it is described factually.)

## 5. Out of scope

- Actual PDF binary generation via a LaTeX toolchain (the HTML print path
  covers PDF; producing the binary is a manual browser step).
- Marketing copy, branding, logos, or visual identity work.
- Translating the litepaper into other languages.
- Any contract code change — this phase only reads the contracts.

## 6. Execution approach

Subagent-driven development, consistent with the P1–P4 phases: a sonnet
implementer drafts each unit, a sonnet reviewer checks factual accuracy against
the contracts and audit pack, an opus reviewer checks writing quality and
overall coherence. The Markdown is authored first and reviewed for accuracy;
the `build.mjs` + HTML generation is a separate task; a final task verifies the
generated HTML renders and the numbers match the Markdown.
