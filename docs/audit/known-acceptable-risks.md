# ArcoraDEX — Known Acceptable Risks (v1)

**Date:** 2026-05-18
**Branch at authoring:** `phase4/audit-rollout`
**Audience:** Spearbit auditors

---

## Introduction

This document records the risks that the ArcoraDEX team has reviewed and
consciously accepts for the v1 mainnet launch. The purpose is twofold: to give
Spearbit auditors an honest picture of deliberate design boundaries so they can
direct effort at unacknowledged exposures, and to put each acceptance decision on
record before any capital is deployed.

For each risk the document states: (a) a precise statement of what the risk is,
(b) why it is being accepted for v1 rather than fixed, and (c) the compensating
control that bounds its impact. Every claim about code is verified against the
contract source; every claim about governance is verified against the deployment
scripts and the governance design spec
(`docs/superpowers/specs/2026-05-14-phase2-governance-design.md`).

---

## R1 — Liquidity-thin freeze and rounding

**Risk.** When the pool has very low total NAV, the LP minting formula can round
small deposits to zero shares. Specifically, if `usdIn` is small relative to the
current NAV-to-supply ratio, `lpMinted` truncates to zero in integer arithmetic,
and the depositor's tokens are accepted but zero LP is issued. A near-empty pool
is therefore a poor experience for small follow-on depositors and can, in
pathological cases, lock trivially small token amounts.

**Why accepted for v1.** The virtual-offset pattern (ERC4626-style) was applied in
P1 as a direct fix to finding #A (first-depositor inflation attack, CRITICAL). That
fix also addresses the rounding concern as a side-effect. The residual risk is
confined to extreme edge cases where `usdIn` is below a few wei of USD value —
economically negligible for any real depositor. Fully eliminating rounding in
fixed-point math would require a different accounting model; the virtual-offset is
the industry-standard mitigation.

**Compensating controls.**

- `VIRTUAL_SHARES = 1e6` and `VIRTUAL_ASSETS = 1` are added to the LP mint
  formula in `ArcoraDexPool.sol` (lines 37–38). The minting expression is
  `lpMinted = (usdIn * (supply + VIRTUAL_SHARES)) / (navBefore + VIRTUAL_ASSETS)`
  (line 390), and the symmetric redemption is
  `usdRedeemed = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (LP.totalSupply() + VIRTUAL_SHARES)`
  (line 427). With `VIRTUAL_SHARES = 1e6`, any deposit where `usdIn >= 1` is
  guaranteed to mint at least one LP unit, eliminating zero-share rounding for any
  economically meaningful deposit.
- `MINIMUM_LIQUIDITY = 1000` (line 24) is burned to `DEAD_ADDRESS` (line 400) on
  the very first deposit. This permanently seeds the supply denominator, preventing
  a first depositor from driving LP supply to zero even via the donation-inflation
  class of attack. Combined with `VIRTUAL_SHARES`, an attacker cannot engineer a
  pool state where follow-on deposits round to zero.
- The `FirstDepositTooSmall` revert (line 380) enforces `usdIn > MINIMUM_LIQUIDITY`
  on the bootstrap deposit, preventing a near-zero anchor deposit that would make
  subsequent small deposits meaningless.

---

## R2 — Centralized initial liquidity

**Risk.** At mainnet launch the founding LP(s) will hold most or all of the
ADEX-LP supply. A single large LP exiting rapidly could drain the pool, leaving
smaller LPs with a thin market and higher slippage on withdrawal. This is a
centralization risk, not a smart-contract vulnerability.

**Why accepted for v1.** A trust-minimized bootstrapping mechanism (e.g., a bonding
curve or vesting lock on founding LP tokens) is a non-trivial system that would add
audit surface before the initial deployment. The standard industry approach is to
start with committed founding LPs under off-chain commercial terms and migrate to a
more decentralized LP incentive model as TVL grows.

**Compensating controls.**

- Founding LPs are subject to the same `MIN_HOLD_SECONDS = 1 hours`
  (`ArcoraDexPool.sol` line 43) lock as all other depositors. A mass exit cannot
  be atomic; it takes at minimum one hour per deposit cohort to exit.
