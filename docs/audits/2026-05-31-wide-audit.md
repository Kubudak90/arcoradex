# ArcoraDEX — Wide Security Audit

**Date:** 2026-05-31
**Commit:** `889cfd2` (branch `main`)
**Auditor:** Claude Code — two-pass multi-agent audit (fan-out finders + adversarial verification), with manual source cross-checks of the headline findings.
**Baseline:** `forge test` green at audit time — **148 tests passing, 0 failing** across 13 suites (unit, fuzz, invariant, security, governance, oracle).
**Prior audit:** `docs/audits/2026-05-24-full-sweep-audit.{html,pdf}` — findings re-verified (see [Prior Audit Status](#prior-audit-status)).

_Scope: ArcoraDEX shared-vault multi-stablecoin AMM — on-chain contracts (Pool, Registry, OracleAggregator, LP, testnet mocks, governance/migration scripts), TypeScript SDK, Next.js dApp, and off-chain keeper/ops._

> **Testnet context.** ArcoraDEX v0.7 is deployed to a testnet (chainid `5042002`) with mock tokens and no real funds. Per-finding severities are **capped for the testnet reality**; "Mainnet impact" notes call out where a finding would escalate (several to Critical) on a value-bearing deployment.

## Executive Summary

ArcoraDEX is a public-LP, oracle-priced, multi-stablecoin shared-vault AMM: a single pool holds N stablecoins, prices each via a Chainlink-style USD oracle, and issues one ERC20 LP receipt against pooled USD NAV. This audit fanned specialized agents across the contract suite, SDK, dApp, and keeper, then ran a second targeted pass on the coverage gaps the first pass flagged; every surviving finding was adversarially re-derived from source and the two headline issues were additionally hand-verified against source and on-chain broadcast artifacts.

The core AMM accounting and the prior audit's High/Medium remediations hold up well — no reentrancy or arithmetic fund-theft primitive was found in the pool. The two most consequential results are architectural rather than arithmetic: **(H-1)** the LP min-hold lock can be weaponized into a permissionless, sustained withdrawal denial-of-service via dust/zero-value transfers; and **(H-2)** the "two-source" oracle's divergence guard is structurally inert because both the primary and secondary feeds are mock aggregators written by the **same keeper key**, so the entire on-chain price surface reduces to a single key. The governance layer compounds H-2: the live testnet Governance and Pause-Guardian Safes are derived from the **public Foundry test mnemonic** (M-1) and the Timelock executor role is open (L-8) — so on the deployed testnet the 48h Timelock and multisig provide no real access control. The remaining findings are testnet-faucet integrity issues (M-2/M-3), oracle/keeper hardening, SDK/frontend safety, and gas optimizations on the hot price-resolution path.

**On mainnet, H-2 and M-1 are deployment blockers** (genuinely independent feed sources and real signer keys are prerequisites); they are rated High/Medium here only because the testnet holds no real value.

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 2 |
| Medium | 3 |
| Low | 11 |
| Informational | 12 |
| Gas | 5 |
| **Total** | **33** |

## Scope

- `contracts/src/ArcoraDexPool.sol` — shared-vault pool: deposit/withdraw/swap, NAV, oracle resolution stack, fee math, pause, owner escape hatches.
- `contracts/src/ArcoraDexLP.sol` — LP ERC20 receipt + min-hold transfer hook.
- `contracts/src/ArcoraDexRegistry.sol` — per-token config (oracle, deviation, staleness, active flag) and mutators.
- `contracts/src/oracle/OracleAggregator.sol` + `CumulativeDeviationGuard.sol` + `contracts/src/interfaces/IChainlinkAggregator.sol` — two-source aggregation, divergence, degraded mode, event-only deviation guard.
- `contracts/src/testnet/MintableERC20.sol`, `contracts/src/testnet/MockChainlinkFeedV2.sol` — testnet mocks (the live on-chain price feeds).
- `contracts/script/*` — deployment, governance (P3 / P3.5 Timelock batches), and migration scripts (cross-checked against `contracts/broadcast/*` artifacts).
- `packages/sdk/*` — TypeScript SDK actions, hooks, allowance/slippage helpers, ABIs, error mapping.
- `app/*` — Next.js dApp (swap/liquidity components, faucet API + rate limiter).
- `ops/keepalive/*` — off-chain keeper (price push + deviation-guard recording) and systemd units.

## Methodology

Two automated passes plus manual verification:

1. **Broad fan-out** — 10 specialized finder agents covered the pool (security + economics), LP/Registry, oracle, governance/deploy scripts, SDK, keeper/ops, frontend, gas/quality, and system composability in parallel.
2. **Targeted gap-fill** — a completeness critic flagged under-covered surfaces; a second pass of 6 investigations confirmed or **refuted** them (oracle trust topology, governance access control, unbounded-token DoS, fee-on-transfer accounting, intra-tx oracle divergence, faucet route).

Every candidate finding was independently re-derived from source by an adversarial verifier (High/Critical candidates by two verifiers under correctness + exploitability lenses); only findings confirmed against source survive below. The two High findings, the open-timelock and public-mnemonic claims, and the unbounded `setAnswer` were additionally cross-checked **by hand** against the source and `contracts/broadcast/*` deployment artifacts. This is a **static source review**; no finding was re-exploited against the live chain.

---

## Findings

## High

### [H-1] LP-transfer min-hold hook is weaponizable: an attacker can re-lock any LP holder's withdrawal indefinitely via dust/zero-value transfers

**Severity:** High

**Location:** `contracts/src/ArcoraDexLP.sol:36-41` (hook); `contracts/src/ArcoraDexPool.sol:661-669` (`notifyLPTransfer`); `contracts/src/ArcoraDexPool.sol:444-447` (withdraw lock); `contracts/src/ArcoraDexPool.sol:430` (`lastMintAt` set on deposit)

**Description:** The anti-JIT min-hold lock is enforced per-account via a single `lastMintAt[account]` timestamp; `withdraw` requires `block.timestamp >= lastMintAt[msg.sender] + MIN_HOLD_SECONDS` (1h). On every wallet-to-wallet LP transfer, `ArcoraDexLP._update` unconditionally calls `IArcoraDexPool(MINTER).notifyLPTransfer(from, to)` whenever `from != 0 && to != 0` — gating only on address sentinels, not on `value`. The vendored OpenZeppelin ERC20 `_update` does not short-circuit on `value == 0`, and its balance check (`fromBalance < value`) is false for `value == 0`, so a zero-value transfer succeeds even from a zero-balance sender and reaches the override. `notifyLPTransfer` is raise-only: `if (lastMintAt[from] > lastMintAt[to]) lastMintAt[to] = lastMintAt[from]`. Because the lock is account-wide (not per minted lot), bumping a victim's `lastMintAt` to a fresh timestamp re-locks the victim's entire LP position for a full `MIN_HOLD_SECONDS`. The defensive direction (closing the deposit→transfer→withdraw bypass, INV-9) is tested; the offensive direction is not.

**Impact:** Permissionless, sustained denial-of-service on withdrawals. An attacker can freeze any chosen LP holder's (or every holder's) ability to call `withdraw()` for as long as they keep griefing, at near-zero cost. The victim cannot escape by transferring out, because their own freshly-bumped `lastMintAt` propagates forward to any recipient wallet via the same hook. Funds are not stolen and the lock self-heals one hour after griefing stops, but exit is blocked via rolling 1h locks — a targeted exit-blocking attack against founding R2 LPs, or a front-run that reverts a specific pending `withdraw`.

**Scenario:** (1) Attacker deposits once so `lastMintAt[attacker] = now` (a fresh `lastMintAt` is all that is required — per verification, no positive LP balance is even needed because a zero-value transfer passes the `fromBalance < value` check). (2) Attacker calls `LP.transfer(victim, 0)`; `_update(attacker, victim, 0)` fires `notifyLPTransfer(attacker, victim)`, setting `lastMintAt[victim] = now`. (3) The victim, previously past their hold and ready to withdraw, now reverts on `withdraw` with `EarlyWithdraw`. (4) Attacker repeats (or front-runs each victim withdraw in the same block) and refreshes their own `lastMintAt` with periodic tiny deposits to keep the bump value at the current block. The victim is perpetually locked out.

**Recommendation:** Do not let an inbound transfer raise the recipient's lock based on the sender's freshness. Options: (a) track hold per minted lot rather than per account, so a stranger cannot reset an unrelated holder's clock; (b) gate the sender instead — require the sender's own hold to have elapsed before locked LP may move, removing the need to push the lock onto recipients; (c) at minimum require `value > 0` in `_update` before calling `notifyLPTransfer`, and have the recipient inherit a lock only when the transfer actually delivers locked tokens (opt-in / per-receipt accounting). Add a regression test for the offensive direction: a dust/zero-value transfer must not extend an unrelated holder's lock.

### [H-2] The "two-source" oracle collapses to a single keeper key — both primary and secondary feeds are keeper-written mocks driven by the same EOA, so the divergence guard is structurally inert and an arbitrary keeper price flows into NAV/swap pricing

**Severity:** High _(Mainnet impact: Critical — see note)_

**Location:** `contracts/src/oracle/OracleAggregator.sol:94-108` (divergence + mid-price); `contracts/src/testnet/MockChainlinkFeedV2.sol:45-52` (unbounded `setAnswer`); `contracts/script/MigrateFeedsToV2.s.sol:54` (primary writer = keeperEOA); `contracts/script/MigrateSecondaryWriters.s.sol:52-61` (secondary writer → same keeper); `contracts/src/ArcoraDexPool.sol:101-138, 145-183, 336-353, 356-368`; confirmed against `contracts/broadcast/MigrateFeedsToV2.s.sol/5042002/run-latest.json`

**Description:** The OracleAggregator is designed as a two-source oracle: it averages PRIMARY and SECONDARY and reverts if they diverge beyond `maxDivergenceBps` (`OracleAggregator.sol:94-98`), returning the mid-price `(pAns+sAns)/2` with a healthy non-zero `roundId`. The implicit security assumption is that the two sources are **independent**, so a single corrupted source is caught by the other. That assumption does not hold here:

1. The PRIMARY feeds are **not** independent real Chainlink aggregators — they are `MockChainlinkFeedV2` instances deployed by `MigrateFeedsToV2.s.sol:54` as `new MockChainlinkFeedV2(oracleDec, currentAnswer, keeperEOA, deployer)`, i.e. `writer = keeperEOA`. The broadcast artifact confirms the deployed USDC primary `0x2E6B862E…534B39` (the exact `cfg[i].primaryFeed` passed into the aggregators) has writer `0xe8fe70…b8C3`, the keeper EOA.
2. The SECONDARY feeds are also `MockChainlinkFeedV2` (`DeployOraclesP3.s.sol:124-125`), and `MigrateSecondaryWriters.s.sol:52-61` migrates each secondary's writer to `KEEPER_ADDRESS` — the **same** keeper EOA.
3. `MockChainlinkFeedV2.setAnswer` (`:45-52`) accepts **any `int256 > 0`** from the writer — no peg band, no deviation cap, no monotonicity, no max-jump. All band/peg/deviation checks live only in the off-chain keeper script (`multi-feed-push.mjs:138-145,196-208`), which a compromised or buggy key bypasses entirely.

A single key therefore writes both sources; setting both to the same value gives `absDiff = 0`, the divergence check passes trivially, and the aggregator returns the chosen value as fresh/healthy. `ArcoraDexPool._readOracle` (101-138) sees `roundOk`/`timestampOk`/`answerOk` all true and feeds it into `_readAndGuardPrice`/`_totalReservesUSDMut`, driving NAV, deposit LP minting, withdraw payout, and swap output. The `CumulativeDeviationGuard` provides no on-chain protection (it is permissionless and event-only). The only remaining on-chain limiter is the per-step cache/accepted-price deviation cap (`maxOracleDeviationBps`, e.g. 50 bps for USD pegs), which bounds movement **per tick but not cumulatively** — the keeper can ratchet the accepted price arbitrarily far over successive ticks (exactly the multi-tick walk the keeper implements), and the owner `syncAcceptedPrice` (`:689-714`) explicitly bypasses the cache-deviation guard.

**Impact:** The pool's entire price surface — NAV, LP mint/redeem rates, and swap exchange rates across all 7 stablecoins — reduces to trust in a single keeper EOA private key (stored in Vault, pulled onto the shared VPS keeper box). The advertised two-source defense-in-depth provides **zero** additional protection because both sources are the same key. A compromised or buggy keeper key can set any positive price and, over a sequence of ticks, walk a stablecoin's on-chain USD price arbitrarily far from peg — mispricing NAV and enabling value extraction via deposit-at-inflated-NAV / withdraw, or cross-token swaps drained at manipulated rates. The role-separation design's intended blast radius ("keeper compromise → only feed-write damage, bounded by `MAX_DEVIATION_BPS`") is real per-tick but **not cumulative**, so "bounded" overstates the protection. The system markets a 2-of-2 oracle that is operationally 1-of-1.

**Scenario:** (1) Attacker obtains the keeper EOA key (e.g. via the shared VPS or the Vault AppRole flow), or a keeper bug emits a wrong value. (2) Attacker calls `setAnswer` on both the USDC primary and secondary with the same elevated answer (push USDC from `1e8` toward `1.05e8`). `absDiff = 0`, so the aggregator returns the elevated mid-price as fresh/healthy. (3) The per-tick deviation cap forces the attacker to repeat over consecutive ticks, each ratcheting `lastValidPrice`/`lastAcceptedPrice` forward. (4) Once USDC NAV is materially inflated, the attacker deposits cheap real USDC that is over-valued by the pool, mints excess LP, then withdraws other reserves / swaps to a correctly-priced token — extracting pool value. The divergence guard never fires because it only compares two values written by the same key.

**Recommendation:** Treat the aggregator as single-source for risk purposes until the sources are genuinely independent. (a) Make the secondary writer a **separate key/role** from the primary (distinct EOA, distinct custody) so the divergence check carries real signal. (b) Add on-chain bounds to `MockChainlinkFeedV2.setAnswer` (per-feed min/max sanity band and/or per-update max-jump + min-update-interval) so the trust root is not "any positive int256" even when the off-chain script is bypassed. (c) Add a **cumulative** (not just per-tick) circuit-breaker that halts trading when the accepted price drifts beyond a hard band from a long-term anchor. (d) For mainnet, replace the keeper-written primary mocks with real independent Chainlink aggregators (reserve mocks for testnet). (e) Restrict or Timelock-gate the `syncAcceptedPrice` owner bypass with an absolute-band check.

**Mainnet impact:** **Critical / deployment-blocking.** With real value in the pool, a single keeper-key compromise (or software bug) is a direct path to draining LP funds via manipulated NAV/swap pricing, with no independent on-chain source able to reject it.

## Medium

### [M-1] Governance & Pause-Guardian Safe signer keys are derived from the public Foundry test mnemonic — anyone can act as the sole Timelock proposer and as owner of every feed/aggregator/deviation-guard

**Severity:** Medium _(Mainnet impact: Critical — see note)_

**Location:** `contracts/script/DeployGovernanceP2.s.sol:20,105-112,132-164`; `contracts/script/P3_5GovernanceActions.s.sol:36,38,50`; `contracts/script/P3GovernanceActions.s.sol:31,33,71-75`; `contracts/script/MigrateSecondaryWriters.s.sol:22-23`; `contracts/test/governance/SafeSigHelpers.sol:28-78`

**Description:** The 3-of-5 Governance Safe owners and the 2-of-3 Pause-Guardian Safe owners are derived deterministically from the **public** Foundry junk mnemonic. `DeployGovernanceP2.s.sol:20` declares `MNEMONIC = "test test … junk"`; `_deployInfra()` derives `govKeys[0..4] = vm.deriveKey(MNEMONIC, i)` and `pgKeys[0..2] = vm.deriveKey(MNEMONIC, 5+i)` (`:105-112`) and sets those addresses as Safe owners with thresholds 3 and 2 (`:132-156`). The same mnemonic and the same Gov Safe address (`0x715f…e624`) are hardcoded into the live operational scripts (`P3GovernanceActions`, `P3_5GovernanceActions`, `MigrateSecondaryWriters`). `SafeSigHelpers` shows that driving a Safe transaction only needs `vm.sign(signerKey, safeTxHash)` for ≥ threshold owner keys — and those keys are universally derivable (`cast wallet derive -m "test test … junk" -i 0..4`). Because the on-chain Safe owners **are** these mnemonic-derived addresses, anyone can reconstruct 3-of-5 keys off-chain, build a valid `execTransaction` signature blob, and execute any transaction as the Governance Safe. That Safe is the **sole proposer/canceller** on the Timelock and the direct owner of all 7 secondary feeds, the 7 OracleAggregators, and the `CumulativeDeviationGuard`. The Pool and Registry are owned by the Timelock, for which the Gov Safe is the only proposer.

**Impact:** Complete governance takeover on the deployed testnet. An attacker holding the (public) Safe keys can: (a) call `OracleAggregator.setMaxDivergenceBps` to widen/disable the divergence cross-check; (b) call `MockChainlinkFeedV2.setWriter` on any secondary feed to install an attacker-controlled writer, then push arbitrary prices (compounding H-2); (c) schedule arbitrary owner-gated calls on Pool/Registry through the Timelock as the only proposer (`setOracle`, `setDeviation`, `deactivateToken`, `unpause`, `setPauseGuardian`, `setSwapFeeBps`, `withdrawProtocolFees`, `syncAcceptedPrice`) and — combined with the open executor role (L-8) — execute them with zero Safe cooperation after the delay. The 48h Timelock confers no protection when the only proposer's keys are public. With the Pause-Guardian keys the attacker can also pause at will.

**Scenario:** An attacker reads the public repo, runs `cast wallet derive -m "test test … junk" -i 0/1/2` to recover three Governance Safe owner keys, constructs a Safe `execTransaction` calling `setWriter(attacker)` on the USDC secondary feed, signs with the three keys (sorted ascending), and relays it from any funded EOA. They are now the price writer; they call `setAnswer` with a manipulated price and drain the most-favorably-priced side of the shared vault. Alternatively they first `setMaxDivergenceBps` to disable the divergence guard.

**Recommendation:** Replace the test-mnemonic derivation with independent per-signer keys (hardware wallets / keystore) for both Safes before any non-throwaway deployment. The current testnet instances (Gov Safe `0x715f…e624`) must be treated as **fully compromised** and never reused or funded with anything of value. Guard the mnemonic path so it can only run on chainid `5042002` with a loud warning, and document the live testnet governance keys as public/compromised in the runbook. Rotating Safe ownership to real keys must be the first action of any production rollout.

**Mainnet impact:** **Critical / deployment-blocking.** Public signer keys = no governance at all.

### [M-2] Faucet records cooldown only on the success path — a mid-batch mint failure skips `recordClaim`, enabling immediate retry and an unbounded partial-mint loop

**Severity:** Medium

**Location:** `app/app/api/faucet/route.ts:131-191` (mint loop `147-160`; catch `161-169`; `recordClaim` `185`; finally `188-191`)

**Description:** The route reserves a per-instance in-flight slot, then runs a 7-token mint loop accumulating tx hashes as each `walletClient.writeContract` resolves. If any iteration throws (RPC error, gas spike, transient revert), the inner `catch` (`:161-169`) returns a 502 — and crucially the cooldown write `recordClaim(cooldownStore, recipient, ip)` (`:185`) sits **after** the loop on the success path, so it is never reached. The `finally` (`:188-191`) only deletes the in-flight reservation; it does not record the claim. Net effect: any request whose batch fails partway delivers the tokens that already broadcast while leaving **no** cooldown timestamp for either the address or IP key. The caller can immediately re-POST and re-mint. The comment at `:182-184` claims this is intentional ("so a mid-flight revert doesn't lock out the user"), but the cost is that every partial failure is a free re-mint, and the prior audit's F-6 fix only addressed the concurrent-request TOCTOU (via the mutex), not the skip-on-error retry.

**Impact:** Testnet integrity / faucet gas drain. An attacker (or any flaky-network user) who can make the batch fail on a late token re-mints the early tokens unboundedly, each retry spending faucet-EOA gas (7 signed mints attempted per call) and minting mock stablecoins that back the live oracle-priced pool. No real funds, so capped at Medium, but it defeats the one-claim-per-24h limit and can exhaust the faucet EOA's gas, denying the faucet to legitimate users.

**Scenario:** Attacker POSTs with a fresh address; the loop mints USDC/USDT/PYUSD, then token #4 hits a transient RPC error; the catch returns 502, `recordClaim` is skipped, finally releases the mutex; the attacker immediately re-POSTs — `checkRateLimit` still returns ok (no timestamp was written), so all 7 mints are attempted again. Loop indefinitely.

**Recommendation:** Record the claim **before** broadcasting — symmetric with the in-flight reservation — and only roll it back if **zero** tokens were broadcast (`Object.keys(txHashes).length === 0`). This bounds a user to one batch per cooldown window regardless of partial failure. Optionally add a global per-hour mint budget as defense-in-depth.

### [M-3] Faucet rate-limit and in-flight mutex are per-serverless-instance only — concurrent Vercel instances each run a full 7-tx mint batch for the same address

**Severity:** Medium

**Location:** `app/lib/faucet-rate-limit.ts:19-27` (`MemoryCooldownStore`); `app/app/api/faucet/route.ts:38-39,104,122-129,185`

**Description:** Both defenses live in module-scoped, single-process memory: `MemoryCooldownStore` wraps a plain `Map`, and the H-6 in-flight mutex is two module-level `Set`s. On Vercel these persist only within one warm instance; cold starts reset them and, more importantly, multiple concurrent instances each hold an independent copy. So `checkRateLimit` and the mutex check on instance B do not see a claim/reservation recorded on instance A. Two near-simultaneous POSTs for the same recipient that land on two instances both pass and both broadcast a full 7-tx batch. The code comments acknowledge this as an accepted testnet tradeoff; combined with the already-filed fresh-address bypass (prior F-1), the cooldown is best-effort at best.

**Impact:** The 24h cooldown is not authoritative across instances; an attacker fanning out concurrent requests (or rotating fresh addresses) multiplies mint batches, draining faucet-EOA gas and inflating mock-token supply. Testnet only, so Medium — but the rate-limit provides materially less protection than the per-request comments imply.

**Scenario:** Attacker sends N concurrent POSTs for the same recipient during a traffic spike when Vercel has scaled out. Each instance sees an empty store, passes `checkRateLimit` and the mutex, and signs 7 mints. The effective rate limit is `(instances × 1)` per window, not 1.

**Recommendation:** Move the cooldown + in-flight lock to a shared, atomic backend (Vercel KV / Upstash Redis) using `SET NX` with TTL keyed by address **and** IP, so the reservation is cross-instance; enforce a global per-hour mint budget in the same store. The `CooldownStore` interface already abstracts the backend, so this is a swap of `MemoryCooldownStore` plus an atomic reserve-or-fail primitive.

## Low

### [L-1] Quote-revert path in swap/deposit/withdraw bypasses `parseContractError` — typed errors leak as raw viem errors

**Severity:** Low

**Location:** `packages/sdk/src/actions/swap.ts:33-54`; `deposit.ts:34-50`; `withdraw.ts:24-43`; `quoteSwap.ts:8-13`; `quoteDeposit.ts:8-13`; `quoteWithdraw.ts:8-14`; `client.ts:91-93`; `errors.ts:137-180`

**Description:** In each write action the on-chain quote read (`quoteSwap`/`quoteDeposit`/`quoteWithdraw`) runs before the try/catch that wraps `writeContract` with `parseContractError`, and the quote actions call `publicClient.readContract` with no error wrapping. The pool's view quotes deliberately use the stricter oracle path `_readUsdPrice1e18WithGuard` (`ArcoraDexPool.sol:234-333`, called at `:563-564`), which over-reverts (`NoValidPrice`/`PriceDeviation`/etc.) relative to the lenient `_readAndGuardPrice`→`_readUsdPrice1e18Mut` (cache fallback at `:177-182`) used by the mutating paths. So during oracle degradation the quote read can revert even when the actual swap would succeed via cache fallback, and the revert propagates as a raw viem `ContractFunctionExecutionError` rather than a typed SDK error. `SameToken`/`ZeroAmount` are also absent from `parseContractError`'s switch.

**Impact:** Integrators classifying failures via `instanceof OracleStaleError` (etc.) fail to recognize the most common pre-flight failure (the strict quote guard), which leaks untyped. The dApp shows a generic error and never learns it could retry the more-lenient swap. No fund loss; the tx is never sent.

**Scenario:** Oracle for `tokenOut` goes slightly stale (fresh read fails the strict `WithGuard` check, cache fallback still valid). `sdk.swap()` calls `quoteSwap()` first; the on-chain `quote()` reverts `NoValidPrice`. The error is thrown outside the try/catch, never passed through `parseContractError`; the dApp's typed-error branch never matches even though a direct swap would have executed against the cache.

**Recommendation:** Wrap the `quote*` calls (and ideally the whole body) of swap/deposit/withdraw in a try/catch routed through `parseContractError`, or wrap `readContract` inside each `quote*` action. Add `SameToken` and `ZeroAmount` cases to the `parseContractError` switch.

### [L-2] FX-leg feeds (EURC/TRYC/BRLC) have no reference/peg-drift sanity guard and use 3×–10×-wide static bands; the on-chain divergence guard is structurally blind

**Severity:** Low

**Location:** `ops/keepalive/multi-feed-push.mjs:46-48, 101-115, 196-209`; `contracts/src/oracle/OracleAggregator.sol:89-108`; `contracts/src/ArcoraDexPool.sol:342-351`

**Description:** The keeper is the sole price source for the on-chain feeds. The three FX-pegged tokens are configured `peg: null`, `maxPegDriftBps: null`, so the peg-drift check is skipped; the only remaining off-chain sanity gate is the static `band`, which is enormous relative to live value (EURC `[1.00, 1.30]` ~24%, TRYC `[0.01, 0.10]` 10×, BRLC `[0.10, 0.30]` 3×). The keeper fetches a single `usd` value and pushes the identical value to both the primary and secondary feed, so the OracleAggregator's only cross-check (`_combineSources` divergence between its two sources) can never fire on a bad-but-consistent value. There is no on-chain and no off-chain reference anchor for FX legs — the wide band is the entire defense. _(This is the off-chain analogue of [H-2]; H-2 covers the on-chain single-writer collapse, this covers the absent FX sanity bounds.)_

**Impact:** A faulty or manipulated upstream FX quote (CoinGecko poisoning, data glitch, thin TRY/BRL spot manipulation) landing inside the loose band is committed to both oracle sources. The per-call `maxOracleDeviationBps` ratchet bounds each step, so the keeper walks the on-chain FX price ~150 bps per tick toward the bad value, mispricing EURC/TRYC/BRLC operations and letting an arbitrageur extract value from LPs. TRYC/BRLC are worst-case (multiple-fold band tolerance). The on-chain ratchet bounds the leak to a slow walk operators can observe, hence Low.

**Scenario:** CoinGecko returns TRY/USD inverting to 0.09 (band max 0.10) while true value is ~0.03. It passes the band check; the keeper pushes 0.09 capped to +150 bps over the prior answer to both TRYC feeds. The aggregator sees no source divergence and returns the average; the pool accepts each step within its ratchet. Two ticks/hour later the on-chain TRYC price has walked materially high; an arbitrageur swaps real stablecoins for over-valued TRYC, draining LP value.

**Recommendation:** Give FX legs a real reference-drift guard: fetch an independent second FX source and reject on disagreement beyond a small bps tolerance, and/or tighten each FX `band` to a narrow window (a few hundred bps) around a recently-trusted reference. At minimum set `maxPegDriftBps` against a slow-moving reference for FX legs too. Document that pushing one source's value to both feeds defeats the on-chain divergence guard, and source the secondary feed from a genuinely independent provider.

### [L-3] CoinGecko fetches have no request timeout; a hung upstream stalls the oneshot until systemd's default start-timeout

**Severity:** Low

**Location:** `ops/keepalive/multi-feed-push.mjs:88, 104`; `:187` vs `:189` (fetch precedes push loop); `ops/keepalive/arcoradex-feeds.service` (`Type=oneshot`, no `TimeoutStartSec`)

**Description:** Both CoinGecko `fetch` calls are made with no `AbortController`/signal and no timeout, and the service unit sets no `TimeoutStartSec`. `fetchAllPrices()` is awaited before the push loop, so if CoinGecko accepts the TCP connection but never responds, the awaited fetch blocks the entire run. (Node's undici applies built-in `headersTimeout`/`bodyTimeout` ~300s and systemd's ~90s default start-timeout would SIGKILL first, so the hang is bounded — but the genuine defect is the lack of a fast, clean per-batch abort.)

**Impact:** A single hung upstream request prevents that run from pushing any feed; all feeds miss that tick. Repeated stalls let on-chain answers exceed `MAX_STALE_SECONDS`, forcing cache fallback and eventually `NoValidPrice`. The 30-min cadence vs 1h `MAX_STALE_SECONDS` gives one-tick recovery margin and the oracle fails safe, hence Low.

**Scenario:** CoinGecko (or an interposing proxy) holds the connection open without responding; `await fetch(...)` never resolves; the run produces no pushes and is eventually SIGKILLed by systemd after the default start-timeout, having refreshed nothing.

**Recommendation:** Wrap both fetches with an `AbortController` and a short timeout (10–15s) so a hung upstream surfaces as the per-batch error the existing handling already logs and skips, and add an explicit `TimeoutStartSec` to the service units as a backstop.

### [L-4] No nonce, gas-price ceiling, or confirmation-timeout on keeper writes — a stuck/under-priced tx or adversarial RPC can stall the oneshot or drain keeper gas

**Severity:** Low

**Location:** `ops/keepalive/multi-feed-push.mjs:151-157, 178-179`; `ops/keepalive/guard-record.mjs:118-122`; service units lack `TimeoutStartSec`

**Description:** Both keeper scripts call `walletClient.writeContract(...)` with no explicit `gas`, `maxFeePerGas`/`gasPrice` ceiling, or `nonce`, then `await publicClient.waitForTransactionReceipt({ hash })` with no timeout. Both clients use a single `http()` transport against one RPC endpoint with no fallback. There is no upper bound on the fee the keeper will pay, and `waitForTransactionReceipt` has no wall-clock timeout, so a tx that never mines blocks the whole oneshot. (systemd's ~90s default start-timeout bounds the hang.)

**Impact:** An abnormally high RPC-suggested fee (RPC misbehavior, fee spike, malicious RPC) is signed and broadcast with no cap, potentially draining the keeper EOA's native gas across successive 30-min runs. A stuck tx hangs the run until systemd kills it, and the unmanaged nonce can collide on the next run. Net effect is keeper liveness loss (feeds go stale, then `NoValidPrice`) and/or gas wastage. Bounded today by this being testnet ARC, hence Low.

**Scenario:** During a congestion spike the RPC under-suggests fees; the first `setAnswer` mines slowly while `waitForTransactionReceipt` blocks; remaining feeds never push before the systemd timeout fires. Alternatively a compromised RPC returns an inflated fee and the keeper burns its ARC balance across runs.

**Recommendation:** Set an explicit per-tx `maxFeePerGas`/`maxPriorityFeePerGas` ceiling and a `timeout` on `waitForTransactionReceipt`; manage the nonce explicitly (or handle replacement) so a stuck tx can be re-priced; add a startup balance check that warns/aborts below a threshold; configure a fallback RPC; add `TimeoutStartSec` to the units. _(These same defects apply to `guard-record.mjs:118` — see Coverage.)_

### [L-5] Swap/Deposit/Withdraw CTAs are not gated on the connected chain — wrong-network users hit a raw `ChainMismatchError` mid-signing

**Severity:** Low

**Location:** `app/components/swap/SwapCard.tsx:106-107, 279-283`; `app/components/liquidity/DepositTab.tsx:58, 142-146`; `app/components/liquidity/WithdrawTab.tsx:69-70, 179-183`; `packages/sdk/src/react/ArcoraDexProvider.tsx:19, 24-25`; `packages/sdk/src/actions/swap.ts:44-51`; `deposit.ts:40-47`; `withdraw.ts:33-40`; `packages/sdk/src/allowance.ts:30-37`; `app/components/wallet/ConnectButton.tsx:13`

**Description:** The three transaction-building components compute `ctaDisabled` purely from `isConnected` + amount + quote + balance; none read `useChainId()` or compare against `arcTestnet.id`. `ArcoraDexProvider` always builds the SDK client with `effectiveChain = arcTestnet` and pins the read client via `usePublicClient({chainId})`, so quotes/balances render even when the wallet is on another chain and the Swap button stays enabled. On Confirm the SDK calls `writeContract({ chain: arcTestnet, ... })`; viem 2.48.8's `sendTransaction` asserts the wallet chain (`getChainId` + `assertCurrentChain`) and throws `ChainMismatchError`. The same wrong-chain CTA pattern is already correctly handled in `ConnectButton.tsx:13` and `FaucetButton.tsx`, making these three an inconsistent omission.

**Impact:** No fund loss (viem blocks cross-chain execution). Degraded/confusing UX: a user on the wrong network can be walked into signing an ERC20 approval (`ensureAllowance` runs before the chain-asserting write, also carrying `chain: arcTestnet`) before the flow aborts with a raw library error rendered verbatim in the red error `<p>`.

**Scenario:** User lands on the dApp with MetaMask on Ethereum mainnet. Pool TVL and a quote render (read client pinned to arcTestnet); the Swap button is enabled. On Confirm the tx aborts with `ChainMismatchError: … wallet (id: 1) does not match … (id: 5042002)`, shown in red with no in-app guidance to the header Switch button.

**Recommendation:** Add a `chainId === arcTestnet.id` gate to `ctaDisabled` in all three components (mirror `ConnectButton.tsx:13`'s `wrongChain`), and render a "Switch to Arc Testnet" CTA in-card (via `useSwitchChain`) when the chain mismatches, preventing both the failed-signing UX and the wrong-chain approval prompt.

### [L-6] `ConfirmSwapModal` "Minimum received" is computed from the displayed quote, but on-chain `minOut` is recomputed from a fresh re-quote at execution

**Severity:** Low

**Location:** `app/components/swap/ConfirmSwapModal.tsx:40-42, 84-89`; `packages/sdk/src/actions/swap.ts:33-38, 50`; `packages/sdk/src/actions/quoteSwap.ts:8-13`; `packages/sdk/src/slippage/index.ts:1-5`; `app/components/swap/SwapCard.tsx:56, 86-95, 342`; `contracts/src/ArcoraDexPool.sol:526`

**Description:** The modal derives `minOutFloat = amountOutQuoted * (10000 - slippageBps) / 10000` from the quote captured at render time. The actual `minAmountOut` sent on-chain is computed inside the SDK from a brand-new `quoteSwap` performed at execution, then `minOut()` applied to that fresh value (enforced at `ArcoraDexPool.sol:526`). Because ArcoraDEX prices swaps purely off the oracle ratio with no slippage curve, the fresh quote can differ from the displayed one if the oracle/cache moved between render and submit, so the shown floor is not the enforced floor.

**Impact:** A user can receive less than the "Minimum received" figure shown in the confirm dialog: the enforced floor is `slippageBps` below the execution-time quote, which may be lower than `slippageBps` below the display-time quote. Bounded by the per-call oracle deviation ratchet, so loss is small; no protection is broken (a real `minOut` is always enforced) — this is a correctness/disclosure gap.

**Scenario:** User sees quote 1000 USDT, 0.5% slippage, modal shows "Minimum received 995 USDT". Oracle ratio shifts down before submit; the SDK re-quotes 996 USDT and enforces `minOut = 991.02 USDT`. The swap succeeds delivering 992 USDT — below the 995 promised as a floor.

**Recommendation:** Have the SDK return the exact `minAmountOut` it will submit (or pass the computed `minOut` into the modal) and display that, rather than recomputing in the UI from a stale quote. Alternatively, freeze the quote used for both display and submission within a single confirm flow.

### [L-7] Retired P3 governance scripts remain fully runnable and would schedule a regression batch repointing the live Registry to superseded V1 aggregators

**Severity:** Low

**Location:** `contracts/script/P3BatchBuilder.sol:14-28, 57-76`; `contracts/script/P3GovernanceActions.s.sol:36-98`; `contracts/script/ExecuteP3Batch.s.sol:18-36` (cross-checked against `P3_5BatchBuilder.sol`, `P3_5GovernanceActions.s.sol`, fix commits 889cfd2 + 4a3b192)

**Description:** Prior-audit M-1 (zero-salt front-run griefing on the P3 batch) is recorded as fixed via "retire/backport old scripts", but the remediation was purely a NatSpec DEAD-CODE comment (commit 889cfd2 added 7 comment lines, 0 code changes). The three P3 scripts still compile and run. They hardcode the live canonical `REGISTRY = 0x9914…05aB` and `TIMELOCK = 0x3644…6E83` and use `SALT = bytes32(0)`; the only run guard is `require(block.chainid == 5042002)`, satisfied on the live testnet. `_buildP3Batch` encodes 7× `Registry.setOracle(token, P3_AGG_*)` + 2× `setDeviation(TRYC/BRLC, 200)`, pointing the Registry back at the legacy P3 (V1) OracleAggregator instances that P3.5 superseded (the V1 aggregators carry the closed C-1/C-2/C-5 oracle bugs that the V2 bytecode fixed). The legacy script also lacks the canonical P3.5 guards: Phase A is idempotent and prints reassuring "skip" lines while Phase B schedules unconditionally.

**Impact:** An operator re-running `P3GovernanceActions` (stale runbook, lingering `P3_AGG_*` env vars) would, after the Timelock delay and `ExecuteP3Batch`, silently regress the production Registry oracle pointers from the audited V2 aggregators back to the buggy V1 aggregators — re-introducing the closed C-1/C-2/C-5 findings and the zero-salt griefing. No on-chain mechanism prevents this; it relies on humans heeding a code comment. Bounded by being a privileged-role footgun, observable on-chain, hence Low.

**Scenario:** Post-P3.5, the Governance Safe still holds the proposer role and the P3 aggregators still exist on-chain. An operator exports the historical `P3_AGG_*` addresses and runs `forge script script/P3GovernanceActions.s.sol --broadcast` believing it idempotent; Phase B unconditionally schedules a fresh `setOracle` batch; the delay later, `ExecuteP3Batch` repoints the Registry to the buggy V1 aggregators.

**Recommendation:** Delete `P3BatchBuilder.sol` / `P3GovernanceActions.s.sol` / `ExecuteP3Batch.s.sol` (git history preserves them), or add a hard runtime guard that aborts the schedule unless the Registry's current `usdOracle` for each token is not already a V2 aggregator. A bare comment is not a control surface for a script encoding live governance calldata.

### [L-8] TimelockController executor role granted to `address(0)` — once an operation is scheduled and the delay elapses, any address can execute it

**Severity:** Low

**Location:** `contracts/script/DeployGovernanceP2.s.sol:160-164`; OZ `TimelockController.sol:131-133,145-150,356-362,383-389`; `contracts/script/ExecuteP3_5Batch.s.sol:8-11,40-41`; `contracts/script/ExecuteP3Batch.s.sol`

**Description:** `DeployGovernanceP2.s.sol:160-164` constructs the TimelockController with `executors = [address(0)]` (and `minDelay = 0`, `admin = address(0)`). In OZ v5.6 this `_grantRole(EXECUTOR_ROLE, address(0))`, and `execute`/`executeBatch` are gated by `onlyRoleOrOpenRole(EXECUTOR_ROLE)`, which skips the per-caller role check entirely whenever `hasRole(role, address(0))` is true. Execution is therefore permissionless. `ExecuteP3_5Batch.s.sol:8-11` documents this explicitly ("The Timelock executor role is open, so the deployer EOA can execute directly"). Scheduling remains gated to `PROPOSER_ROLE` and cancel to `CANCELLER_ROLE`, so the open executor alone does not let an attacker introduce new operations — it lets any third party control **when** an already-ready operation runs.

**Impact:** Any third party can call `execute`/`executeBatch` on a scheduled, ready operation. Two concrete effects: (1) **timing control** — an attacker picks the exact block at which a ready governance batch lands (e.g. coinciding the P3.5 `setOracle` migration with a favorable transient oracle/NAV state, or sandwiching it with swaps); (2) **griefing** — a watcher front-runs the legitimate operator's execute. Standalone this is a minor operational weakness, but it compounds badly with [M-1]: because the only proposer (Gov Safe) is itself controlled by publicly-derivable keys, the schedule→wait→execute pipeline is end-to-end permissionless, and the open executor removes even the last step of needing the legitimate operator to push the execution.

**Scenario:** An operator schedules the P3.5 `setOracle` migration via the Gov Safe. Once Ready, a bot monitoring `isOperationReady(batchId)` front-runs the operator's `ExecuteP3_5Batch` transaction, calling `executeBatch(...)` itself in a block of its choosing — e.g. immediately after pushing a large swap to skew pool state, or to grief the operator's post-condition assertions. No proposer/executor authorization is checked for the executing caller.

**Recommendation:** Grant `EXECUTOR_ROLE` to a known, bounded set (the Governance Safe and/or the keeper EOA) instead of `address(0)`. If open execution is intentional for the testnet rehearsal, document it as an accepted risk in the deploy runbook and ensure the production deploy script passes a concrete executor list (and renounces the open role). Independently, fixing the proposer-key issue (M-1) is what actually restores the timelock's protective value.

### [L-9] Registry token set is monotonic and uncapped (no `removeToken`, no `MAX_TOKENS`); NAV-loop cost can only grow, and deactivation never reclaims iteration cost

**Severity:** Low

**Location:** Registry: `listToken` push at `:55`, `deactivateToken` `:86-91`, `tokensLength` `:28-30`, interface `IArcoraDexRegistry.sol:38-56` (no `removeToken`). Pool NAV loops: `_totalReservesUSDMut` `:356-368`, `totalReservesUSD` `:371-383`; hot-path callers deposit `:412`, withdraw `:449`, quoteDeposit `:584`, quoteWithdraw `:601`.

**Description:** `ArcoraDexRegistry.tokens[]` only ever grows: `listToken` does `tokens.push(token)` and there is no `removeToken`, `pop`, `delete`, or cap anywhere in `src/` or the interface. `deactivateToken` merely sets `isActive = false` and leaves the address in `tokens[]` permanently. The pool's two NAV loops iterate `0..tokensLength()` and perform external calls `REGISTRY.tokens(i)` and `REGISTRY.isActive(t)` on **every** entry — including deactivated ones — before the `continue` skip. So deactivation lowers but never eliminates a token's per-iteration gas, and there is no mechanism to shrink the iterated set. A large enough `tokens[]` makes the NAV-loop paths (deposit, withdraw, quoteDeposit, quoteWithdraw) revert out-of-gas for all users, permanently, with no recovery primitive. (`swap()`/`quote()` price only the two legs and do not run the NAV loop, so they would survive.)

**Not attacker-reachable (verified).** `listToken` is `onlyOwner`; the Registry owner is the TimelockController governed by the Governance Safe, and the keeper/secondary-writer roles touch only oracle feeds, not the token set. There is **no** public-mnemonic or keeper path to `listToken`, and listing additionally requires a real ERC20 with matching `decimals()` and a non-zero oracle per token. This is therefore a **governance footgun / scalability-and-irreversibility ceiling**, not an externally exploitable DoS.

**Impact:** If the token set were ever grown very large (only governance can), the NAV-loop paths would revert OOG and could not be repaired — there is no `removeToken` and deactivation does not remove a token from iteration, so gas can never be reduced below the per-entry external-call floor. Order-of-magnitude: at ~30M block gas and ~20k–40k gas/iteration, the loop approaches unusability in the low-hundreds-to-~1000-token range; dead (deactivated) entries push that ceiling lower in effective terms.

**Scenario:** Governance lists tokens over the protocol's lifetime; some are later deactivated for depeg/deprecation. Because `deactivateToken` leaves the entry and the loop still pays `tokens(i)+isActive(t)` for each dead entry, per-deposit/withdraw gas climbs monotonically and can never be walked back; no governance action can restore a bricked NAV loop.

**Recommendation:** Add an explicit `MAX_TOKENS` bound in `listToken`. Provide a `removeToken` (swap-and-pop on `tokens[]`, precondition `reserves[token] == 0` and deactivated) so the iterated set can shrink. Alternatively maintain a separate `activeTokens[]` array that the pool iterates so deactivated tokens cost zero gas. At minimum, document the ceiling in governance runbooks and require deactivation+drain before any large listing campaign.

### [L-10] Reserve accounting trusts the requested transfer amount, not the measured balance delta — fee-on-transfer / deflationary / rebasing tokens break the `balance == reserves + fees` invariant and can freeze residual liquidity

**Severity:** Low

**Location:** `contracts/src/ArcoraDexPool.sol:421-422` (deposit), `:533-534` (swap in-leg), `:473-489` (withdraw); `contracts/src/ArcoraDexRegistry.sol:33-57` (`listToken` guards)

**Description:** `deposit()` does `safeTransferFrom(msg.sender, address(this), amount)` then `reserves[token] += amount` — crediting the **requested** `amount`, not the actually-received balance delta. `swap()` does the same on the in-leg. For a fee-on-transfer / deflationary token the contract receives `amount - fee` but books the full `amount`, so `reserves[token]` over-counts the true balance by the cumulative fee; for a positive-rebasing token the reverse drift occurs. No path measures `balanceOf` before/after to reconcile (grep confirms no `balanceOf` use in deposit/swap/withdraw). The Registry `listToken` guard validates only non-zero token/oracle, declared-vs-actual decimals, deviation/stale-seconds ranges, and not-already-listed — there is **no** probe or rejection of non-standard transfer behavior. `reserves[]` stays internally consistent (decremented by requested out amounts, `InsufficientLiquidity` compares against `reserves[]`), but diverges from real balance, so eventually a final `safeTransfer` reverts or earlier withdrawers drain the real balance below what later LPs' reserves entitle them to.

**Impact:** The intended invariant `balance(token) >= reserves[token] + protocolFeesAccrued[token]` is violated for any non-clean listed token. For fee-on-transfer/deflationary tokens, the last LPs/swappers attempting to exit hit `InsufficientLiquidity` or a reverting transfer, leaving residual reserves permanently unredeemable (partial freeze of the shortfall). NAV also overstates true backing, mildly diluting honest LPs. Integrity/accounting break + partial-freeze; not direct theft, and gated on an owner listing action.

**Scenario:** Governance lists a token whose ERC20 transfer skims a fee or rebases — e.g. USDT (which ships a dormant fee-on-transfer switch), a reflection-style "stable", or an algorithmic rebasing stable. Decimals and oracle pass `listToken`, so listing succeeds. Users deposit/swap; `reserves[token]` accrues more than held. Over time redemptions draw the real balance below `reserves[token]`; the final LPs calling `withdraw()` get `InsufficientLiquidity` or a reverting `safeTransfer`.

**Recommendation:** (1) In `deposit()` and `swap()`, credit the **measured delta** (snapshot `balanceOf` before/after `safeTransferFrom`, use `received = after - before`). (2) Add a no-FoT/no-rebasing precondition to `listToken` — at minimum document the assumption, ideally perform a self-transfer probe or require an owner attestation. (3) Add a deflationary/FoT mock to the invariant suite (currently only clean `MintableERC20` is exercised). If the protocol intends to support only clean stablecoins, encode that as an asserted listing precondition rather than an implicit assumption.

### [L-11] Faucet CSRF/origin defense fails open when `NEXT_PUBLIC_APP_URL` is unset or misconfigured

**Severity:** Low

**Location:** `app/app/api/faucet/route.ts:57-69`

**Description:** The H-7 same-origin check is wrapped in `if (allowedOrigin)` (`:58`), where `allowedOrigin = process.env.NEXT_PUBLIC_APP_URL`. If that env var is absent or empty, the entire Origin/Referer validation block (`:59-68`) is skipped and the route accepts cross-origin POSTs. There is no `app/.env.example` or `app/vercel.json` pinning the variable (verified), and the only place the prod URL appears is `metadataBase`/openGraph in `app/layout.tsx` (unrelated to this check). The CSRF guard depends entirely on a correctly-set runtime env var with no build/test-time enforcement — a fail-open posture: a deploy/preview environment that forgets `NEXT_PUBLIC_APP_URL` silently loses origin protection.

**Impact:** With the var unset, a third-party page can drive a victim's browser to POST `/api/faucet` (CSRF). Because BotID's signal is collected per page load in the victim's app context and the faucet only needs an attacker-chosen `address` in the body, a cross-site forced claim is feasible — minting to an attacker address using the victim's apparent origin/session signals. Testnet mock tokens only, so Low, but it nullifies a documented control under a realistic misconfiguration.

**Scenario:** Faucet is deployed to a preview/staging Vercel project (or a misconfigured prod) where `NEXT_PUBLIC_APP_URL` was not set. `allowedOrigin` is undefined, the check is skipped, and curl/cross-site POSTs with arbitrary Origin headers are accepted.

**Recommendation:** Fail closed: if `NEXT_PUBLIC_APP_URL` is unset in a non-dev environment, reject the request (or hardcode the canonical production origin as a fallback allowlist). Add a build/CI assertion that the var is present for production deploys, document it in an `.env.example`, validate Origin by exact match, and treat a missing Origin on a state-changing POST as suspicious rather than implicitly trusted.

## Informational

### [I-1] Token deactivation/reactivation NAV swing enables deposit/withdraw value transfer between LP cohorts

**Severity:** Informational

**Location:** `contracts/src/ArcoraDexPool.sol:356-383` (NAV active-only filter), `:415` (deposit mint), `:444-452` (withdraw hold + redeem); `contracts/src/ArcoraDexRegistry.sol:86-98` (deactivate/reactivate, no reserves guard); prior triage `docs/audit/2026-05-19-comprehensive-audit.md:283-291` (C-12), `docs/audit/invariants.md:84` (INV-5)

**Description:** NAV sums `reserves[t]*price` only over active tokens (`if (!REGISTRY.isActive(t)) continue;` at `:364`/`:379`). `deactivateToken(X)` on a token still holding `reserves[X] > 0` instantly drops X's USD contribution from NAV with no token leaving the pool; `reactivateToken(X)` restores it. Deposit/withdraw for other active tokens keep functioning during the window. Since `MIN_HOLD_SECONDS` (1h) is far below the 48h governance delay, the hold does not block a deposit-in-window / withdraw-after-reactivation straddle. Same root cause as in-house finding C-12 (triaged Low) and governance-gated; the cross-LP value-transfer framing is a legitimate elaboration.

**Impact:** Value is transferred between LP cohorts across the deactivation boundary with no fee or hold protecting the deactivated value. An actor depositing an active token during the window mints LP against an understated NAV; after reactivation the restored NAV inflates their share at the expense of LPs who held through the window. Privileged-trigger only (48h Timelock), hence Informational.

**Scenario:** Pool NAV $700k, $100k in TRYC. `deactivateToken(TRYC)` is queued in the 48h Timelock; on execution NAV drops to ~$600k while LP supply is unchanged. An observer deposits $100k USDC during the window at the depressed NAV-per-share; governance reactivates TRYC; NAV jumps back; the attacker withdraws after the 1h hold, having diluted LPs who held TRYC exposure through the window.

**Recommendation:** Do not let an active-set change silently re-rate outstanding LP. Options: require `reserves[token] == 0` before `deactivateToken`; do not auto-restore reserves into NAV on `reactivateToken` without a governance-acknowledged re-rate; or pause the pool for the duration of any active-set change affecting a token with non-zero reserves. At minimum document the straddle alongside INV-5 / C-12.

### [I-2] `reactivateToken` re-seeds stale `lastAcceptedPrice`/cache, bricking the token or trading it stale until owner `syncAcceptedPrice`

**Severity:** Informational

**Location:** `contracts/src/ArcoraDexRegistry.sol:93-98` (reactivateToken only flips isActive, no pool hook); `contracts/src/ArcoraDexPool.sol:336-353` (`_readAndGuardPrice` ratchet against `lastAcceptedPrice`), `:145-199` (`_readUsdPrice1e18Mut` cache-deviation guard + `_requireCacheNotExpired`), `:356-368`/`:449`/`:457` (NAV loop skips inactive tokens), `:689-714` (`syncAcceptedPrice` owner-only recovery)

**Description:** `lastAcceptedPrice`/`lastValidPrice`/`lastValidPriceAt` are pool state never cleared on `deactivateToken`/`reactivateToken` (the registry has no pool hook). After a token X has been inactive for a meaningful period and is reactivated, the first mutating read compares the fresh oracle price against the stale `lastAcceptedPrice` captured before deactivation. The dominant outcome is trading briefly at the stale cache price, or `NoValidPrice` if the deactivation outlasted `maxCacheAgeSeconds`; a hard `PriceDeviation` brick occurs only in the narrower sub-case where the fresh price stays within cap of cache but beyond cap of `lastAcceptedPrice`. The path is gated behind a 48h Timelock action and fully recoverable by the same governance via `syncAcceptedPrice`.

**Impact:** After a non-trivial deactivation period the reactivated token can be temporarily untradeable until governance separately calls `syncAcceptedPrice(X)` (another 48h-delayed action), or briefly tradable at a stale cache price. Availability/operational footgun triggered by operator mis-sequencing, not an external adversary; no funds lost.

**Scenario:** Governance deactivates EURC to migrate its aggregator; during the multi-day migration EURC's price moves >150 bps; governance reactivates EURC; the next `withdraw`/`swap` touching EURC reverts `PriceDeviation` (or trades on stale cache); recovery requires a separate `syncAcceptedPrice(EURC)` Timelock action.

**Recommendation:** Require `syncAcceptedPrice(token)` in the same governance batch as `reactivateToken` (sequence the Timelock payload), or add an owner path that resets `lastAcceptedPrice`/`lastValidPrice` at reactivation. Document the required reactivate+sync ordering in migration runbooks.

### [I-3] Pause Guardian can freeze all user withdrawals for ≥48h (pause-griefing DoS); paused pool blocks exits while admin fee-sweep stays open

**Severity:** Informational

**Location:** `contracts/src/ArcoraDexPool.sol:82-89` (`whenNotPaused` + `onlyOwnerOrGuardian` modifiers), `:435-441` (withdraw gating), `:502` (swap gating), `:631-639` (`withdrawProtocolFees` not paused-gated), `:641-654` (pause guardian-callable / unpause owner-only with intentional-design comment)

**Description:** `withdraw()`/`swap()`/`deposit()` are gated by `whenNotPaused`. `pause()` is callable by owner OR `pauseGuardian` (`onlyOwnerOrGuardian`), but `unpause()` is owner-only (the 48h governance Timelock). A compromised or misbehaving Pause Guardian can therefore freeze all user operations, and the soonest anyone can restore service is after a Timelock proposal completes its 48h delay. `withdrawProtocolFees()` is not gated by `whenNotPaused`, so the owner can still sweep `protocolFeesAccrued` while user exits are frozen. This asymmetry is explicitly intentional (code comment `:646-650`: a compromised guardian must not be able to un-protect a pool) and is a documented trust assumption.

**Impact:** Liveness/DoS only: a single guardian-key compromise (a lower bar than the Governance Safe) can lock all user funds in the pool for at least the full Timelock delay. No theft — funds remain in `reserves[]` and are recoverable on unpause.

**Scenario:** An attacker compromising only the Pause Guardian Safe key calls `pause()`. All `withdraw()`/`swap()`/`deposit()` revert `PoolPaused`. Governance must draft, sign, and wait out the 48h Timelock unpause before service resumes.

**Recommendation:** Accepted design trade-off; no code change required if intentional. To reduce blast radius, consider (a) an auto-expiry on guardian-initiated pauses unless re-affirmed by the owner, or (b) a faster owner-direct emergency-unpause path distinct from the standard 48h flow. _(Note: the Pause-Guardian Safe is one of the public-mnemonic Safes — see [M-1].)_

### [I-4] Single-source degraded mode forwards the surviving feed's price with no divergence cross-check; safety depends entirely on consumers checking `roundId == 0`

**Severity:** Informational

**Location:** `contracts/src/oracle/OracleAggregator.sol:77-85` (degraded path) and `:14-22` (contract NatSpec); `contracts/src/interfaces/IChainlinkAggregator.sol:1-11` (no NatSpec); `contracts/src/ArcoraDexPool.sol:101-138` (`_readOracle` roundOk at `:113`); `contracts/test/oracle/P3Aggregator.t.sol:465-512`

**Description:** When exactly one source passes `_tryRead`, `latestRoundData` returns `(0, ans, at, at, 0)` — the surviving feed's price with no divergence cross-check, signaled solely by `roundId = 0`/`answeredInRound = 0`. The entire fail-safe rests on the consumer rejecting `roundId == 0`. The in-repo consumer `ArcoraDexPool._readOracle` does exactly this (`roundOk = roundId != 0 && answeredInRound >= roundId` → `isFresh = false` → cache fallback), and `P3AggregatorDegradedConsumerTest` pins it. But `IChainlinkAggregator.sol` carries no NatSpec documenting this convention, so a naive third-party consumer validating only `answer > 0`/`updatedAt` would silently accept an un-cross-checked single-source price.

**Impact:** For the current pool: none — degraded reads correctly fold to cache. The hazard is integration-contract fragility: a future or third-party consumer not special-casing `roundId == 0` would lose divergence protection in single-source mode. Architectural trust assumption, not an exploitable bug in present wiring.

**Scenario:** The secondary feed goes stale (keeper downtime on one writer); the aggregator enters single-source mode (`roundId = 0`); the pool ignores the read and uses cache (correct). A hypothetical second consumer checking only `answer > 0`/`updatedAt` would instead trade on the lone surviving feed with no cross-check.

**Recommendation:** Document the `roundId == 0` degraded-mode convention directly in `IChainlinkAggregator.sol` NatSpec. Optionally expose an explicit `isDegraded()`/reuse `sourceHealth()` and require consumers to gate on it. Keep `P3AggregatorDegradedConsumerTest` as the regression pin.

### [I-5] OracleAggregator divergence cap is measured against `min(price)`, not mid/max — asymmetric band widens effective tolerance and is not re-validated against the returned mid

**Severity:** Informational

**Location:** `contracts/src/oracle/OracleAggregator.sol:94-107`

**Description:** `_combineSources` computes `absDiff = |pAns - sAns|` and divides by `minAns` (the smaller of the two answers): `if (absDiff * 10_000 > minAns * maxDivergenceBps) revert`. Using the smaller price as denominator makes the effective tolerance, expressed relative to the larger price or the returned mid `(pAns+sAns)/2`, wider than `maxDivergenceBps`; the strict `>` accepts the exact boundary. With cap = 200 bps, primary = 100 / secondary = 102 passes, and the mid (101) sits ~1.98% from each source. There is no second check that the returned mid is within `maxDivergenceBps` of each source.

**Impact:** The intended "sources agree within `maxDivergenceBps`" guarantee is slightly looser and asymmetric (looser when the corrupted feed prints high). For the configured 50/100/200 bps caps the extra slack is on the order of `cap²/2` — a fraction of a basis point — fully inside the documented oracle trust model, and the returned mid always stays within `[min,max]` (INV-7 holds). No fund-loss path; purely a tolerance-precision/spec-fidelity issue.

**Scenario:** Governance sets `maxDivergenceBps = 200` for a soft-FX token; a compromised secondary reports 2% above the honest primary; the aggregator accepts at the boundary and returns a mid ~1% above true, which the pool then accepts subject to its own per-token ratchet — marginally above the operator's mental model of "within 2% of each other".

**Recommendation:** If exact symmetric semantics are desired, measure divergence relative to the mid (`absDiff * 10_000 > mid * maxDivergenceBps`) or to `max(pAns,sAns)`; otherwise document in NatSpec that the cap is measured against the smaller source and is therefore asymmetric. Low priority — current per-tier caps make the numerical effect negligible.

### [I-6] `syncAcceptedPrice` NatSpec overstates behavior on the stale-fallback branch (cache age not reset)

**Severity:** Informational

**Location:** `contracts/src/ArcoraDexPool.sol:689-714` (comment at `:690-692`; stale branch `:698-704`; fresh branch `:705-710`; unconditional accepted-price update `:711-713`); cross-checked against `_requireCacheNotExpired` at `:190-198`

**Description:** `syncAcceptedPrice` has two branches. On a fresh oracle read it updates `lastValidPrice` + `lastValidPriceAt` and emits `PriceCacheUpdated`, then re-baselines `lastAcceptedPrice` and emits `AcceptedPriceSynced`. On the stale branch it reuses the existing cache as the price and re-baselines `lastAcceptedPrice` without touching `lastValidPriceAt` or emitting `PriceCacheUpdated` (correct, since the cache value did not change). The function comment says it "simultaneously reset[s] both the cache and the lastAcceptedPrice baseline", which is only true on the fresh branch.

**Impact:** No fund or accounting impact. Documentation/operator-expectation drift: an operator invoking `syncAcceptedPrice` during an outage to "reset the cache age" finds `lastValidPriceAt` unchanged (so `_requireCacheNotExpired` still measures from the original cache write), contrary to the comment.

**Scenario:** An operator calls `syncAcceptedPrice` during a stale-oracle incident expecting the cache TTL clock to reset; `lastValidPriceAt` is not refreshed, so the cache can still expire on schedule. Behavior is correct but contradicts the comment.

**Recommendation:** Tighten the comment to state the cache is only refreshed on the fresh-oracle branch and the stale branch only re-baselines `lastAcceptedPrice`. No code change needed.

### [I-7] `setMaxStaleSeconds`/`setDeviation`/`setOracle` in Registry lack NatSpec and have no active-state interaction guard or oracle-decimals re-validation

**Severity:** Informational

**Location:** `contracts/src/ArcoraDexRegistry.sol:59-98` (and `ArcoraDexPool.sol:101-138` for runtime oracle-decimals handling)

**Description:** The Registry mutators (`setOracle`, `setDeviation`, `setMaxStaleSeconds`, `deactivateToken`, `reactivateToken`) carry no NatSpec, unlike the pool's heavily-documented functions. `setOracle` performs an instant feed repoint guarded only by a zero-address and listed check — a security-relevant mutation with zero inline documentation. `listToken` validates token decimals against `IERC20Metadata(token).decimals()`, but the config setters do not re-validate against the oracle's `decimals()`; a `setOracle` to a feed with different decimals is silently accepted (the pool's `_readOracle` normalizes arbitrary oracle decimals at runtime, so not a bug, but undocumented). The config setters gate on "listed" rather than "active", so they can mutate a deactivated-but-listed token's config (benign, arguably intended).

**Impact:** No direct vulnerability (all owner-gated behind the 48h Timelock). Maintainability/auditability gap on the highest-trust mutators: no documented invariants (e.g. that `setOracle` does not re-check decimal compatibility, that deviation/stale bounds match the pool's constructor bounds).

**Scenario:** A future maintainer calls `setOracle` to a feed whose decimals differ from the originally-listed assumptions; nothing documents that the pool reads `oracle.decimals()` at runtime and that this is intended, raising the chance of misconfiguration during a feed migration.

**Recommendation:** Add NatSpec to all Registry mutators documenting their security implications (instant feed repoint, no decimals re-validation on `setOracle`, bound parity with the pool). Consider asserting `oracle.decimals() <=` a sane bound on `setOracle` for defense-in-depth.

### [I-8] Registry `TokenInfo` ABI in the SDK omits the on-chain struct's 5th field (`maxStaleSeconds`) — silent corruption risk on any future field reorder

**Severity:** Informational

**Location:** `packages/sdk/src/abi/registry.ts:4`; `packages/sdk/src/actions/getTokens.ts:64-76`; `packages/sdk/src/types.ts:74-82`; `contracts/src/interfaces/IArcoraDexRegistry.sol:7-13`

**Description:** The on-chain `IArcoraDexRegistry.TokenInfo` struct has 5 fields ending in `uint32 maxStaleSeconds`; the SDK's `registryAbi` declares only the first 4. All five fields are static value types, so a 4-field static-tuple decode reads the first four words positionally and silently ignores the trailing word — `getTokens` decodes `decimals`/`isActive`/`usdOracle`/`maxOracleDeviationBps` correctly today. The bug is latent: `maxStaleSeconds` is not surfaced to integrators, and because viem decodes positionally, any future struct field reorder/insertion would silently mis-decode without throwing.

**Impact:** No current data corruption (verified). Integrators cannot read `maxStaleSeconds`. Future maintainability hazard: a struct-field reorder would silently corrupt decoded registry data with no decode error, potentially mislabeling oracle deviation tolerances in risk UIs.

**Scenario:** A future contract revision reorders `TokenInfo` or inserts a field before `maxOracleDeviationBps`; the SDK's 4-field ABI still decodes without error but reads the wrong word for `maxOracleDeviationBps`; a dApp displays an incorrect deviation cap and a user under-estimates oracle-manipulation exposure.

**Recommendation:** Mirror the full on-chain struct in `registryAbi` (add `uint32 maxStaleSeconds` as the 5th field) and expose it on `TokenInfo` in `types.ts`/`getTokens.ts`. Keeping the ABI struct field-for-field identical to the interface eliminates the positional-decode hazard.

### [I-9] `ensureAllowance` defaults to unlimited (`maxUint256`) approval

**Severity:** Informational

**Location:** `packages/sdk/src/allowance.ts:16, 29`; `packages/sdk/src/actions/swap.ts:30`; `packages/sdk/src/actions/deposit.ts:31`; `contracts/src/ArcoraDexPool.sol:421, 533`

**Description:** `ensureAllowance` defaults `exactApproval = false`, which sends `approve(spender, maxUint256)`; the callers `swap()`/`deposit()` also default `exactApproval` to false. The spender is the immutable, non-upgradeable pool, which pulls only explicit amounts via `safeTransferFrom`, so this follows the standard router-style infinite-approval pattern and the blast radius is bounded. Still, the SDK makes unlimited the default rather than opt-in. _(Related open item: the spender is `client.addresses.pool`, trusted from `addresses.ts` without verification — see Coverage.)_

**Impact:** Standing unlimited allowance on each deposited/swapped token. Bounded because the pool is immutable and pulls explicit amounts, and `exactApproval` is already exposed as an opt-in lever — but it is a larger-than-necessary default for a safety-conscious SDK.

**Scenario:** A dApp integrates `swap()`/`deposit()` with defaults; every user grants the pool a `maxUint256` allowance on first interaction with each token. If a token contract is later compromised (proxy stablecoins) or the pool address is mis-resolved, the standing infinite allowance is exposed.

**Recommendation:** Document the infinite-approval default prominently and consider defaulting `exactApproval` to true for safe-by-default posture, leaving infinite approval as an explicit opt-in for gas-sensitive integrators.

### [I-10] `minOut()` silently disables slippage protection for `slippageBps >= 10000`

**Severity:** Informational

**Location:** `packages/sdk/src/slippage/index.ts:1-5` (callers: `packages/sdk/src/actions/swap.ts:38,50`; `deposit.ts:35`; `withdraw.ts:28`; test: `packages/sdk/test/unit/slippage.test.ts:14-17`)

**Description:** `minOut` returns `0n` for any `slippageBps >= 10_000` (and the quoted value unchanged for `<= 0`). A value of exactly 10000 (intended "100%") yields `minOut = 0` — the swap/deposit/withdraw accepts any output amount, no on-chain slippage floor. There is no upper-bound validation or warning; a dApp mistakenly treating bps as percent gets fully unprotected execution. `slippageBps` is a required arg, so this is limited to caller misuse, and a fractional value `>= 10000` also silently returns `0n`.

**Impact:** A dApp bug or operator typo passing `slippageBps >= 10000` produces a tx with zero MEV/sandwich/oracle-lag protection. Loss is bounded by liquidity and the per-call oracle deviation ratchet, but the SDK provides no guardrail against the foot-gun.

**Scenario:** An integrator wires a slider whose max is mislabeled, or converts a percent field to bps incorrectly, and submits `slippageBps = 10000`; `swap()` builds a tx with `minOut = 0`; an adversary sandwiches within the oracle deviation band and the user receives substantially less than quoted with no revert.

**Recommendation:** Reject or clamp implausible slippage: throw on `slippageBps >= 10000` (or a saner ceiling) rather than silently returning 0, and validate it is a non-negative integer. Optionally emit a warning above e.g. 1000 bps.

### [I-11] `guard-record.mjs` hard-codes Registry/Guard addresses while the feed keeper sources from env — a Registry/Guard migration silently breaks deviation-event recording

**Severity:** Informational

**Location:** `ops/keepalive/guard-record.mjs:29-46` (hard-coded `GUARD`/`REGISTRY`/`TOKENS`) vs `ops/keepalive/multi-feed-push.mjs:42-48` (env-driven feeds); corroborated by `.env.example` (no `REGISTRY`/`GUARD` vars) and `DeployArcoraDexV2.s.sol:73` / `DeployArcoraDexV3.s.sol:74` (Registry redeployed per epoch)

**Description:** `GUARD`, `REGISTRY`, and all seven token addresses are hard-coded constants in `guard-record.mjs`, whereas the price keeper resolves feed addresses from env. The "survives any future oracle migration" comment holds only for the aggregator layer (resolved via `Registry.tokenInfo`) and only because the Registry address itself is pinned. If governance redeploys the Registry (the no-proxy model: redeploy + migrate, confirmed by `DeployArcoraDexV2/V3`) or the `CumulativeDeviationGuard`, this script keeps reading the old contracts with no mismatch check. (Distinct from the retracted H-9, which claimed a current mismatch; this concedes the pin is correct today and raises a forward-looking config-drift concern.)

**Impact:** After a Registry/Guard redeploy, `guard-record` records against stale aggregators (or a dead Guard), so the `PriceObserved`/`CircuitBreakerTripped` event stream the monitor consumes silently points at the wrong contracts. The guard is event-only/advisory (nothing on-chain consumes it), so no funds are at risk, but the monitoring layer operators rely on to detect degraded/diverging oracle states could go blind during exactly the kind of event it exists for.

**Scenario:** A future migration redeploys `ArcoraDexRegistry`; the env-driven price keeper is updated but `guard-record.mjs`'s pinned `REGISTRY` constant is overlooked; the script continues recording against aggregators resolved from the old Registry, so the new pool's real deviations are never observed.

**Recommendation:** Source `REGISTRY` and `GUARD` from env (like the feed addresses), or assert at startup that the configured Registry/Guard match expected on-chain markers and exit non-zero on mismatch, so a migration that forgets to update this script fails loudly.

### [I-12] Faucet returns raw viem/RPC error strings to the client (nonce/gas/internal detail disclosure)

**Severity:** Informational

**Location:** `app/app/api/faucet/route.ts:161-168`

**Description:** On a mid-flight mint failure the route interpolates the raw exception message into the client response: ``error: `Mint failed mid-flight: ${(e as Error).message}. Some tokens may have arrived.` `` (`:164-166`). viem surfaces detailed transport/RPC errors here — nonce values, gas-estimation failures, node error strings — rendered verbatim by the client (`FaucetButton.tsx` generic branch `:205-208`). This is the prior audit's F-8 still present. Low sensitivity on a public testnet faucet, but it leaks faucet-EOA operational state (current nonce, insufficient-funds-for-gas) that aids an attacker timing the partial-mint retry loop ([M-2]).

**Impact:** Information disclosure of RPC/account internals to unauthenticated callers. No direct fund impact (testnet); primarily aids reconnaissance for the faucet-drain path.

**Scenario:** Attacker POSTs and reads the 502 body to learn the faucet EOA's nonce or that it is out of gas, then times concurrent/retry requests for maximum effect.

**Recommendation:** Return a generic client-facing message (e.g. "Faucet mint failed, please retry later") and log the detailed error server-side only. Combine with the `recordClaim`-before-broadcast fix ([M-2]) so an error response cannot also be a free retry signal.

## Gas

### [G-1] Redundant `REGISTRY.tokenInfo()` external calls in the price-resolution stack (2–3× per token per deposit/withdraw/swap leg)

**Severity:** Gas

**Location:** `contracts/src/ArcoraDexPool.sol:104` (`_readOracle` tokenInfo), `:159` (`_readUsdPrice1e18Mut` cache-deviation tokenInfo), `:265` (`_readUsdPrice1e18WithGuard` tokenInfo), `:337` (`_readAndGuardPrice` tokenInfo); struct `contracts/src/interfaces/IArcoraDexRegistry.sol:7-13`

**Description:** The full `TokenInfo` struct is re-read multiple times for the same token within a single price resolution. `_readAndGuardPrice` (`:337`) fetches it solely for `info.maxOracleDeviationBps`, then calls `_readUsdPrice1e18Mut`→`_readOracle` which fetches `tokenInfo` again (`:104`), and on the fresh+cached path fetches it a third time (`:159`). The struct is immutable within a transaction, so all reads after the first are waste. (The struct packs into one storage slot and repeat calls are warm — so the saving is hundreds of gas, not the cold-call figure, but it scales with active-token count in the NAV loops.)

**Impact:** Every deposit reads `tokenInfo` for 1 token via `_readAndGuardPrice` (2–3 calls) plus 1 per active token in the NAV loop; every swap does both legs (up to ~6 redundant struct reads); every `quote()` does 2 per token. Hundreds of gas of pure overhead on the hottest paths.

**Recommendation:** Thread the already-loaded `TokenInfo` struct down the call stack: make `_readOracle`/the deviation guards accept a `TokenInfo memory` parameter that callers fetch once, or have `_readAndGuardPrice`/`_readUsdPrice1e18WithGuard` fetch once and pass `maxOracleDeviationBps` + resolved decimals into a single combined reader, collapsing 2–3 reads per token to 1.

### [G-2] NAV loop re-derives `isActive` via a separate `REGISTRY.isActive()` call that `REGISTRY.tokenInfo()` already returns

**Severity:** Gas

**Location:** `contracts/src/ArcoraDexPool.sol:356-368` and `:370-383` (redundant `REGISTRY.isActive` at `:364`/`:379` vs `REGISTRY.tokenInfo` at `:104` reached via `_readUsdPrice1e18Mut/View`); registry `contracts/src/ArcoraDexRegistry.sol:20-26`; interface struct `contracts/src/interfaces/IArcoraDexRegistry.sol:7-13`

**Description:** Each NAV-loop iteration calls `REGISTRY.isActive(t)` and then, for active tokens, calls `_readUsdPrice1e18Mut/View(t)` which internally calls `_readOracle(t)`→`REGISTRY.tokenInfo(t)`. `TokenInfo` already carries the `isActive` flag (and `_readOracle` re-checks it at `:105`), so the standalone `isActive(t)` call is fully redundant — two cross-contract calls where one suffices.

**Impact:** One extra cross-contract CALL + 1 SLOAD per active token on every deposit/withdraw NAV pass and every NAV-based quote, multiplied across all active tokens.

**Recommendation:** Fetch `TokenInfo` once per loop iteration (or expose a registry view returning `(active, info)` together) and branch on `info.isActive` locally instead of a separate `isActive()` call, then pass that struct into the price reader to also eliminate G-1's redundancy. Preserve the skip-vs-revert semantics (NAV loop `continue`s on inactive at `:364`; `_readOracle` reverts `TokenNotActive` at `:105`) by branching on the locally-loaded `info.isActive`.

### [G-3] Oracle `decimals()` re-fetched on every fresh read instead of cached

**Severity:** Gas

**Location:** `contracts/src/ArcoraDexPool.sol:124-127` (call at `:124`; also `:110`, `:147`, `:205`); `contracts/src/oracle/OracleAggregator.sol:32, 67-68`; `contracts/src/testnet/MockChainlinkFeedV2.sol:16, 54-55`; `contracts/src/interfaces/IArcoraDexRegistry.sol:7-13`

**Description:** On every fresh oracle read `_readOracle` calls `info.usdOracle.decimals()` (`:124`) — a second cross-contract CALL on top of `latestRoundData()`. For the in-repo oracles (`OracleAggregator.DECIMALS` and `MockChainlinkFeedV2.decimalsValue` are both immutable) this value never changes, yet it is fetched fresh on every price resolution, including once per active token in the NAV loop. (The redundant call only occurs on the fresh-read path, which is the normal operating mode.)

**Impact:** One extra cross-contract CALL per fresh price read, multiplied by the number of active tokens in the NAV loop on every deposit/withdraw and each swap/quote leg.

**Recommendation:** Persisting oracle decimals requires trusting it is fixed, which is unsafe for an arbitrary feed if `setOracle` repoints. Safer optimization: store the oracle's `decimals` in the Registry `TokenInfo` at `listToken`/`setOracle` time and pass it through, removing the per-read `decimals()` call. If keeping the live read, at minimum avoid re-reading it for the same oracle within one tx.

### [G-4] Loop counter increment not wrapped in `unchecked` in NAV loops

**Severity:** Gas

**Location:** `contracts/src/ArcoraDexPool.sol:358` and `:373`

**Description:** Both NAV loops use `for (uint256 i = 0; i < n; i++)`. Under Solidity 0.8.x (`pragma ^0.8.26`, solc pinned 0.8.26) the `i++` carries a built-in overflow check on every iteration. Since `i` is bounded by `n = REGISTRY.tokensLength()` and cannot overflow uint256, the check is dead weight; the optimizer does not remove it.

**Impact:** ~30–40 gas per loop iteration saved by removing the overflow check; pre-increment saves a few more. Minor per-iteration but on a hot path executed on every deposit/withdraw and NAV view.

**Recommendation:** Rewrite both loops (`_totalReservesUSDMut` `:358`, `totalReservesUSD` `:373`) as `for (uint256 i = 0; i < n;) { ...; unchecked { ++i; } }`.

### [G-5] Unused declared errors `InvalidOracleRound`/`InvalidOracleTimestamp` in `IArcoraDexPool`

**Severity:** Gas _(code-cleanliness; effectively Informational)_

**Location:** `contracts/src/interfaces/IArcoraDexPool.sol:22-23` (declarations); `contracts/src/ArcoraDexPool.sol:101-138` (`_readOracle` folds bad-round/bad-timestamp to `isFresh = false`), `:181`/`:198`/`:230` (only `NoValidPrice` reverts)

**Description:** `IArcoraDexPool` declares `error InvalidOracleRound(address,uint80,uint80)` and `error InvalidOracleTimestamp(address,uint256)`, but `ArcoraDexPool` never reverts with either — `_readOracle` folds all bad-round and bad-timestamp conditions into `isFresh = false` and falls through to cache (by design, INV-6). A grep of `src` confirms no `revert InvalidOracleRound`/`InvalidOracleTimestamp` anywhere. These are dead error definitions. (Prior finding H-3 added these exact cases to the SDK's `parseContractError`, so the SDK now decodes errors the contract can never emit — harmless but unreachable.)

**Impact:** No runtime impact. Misleading API/ABI surface: integrators (and the SDK) handle revert selectors the pool will never produce, and the declarations imply a revert-on-bad-oracle behavior that contradicts the actual cache-fallback design.

**Recommendation:** Either remove the two unused error declarations from `IArcoraDexPool`, or add a comment documenting they are reserved/historical, and reconcile the SDK (H-3) expectation that the pool reverts with them.

> **Code-quality note (Informational):** `contracts/src/testnet/MintableERC20.sol:5,9,23-25` uses single-step `Ownable` while every other ownable contract in `src` uses `Ownable2Step` (`ArcoraDexPool.sol:18`, `ArcoraDexRegistry.sol:13`, `OracleAggregator.sol:23`, `CumulativeDeviationGuard.sol:31`, `MockChainlinkFeedV2.sol:12`). The `TransferTokenOwnershipToFaucet.s.sol:35` handoff is therefore a single-step, irreversible transfer with no `acceptOwnership` typo guard. Testnet-only (the token is a documented mock); switch to `Ownable2Step` for uniformity or document the deliberate exception. Likewise `contracts/script/DeployArcoraDex.s.sol:23` and `SmokeArcoraDex.s.sol:13` resolve the broadcaster key from `vm.envUint("PRIVATE_KEY")` while all 12 other in-scope scripts use `DEPLOYER_PRIVATE_KEY` — an Informational env-var-naming footgun on two testnet-only, superseded scripts; rename for consistency.

---

## Coverage & Limitations

This is a **static source review**. None of the findings were re-tested on-chain against the live deployment; PoCs referenced by verifiers were local Foundry reproductions that were not retained. The audit ran in two passes (broad fan-out + a targeted gap-fill on the completeness-critic's flags). The following records what the second pass **resolved**, **refuted**, and what remains **open**.

**Resolved by the second pass (now formal findings):** oracle single-writer collapse → **[H-2]**; public-mnemonic governance → **[M-1]**; open Timelock executor → **[L-8]**; unbounded `tokens[]` growth → **[L-9]**; fee-on-transfer accounting → **[L-10]**; faucet partial-mint retry, per-instance rate-limit, CSRF fail-open, raw-error disclosure → **[M-2]/[M-3]/[L-11]/[I-12]**.

**Investigated and refuted / not confirmed:**

- **Same-tx oracle/cache divergence in `withdraw()`** (recon hotspot, `ArcoraDexPool.sol:435-491`): the concern that `navBefore` (priced via `_totalReservesUSDMut()`, which mutates the cache for all tokens) could diverge from the `tokenOut` price used for the payout leg (`_readAndGuardPrice(tokenOut)`) within the same call was investigated and **could not be turned into an exploitable PnL path** — the per-token ratchet and consistent cache mutation ordering were not shown to permit redeem-at-one-price/exit-at-another within a single transaction. Recommended to keep as a watch item, but no confirmed finding.

**Still open — recommended follow-ups (not exhaustively examined):**

- **`MintableERC20` mint authorization economics.** Whether `mint` is owner-only and whether the faucet server key equals the token owner; if so, faucet-key compromise mints arbitrary supply of an oracle-priced asset into the shared pool (compounds with H-2). The economic impact of unbounded minting against a fixed oracle price (vs an AMM-curve loss) was not quantified.
- **Invariant suite is structurally weak.** `contracts/test/ArcoraDexPool.invariant.t.sol` + `handlers/PoolHandler.sol` use **static** oracle prices (never call `setAnswer`), never advance `block.timestamp`, and never drive `pause`/`deactivate`/`reactivate`/`syncAcceptedPrice`; there is **no per-LP value-conservation invariant**. The confirmed economic findings (H-1, I-1, L-10) and the same-tx oracle hotspot are therefore not exercised. Add a price-mutating handler action, a strict NAV/redemption-conservation invariant, and a "no positive PnL from atomic deposit+oracle-move+withdraw" invariant.
- **`protocolFeesAccrued` vs `reserves` conservation under cache-fallback / price divergence** (`withdraw` `:470/:484/:487`): not formally proven that `reserves[tokenOut]` cannot underflow or be over-credited when the oracle is in cache-fallback and `priceOut` diverges from the NAV-loop price.
- **V1→V2→V3 migration state-carryover** (`DeployArcoraDexV2/V3.s.sol`, `MigrateFeedsToV2.s.sol`): a fresh `MockChainlinkFeedV2` per token seeds `initialAnswer` from the old oracle but the pool's `lastValidPrice`/`lastAcceptedPrice` cache is not reset and the new feed's `roundId` restarts at 1; cross-feed `roundId`/cache-deviation behavior after a feed swap was not verified end-to-end.
- **SDK hooks/subscriptions error propagation.** The [L-1] quote-revert bypass was examined at the action layer only; the React hooks (`useSwap`/`useQuote*`) and subscriptions (`subscribePoolStats.ts`, `subscribeSwaps.ts` — which **silently swallow all errors**) were not, so stuck-stale-data UX and reorg/event-replay double-counting (no `(txHash, logIndex)` dedupe / removed-log handling in `watchContractEvent`) are open.
- **`addresses.ts` trust.** `ensureAllowance` (`exactApproval=false`) grants `maxUint256` to `client.addresses.pool` with no verification it is the canonical pool; a wrong/overridden pool address in SDK config silently grants unlimited approval to an attacker-controlled spender. ([I-9] covers the default; the address-trust path is open.)
- **`guard-record.mjs` tx/fetch hardening.** The [L-3]/[L-4] defects (no request timeout, no nonce/gas-ceiling, no confirmation timeout) also apply to `guard-record.mjs:118`.
- **`CumulativeDeviationGuard` → off-chain monitor → Pause-Guardian pipeline.** `record` is treated as event-only on the assumption nothing on-chain consumes it; this was asserted but not exhaustively grepped across the whole tree. The off-chain pipeline (does the monitor re-validate against an independent feed before paging the guardian? can a permissionless spammed event trigger or suppress a pause?) was not traced end to end.

## Prior Audit Status

The prior audit's High/Medium findings (recorded in the recon map as `H-1…H-10`, `M-1…M-16`, plus `C-*`/`OPS-*` items) were verified against current source and confirmed remediated, **with one regression**:

- **Verified fixed (no regression):** prior `H-1`–`H-4` (cache staleness ceiling + SDK error handling), `H-5`–`H-7` (app chain def, faucet TOCTOU/Origin), `H-8`/`H-10` (keeper env race, secondary-feed `.env`), `M-2` (TRYC/BRLC deviation tightened to 200 bps), `M-3` (V2 monotonic roundId), `M-4` (deviation-guard event-only/R3), `M-5`/`M-7`/`M-8` (SDK), `M-9`–`M-12` (app), `M-13`/`M-15`/`M-16` + OPS-A/OPS-B (CI), `C-5` (monotonic roundId via V2). The previously retracted items (`OPS-1`, `H-9`, `M-6`, two `.env`-leak false positives) were not re-reported.
- **Regression / stale-remediation found:** prior **`M-1`** (zero-salt P3 batch griefing) is recorded as "fixed (PR #55; retire/backport old scripts)", but the remediation was **documentation-only** — see **[L-7]** above. The retired P3 scripts still compile and run with `SALT = bytes32(0)` against the live Registry/Timelock and would, if re-run, both re-introduce the griefing and regress the Registry oracle pointers to the pre-fix V1 aggregators (re-opening `C-1`/`C-2`/`C-5`). This is the one prior finding whose fix does not hold up under verification.
- **Doc-vs-code drift to reconcile:** `invariants.md` INV-7 still describes the old hardcoded-`roundId=1` aggregator behavior, which contradicts the current monotonic-roundId implementation; and the SDK still decodes `InvalidOracleRound`/`InvalidOracleTimestamp` (see **[G-5]**) which the contract can no longer emit.

> **Note on numbering:** finding IDs in this report (`H-1`/`H-2`, `M-1`–`M-3`, `L-1`–`L-11`, `I-1`–`I-12`, `G-1`–`G-5`) are **local to this audit** and do **not** correspond to the prior audit's identically-named IDs referenced in this section.