- The LP transfer hook (`ArcoraDexLP._update`, `ArcoraDexPool.notifyLPTransfer`)
  propagates the lock to any LP token recipient, preventing an exit via an
  intermediary fresh wallet.
- The P5 mainnet-operations plan (roadmap §7) calls for founding LP commitments,
  a TVL-floor agreement, and a decentralized LP incentive program to dilute initial
  concentration over time.

---

## R3 — Permissionless `CumulativeDeviationGuard.record`

**Risk.** `CumulativeDeviationGuard.record(address token, uint256 price1e18)` is
unauthenticated — anyone can call it with any price value. An adversary can
therefore: (a) anchor the tumbling window at an artificially favorable or
unfavorable price by being the first caller in a fresh window; (b) spam calls to
force repeated window resets; (c) emit spurious `CircuitBreakerTripped` events to
cause alert fatigue in the off-chain monitor. If the off-chain monitor were wired
to auto-pause on trip events, a griever could pause the pool trivially.

**Why accepted for v1.** Adding a keeper allowlist to `record` now would introduce
a new failure mode — a stuck or misconfigured allowlist that prevents legitimate
keepers from recording — with no functional benefit in the current implementation.
`record` has no on-chain state effect beyond updating the per-token window state
and emitting events. Nothing on-chain is gated on the guard's output. The
permissionless design is a deliberate P3 MVP decision, documented in the contract
NatSpec (lines 26–30) and the P3 design spec
(`docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md` §6).
Making `record` keeper-only is a P5 task, gated on on-chain auto-pause being wired
to the guard at that time.

**Compensating controls.**

- The contract's NatSpec explicitly documents the trust boundary: "The off-chain
  monitor MUST treat `PriceObserved` and `CircuitBreakerTripped` as untrusted hints
  and re-validate the price and anchor against its own trusted feed before paging
  the Pause Guardian" (`CumulativeDeviationGuard.sol` lines 26–30).
- No on-chain action — pause, freeze, price change — can be triggered by `record`
  alone in the current implementation. A `CircuitBreakerTripped` event is purely
  advisory.
- When on-chain auto-pause is wired to the guard in P5, `record` must be made
  keeper-only at that time (tracked in the P5 deferred-work register,
  `docs/audit/p5-tracking.md`).

**Suppression (added 2026-05-19, finding C-7):** Beyond the documented
favorable-anchor and spam-trip variants, an unauthenticated attacker can
*suppress* a genuine `CircuitBreakerTripped` by front-running the legitimate
keeper's first post-expiry `record` every window and re-anchoring to the
current drifted price. The compensating control "off-chain monitor
re-validates" addresses false positives only — not suppression of a true trip.
Mitigation: the off-chain monitor must compute deviation itself from raw feed
reads; this contract is redundant breadcrumbs, not the source of truth.
Moving `record` to keeper-only is tracked as a P5 item.

---

## R4 — Tumbling (not rolling) deviation window

**Risk.** `CumulativeDeviationGuard` measures deviation against the first
observation of each 24-hour tumbling window. A slow, sustained price drift that
stays just below `maxCumulativeBps` within each window is not detected across
window boundaries. For example, if `maxCumulativeBps = 200` for TRYC/BRLC, a
compromised keeper could push 199 bps per 24-hour window indefinitely without
ever tripping the breaker, drifting the anchor price by 199 bps/day with no
on-chain alert.

**Why accepted for v1.** A true rolling-window detector requires either a circular
buffer (expensive storage) or a two-pass checkpoint scheme (more complex logic and
more audit surface). The tumbling-window approach was deliberately chosen as a P3
MVP: it catches acute intra-window spikes — the dominant attack vector — while
keeping the implementation simple and cheap. The limitation is documented in the
contract NatSpec (lines 14–20). A rolling or multi-window detector is a P5
enhancement (`docs/audit/p5-tracking.md`).

**Compensating controls.**

- The `maxOracleDeviationBps` per-transaction cap on `lastAcceptedPrice` in
  `ArcoraDexRegistry` (reduced from 5 000 bps to 200 bps for TRYC/BRLC via P3)
  limits how far the accepted price can drift in a single oracle update. A
  cross-window drift would also be cross-transaction, giving the off-chain monitor
  many opportunities to observe and alert.
- The `OracleAggregator`'s two-source divergence check (`maxDivergenceBps = 200`
  for TRYC/BRLC, `OracleAggregator.sol` `latestRoundData` — `SourcesDiverge`
  revert at line 74) means a single compromised keeper cannot push the primary
  source more than 200 bps without the honest secondary source triggering
  `SourcesDiverge`.
- The P5 roadmap includes a rolling-window or multi-window detector as an explicit
  improvement (roadmap §10 and the P5 deferred-work register).

---

## R5 — Governance multisig compromise

**Risk.** The Governance Safe is a 3/5 Safe multisig. An attacker who compromises
three of the five signing keys could schedule any owner action on `ArcoraDexPool`
and `ArcoraDexRegistry` — rotating oracles to attacker-controlled feeds, changing
deviation caps, withdrawing protocol fees, or transferring ownership. Additionally,
the Governance Safe holds direct (non-Timelock) ownership of the seven
`MockChainlinkFeedV2` oracle feeds and seven `OracleAggregator` instances, so a
compromised governance Safe can rotate feed writers instantly, without the 48-hour
delay.

**Why accepted for v1.** The 3/5 threshold is a deliberate tradeoff between
operational liveness and security. Raising the threshold to 4/5 or 5/5 would make
coordinated governance impractical for frequent, low-stakes actions (e.g., adjusting
staleness limits, listing a new token). Using a Timelock-fronted multisig is the
standard industry approach for DeFi protocol governance at this scale. Key
procurement and signer onboarding requirements (hardware wallets per signer) are
part of the P2 governance spec.

**Compensating controls.**

- All `onlyOwner` functions on `ArcoraDexPool` and `ArcoraDexRegistry` (fee
  changes, oracle rotation, token listing, deviation caps, `transferOwnership`,
  etc.) must pass through the `TimelockController` with `getMinDelay() = 48 hours`.
  A malicious proposal is publicly visible on-chain for 48 hours before it can
  execute; any watcher can alert the community and the remaining keyholders can
  cancel via `TimelockController.cancel()`.
- The Pause Guardian Safe (2/3 threshold, separate key set from the Governance
  Safe) can call `pool.pause()` immediately — no Timelock — to freeze deposits and
  withdrawals, limiting damage to whatever an attacker could execute before the
  48-hour proposal fires. After the P4/A1 fix, `unpause()` is `onlyOwner`
  (`ArcoraDexPool.sol` line 626), so a compromised 2/3 Pause Guardian cannot
  restart a pool that the owner deliberately paused. (Note: the P2 governance
  design spec predates the P4/A1 tightening and still shows `unpause()` as a
  guardian-instant action. The current code — `onlyOwner` unpause — is
  authoritative; the P2 spec's action-routing table is superseded on this point.)
- The fee-collector role is not separated from the Governance Safe in v1 (deferred
  per roadmap §4 out-of-scope note). A compromised governance Safe could therefore
  extract accrued protocol fees in addition to the above. This is a known accepted
  risk (see R7 below).

**No-Timelock asymmetry (added 2026-05-19, finding C-10):** `OracleAggregator`
and `CumulativeDeviationGuard` are owned by the Governance Safe **directly,
without the 48h Timelock**, by deliberate design (emergency feed rotation). A
compromised Governance Safe can therefore call `setMaxDivergenceBps(10_000)`
and `setConfig(maxCumulativeBps=10_000)` **with zero delay**, disabling both
the divergence cross-check and the cumulative-deviation breaker, while the
Pool-side `maxOracleDeviationBps` ratchet that complements them *is* 48h-delayed.
This asymmetry shrinks the effective window of governance-level defenses
against a compromised Safe.

---

## R6 — Oracle keeper compromise

**Risk.** A compromised oracle keeper EOA can push malicious prices to one or both
oracle feeds for any token. Before P3 this was a direct, high-speed drain vector
(finding #1, HIGH). P3 introduced a two-source `OracleAggregator` and tightened
per-token deviation caps, narrowing the attack surface but not eliminating it.

In the v1 testnet configuration, the same keeper key is used to push both the
primary and secondary feed for each token (on a slightly offset schedule). An
attacker who compromises the single keeper EOA therefore controls both sources and
can bypass the `OracleAggregator`'s `SourcesDiverge` check. On mainnet, primary and
secondary are intended to be independent sources (Chainlink for primary, Pyth or a
DEX TWAP for secondary with a different keeper key), but this full independence is
deferred to P5.

**Why accepted for v1.** On testnet the keeper is a single EOA because there is no
Chainlink mainnet feed for TRYC/BRLC; both sources are mocked. The P5 mainnet
deployment will use independent primary and secondary sources with separate signer
keys. The testnet configuration is not the mainnet target state. For the audit, the
design of the aggregator (two independent sources) is the thing being reviewed; the
testnet deployment is scaffolding.

**Compensating controls.**

- `OracleAggregator.sol` `SourcesDiverge` revert limits single-transaction
  deviation at `maxDivergenceBps` (200 bps for TRYC/BRLC). With two independent
  sources on mainnet, a single compromised keeper can only control one source and
  the aggregator will reject a unilateral push beyond 200 bps.
- `ArcoraDexRegistry.sol` per-token `maxOracleDeviationBps` (200 bps for
  TRYC/BRLC after P3 recalibration) caps how far `lastAcceptedPrice` can walk per
  swap. An attacker needs ~50 sequential transactions to move the accepted price
  100%, giving the off-chain monitor significant lead time.
- `CumulativeDeviationGuard.sol` emits `CircuitBreakerTripped` events that the
  off-chain monitor subscribes to and responds to by submitting a Pause Guardian
  Safe transaction. This is human-in-the-loop for P3; on-chain auto-pause is
  deferred to P5.
- `MIN_HOLD_SECONDS = 1 hours` (`ArcoraDexPool.sol` line 43) means a
  keeper-compromised attacker cannot deposit to an inflated position and exit
  atomically; at least two full keeper cycles must elapse before withdrawal.

**Disable-the-honest-source variant (added 2026-05-19, finding C-1):** The
aggregator's divergence cross-check runs only in the `pOk && sOk` branch. An
attacker who controls one feed need not move it — they can **disable the
feed they do not control** by pushing it to `0` (`MockChainlinkFeedV2.setAnswer`
accepts zero/negative; `_tryRead` then returns `ok = false` for `a <= 0`),
demoting the aggregator to single-source mode and bypassing the divergence
check entirely. On testnet (single keeper writes both feeds, R6 accepted)
this is already the operative model. On mainnet (with truly independent
sources) it is a real attack. Phase D adds an explicit `requireBothSources`
mode and a degraded-mode signal to address this.

---

## R7 — Fee-collector role not separated from governance ownership

**Risk.** The protocol-fee recipient role is not separated from governance
ownership. `withdrawProtocolFees(address token, uint256 amount, address to)` in
`ArcoraDexPool` is `onlyOwner`, and the owner is the `TimelockController` (set by
`DeployGovernanceP2.s.sol`). Consequently, a malicious governance majority could
pass a proposal to redirect accrued protocol fees to an attacker-controlled
address — but that proposal is subject to the same **48-hour Timelock delay** that
applies to every other `onlyOwner` action. Fee withdrawal is **not** an
instant-drain path; it is fully Timelock-gated like `setSwapFeeBps`,
`setProtocolFeeShareBps`, and every other Pool owner action. The accepted risk is
the absence of a dedicated fee-collector multisig, not a bypass of the Timelock.

**Why accepted for v1.** Separating the fee-collector into a distinct multisig was
explicitly called out as out-of-scope for P2 in the governance design spec
(`docs/superpowers/specs/2026-05-14-phase2-governance-design.md` §4 "Out of
scope") and the mainnet-readiness roadmap §4 out-of-scope note: "Fee-collector
multisig separation (deferred — current governance multisig collects fees via
Timelock)". The separation would require a dedicated fee-withdrawal module and
adds governance surface before the Spearbit review. The deferred work is tracked
as a P5 item.

**Compensating controls.**

- `withdrawProtocolFees` is `onlyOwner`; the owner is the `TimelockController`
  with `getMinDelay() = 48 hours`. Any proposal to withdraw protocol fees to an
  attacker-controlled address is publicly visible on-chain for 48 hours before it
  can execute, giving watchers and remaining keyholders time to observe and cancel
  via `TimelockController.cancel()`.
- The affected funds are accrued protocol revenue (bounded by
  `protocolFeeShareBps` and actual swap volume); they do not represent LP
  principal or user deposits.
- The 48-hour delay makes any malicious fee-extraction proposal observable and
  cancellable — the risk is governance-trust bounded by the Timelock, not an
  instant or unobservable drain.
- Full fee-collector/governance separation is a tracked P5 item in the
  deferred-work register (`docs/audit/p5-tracking.md`).

---

## R8 — Pre-bug-bounty exposure window

**Risk.** ArcoraDEX v1 will not have an active Immunefi bug-bounty program at the
time of mainnet launch. Researchers who discover post-audit vulnerabilities before
a bounty program is in place have no formal, incentivized channel for responsible
disclosure. This creates a window — between mainnet deployment and Immunefi
program launch — during which a researcher might choose exploit-over-disclose.

**Why accepted for v1.** Setting up an Immunefi program requires a finalized
mainnet deployment (contract addresses, TVL commitments, reward-tier funding). The
program cannot be meaningfully launched before the Spearbit audit is complete and
the code is frozen for mainnet. The sequence is therefore: Spearbit audit → mainnet
deploy → Immunefi launch. This ordering is unavoidable without either delaying
mainnet or launching a bounty against unaudited code, both of which are worse
outcomes.

**Compensating controls.**

- The Spearbit audit precedes mainnet deployment. Unaudited code does not go live.
- An informal responsible-disclosure contact (the team's public key / email) is
  published in the repository and the frontend at mainnet launch so researchers
  have a channel even before the formal Immunefi program opens.
- The Immunefi program launch is a first-week P5 deliverable (roadmap §7 "Bug
  bounty launch"), with initial reward tiers covering Pool, Registry,
  OracleAggregator, and the governance contracts.
- TVL during the pre-bounty window is expected to be low (founding LP bootstrap
  only), limiting the incentive for exploit-over-disclose.

---

## R9 — Oracle-priced zero-impact swaps (finding C-3, accepted design)

ArcoraDEX prices swaps from oracles with a flat `swapFeeBps`; there is no
constant-product curve and no utilization-scaled penalty. An actor observing a
real stablecoin de-peg can convert the mispriced token at the oracle rate with
zero slippage, bounded only by `reserves[tokenOut]`. **This is by design** —
the system is an oracle swap desk, not a CFMM. LP value leaks to arbitrageurs
on every oracle-vs-market basis event.

**Compensating controls:**
- Tight `maxOracleDeviationBps` (per-token, 50/150/200 bps).
- Keeper cadence ≤ 30 min keeps the on-chain price close to the live rate.
- Phase D's aggregator hardening (per-source staleness, degraded-mode signal)
  reduces the window during which the oracle lags the real market.

**Not mitigated:** the underlying basis exposure during legitimate de-peg
events. Considered acceptable given the testnet stable mix and the design
goal of zero-slippage oracle pricing.

## R10 — Single-token full-pool withdrawal (finding C-4, accepted design)

`withdraw(tokenOut, lpAmount, …)` redeems an LP's full proportional NAV share
but pays it entirely in one chosen token. A large LP can debit
`reserves[tokenOut]` by the USD value of their whole multi-token claim,
exiting in whichever token is currently oracle-cheap vs market. **This is by
design** — the contract supports single-token exit deliberately for UX
simplicity.

**Compensating controls:**
- `MIN_HOLD_SECONDS = 1 hour` (R2) slows mass exit.
- The 0.05% protocol fee + LP-retained fee on withdraw applies regardless of
  token choice.
- The `Withdrew` event records the chosen `tokenOut` and `usdNet`, so token-
  selection bias is auditable post-hoc.

**Not mitigated:** the economic and availability hazard of one LP zeroing
`reserves[tokenOut]`. A future proportional multi-token withdraw is a possible
enhancement, deferred to post-audit.

---

*All claims above are verifiable against the contract source files in
`contracts/src/`, the design specs in `docs/superpowers/specs/`, and the threat
model in `docs/audit/threat-model.md`.*
