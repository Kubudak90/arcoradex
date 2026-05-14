# Phase 2 — Governance Migration Rollout (Testnet Rehearsal)

**Date:** 2026-05-14
**Branch:** `phase2/governance-rollout` (merged to main as PR #N)
**Spec:** `docs/superpowers/specs/2026-05-14-phase2-governance-design.md`
**Plan:** `docs/superpowers/plans/2026-05-14-phase2-governance.md`
**Roadmap parent:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §4

## Why migrate

P1 closed contract-level economic footguns. P2 closes the governance footgun (audit finding #3, HIGH): the deployer EOA was a single point of failure for every owner action across Pool, Registry, and the 7 feeds. P2 migrates ownership to a Safe 3/5 governance multisig fronted by an OZ `TimelockController` (48 h delay), plus a separate Safe 2/3 Pause Guardian that bypasses the timelock for emergency pause/unpause only.

**Scope: testnet rehearsal only. Mainnet rotation deferred to P5 with real signers + hardware wallets.**

## New V3 protocol addresses

The P1 V2 pool gained no new storage in P2 itself, but the `pauseGuardian` role addition required a fresh redeploy. V3 reuses all existing tokens and `MockChainlinkFeedV2` feeds from the 2026-05-10 cutover; only the Pool + Registry + LP are new.

| Contract           | Address                                       |
|--------------------|-----------------------------------------------|
| ArcoraDexRegistry  | `0x9914436e5245bf3c0d4d4338e0a8b8f5ab5505ab`  |
| ArcoraDexPool      | `0x1ce1ef94e7ebe70727bd69003d61a3f0c9a331bc`  |
| ArcoraDexLP        | `0x17B47173C457069E53B3B75Ef42773041B79523e`  |

Initial NAV: **$640.84** (lower than P1's $700 because deployer's TRYC balance was partially consumed in P1's Task 7 redeploy; SEED_TRYC reduced from 4.39B to 1.8B accordingly).

## Governance addresses

| Contract               | Address                                       |
|------------------------|-----------------------------------------------|
| Safe singleton (v1.4.1)| `0x93e259adbee7b1bf16619b39905f1154d4025f10`  |
| SafeProxyFactory       | `0x5f1ad56dc1d90688113baf80fc3572cd441f3cc3`  |
| Governance Safe (3/5)  | `0x715f669D79Cc72d6685F8724c0B86f7B53d7e624`  |
| Pause Guardian Safe (2/3) | `0x39500e45935f36CfcEb826590aaE97226Ac6640D` |
| TimelockController     | `0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83`  |

## Test signers (testnet-only — DO NOT use on mainnet)

Derived via Forge `vm.deriveKey` from the **standard Foundry test mnemonic**:

```
test test test test test test test test test test test junk
```

(The plan originally specified a project-specific placeholder mnemonic but those words weren't valid BIP-39; the Task 5 implementer correctly substituted the canonical Foundry test mnemonic.)

| Role | Index | Address |
|------|-------|---------|
| gov1 | 0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` |
| gov2 | 1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` |
| gov3 | 2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` |
| gov4 | 3 | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` |
| gov5 | 4 | `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65` |
| pg1  | 5 | `0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc` |
| pg2  | 6 | `0x976EA74026E726554dB657fA54763abd0C3a0aa9` |
| pg3  | 7 | `0x14dC79964da2C08b23698B3D3cc7Ca32193d9955` |

Derivation path: BIP-44 (`m/44'/60'/0'/0/<index>`), Foundry's `vm.deriveKey` default.

Each signer was funded with 0.1 ARC at deploy time (sufficient for ≥10 Safe-confirmation transactions on Arc testnet at current gas prices).

**Operational note:** These addresses already have ~49 bytes of code on Arc testnet (legacy of well-known test-mnemonic occupation from prior projects). The deploy script uses `.call{value:}` rather than `.transfer()` to bypass the 2300-gas stipend limit; this works correctly with code-bearing receivers.

## Ownership matrix (post-migration, verified on-chain)

| Contract            | Owner |
|---------------------|-------|
| ArcoraDexPool V3       | TimelockController (`0x36444f65...`) |
| ArcoraDexRegistry V3   | TimelockController (`0x36444f65...`) |
| ArcoraDexLP V3         | (auto-bound to Pool V3, no separate owner) |
| 7× MockChainlinkFeedV2 | Governance Safe (`0x715f669D...`) — no timelock, instant writer rotation |

Pool V3 `pauseGuardian()` = `0x39500e45935f36CfcEb826590aaE97226Ac6640D` (Pause Guardian Safe).
Timelock `getMinDelay()` = `172800` (48 hours).

## Frozen / deprecated pools

| Contract           | Address                                       | State          |
|--------------------|-----------------------------------------------|----------------|
| v0.7 Pool          | `0x3051d24D771bAF44031571544a9159578035D0c5`  | paused 2026-05-12 (cutover §3) |
| V2 Pool (P1)       | `0xb01a7a4da9986e9eb197d98242cf74d15f1f648b`  | **paused 2026-05-14** (tx `0x6e25c5da9ac55392f8b92c0d10353d3f25454b256e2a46353f2d4ba2e411a5c5`) |
| V2 Registry (P1)   | `0x8748fc38718dd2985e2680e7fc122c7946fb2ad0`  | orphaned (no on-chain pause) |
| V2 LP (P1)         | `0xfD431f8101405DD3781F92056347bd4D323c97c7`  | orphaned |

## Per-action operator runbook

### Emergency pause (Pause Guardian Safe — instant)

Two of {pg1, pg2, pg3} sign `pool.pause()` via Safe. Any address relays the Safe transaction. Pool is paused within one block; no 48 h delay.

Concrete steps with the test mnemonic:
1. Derive pg1, pg2 keys: `cast wallet derive -m "test test test test test test test test test test test junk" -i 5` and `... -i 6`.
2. Build the `safeTxHash` for `(pool, 0, encodeCall(pause, ()), Call, ...)`.
3. Sign with both keys via `cast wallet sign`.
4. Sort signatures by recovered address ASC; concatenate as `r||s||v`.
5. Submit `safe.execTransaction(...)` from any address with ARC.

In an emergency, the operator scripts this end-to-end; for testnet rehearsal the `P2GovernanceTest` suite (in-memory) is the verifying demonstration.

### Governance action (Timelock 48 h delay)

To change e.g. `swapFeeBps` from 5 → 10:

1. Three of {gov1..gov5} sign a Safe tx calling `timelock.schedule(pool, 0, encodeCall(setSwapFeeBps, (10)), 0, 0, 172800)`.
2. Wait 48 hours.
3. Anyone executes `timelock.execute(pool, 0, encodeCall(setSwapFeeBps, (10)), 0, 0)` (executor role is open).

### Feed writer rotation (Governance Safe direct — instant)

If a keeper EOA is compromised:

1. Three of {gov1..gov5} sign a Safe tx calling `<feed>.setWriter(newKeeperEOA)`.
2. Any address relays the Safe transaction.

No timelock delay. The 7 feeds are owned directly by Governance Safe specifically to enable this rapid response.

### Adding a new token to Registry

1. Three of {gov1..gov5} sign `timelock.schedule(registry, 0, encodeCall(listToken, (token, decimals, oracle, devBps, staleSeconds)), 0, 0, 172800)`.
2. Wait 48 h.
3. Anyone executes the matching `timelock.execute(...)`.

For mainnet, prepend an off-chain 7-day public announcement before scheduling — `setOracle` and `listToken` are the most critical governance actions.

## Dry-run coverage

The full governance lifecycle is exercised in-memory by `contracts/test/governance/P2Governance.t.sol`:
- `test_setup_state_correct` — verifies the migrated state after a fresh deploy
- `test_governance_proposes_executes_setSwapFeeBps` — propose, fail-before-delay, warp 48 h, execute, assert
- `test_governance_proposes_executes_setMaxStaleSeconds` — same shape on Registry
- `test_pauseGuardian_canPauseInstantly` / `_canUnpauseInstantly` — guardian bypasses timelock
- `test_deployerEOA_cannotPause_post_migration` — deployer revert with `NotAuthorized`
- `test_executor_open_anyone_can_execute_after_delay` — open executor role works

All 7 pass. Full Foundry suite: **101 tests, 0 failed.**

## Sanity ping (live testnet, 2026-05-14)

- V2 P1 pool `0xb01a7a4da9...` → `paused()` = `true` after our Task 10 tx
- V3 pool `0x1ce1ef94e7...` → `paused()` = `false`, `owner()` = Timelock, `pauseGuardian()` = Pause Guardian Safe, `MIN_HOLD_SECONDS` = 3600
- Direct deployer call `pool.pause()` on V3 → reverts `NotAuthorized` (selector `0xea8e4eb5`) ✓
- All 7 feeds → `owner()` = Governance Safe ✓
- Timelock `getMinDelay()` = 172800 (48h) ✓

Live propose-wait-execute cycle on testnet is not exercised in-session (48 h real-time wait). Foundry dry-run tests are the audit-quality demonstration. If a live ceremony is desired before P3, the operator can schedule a no-op action (e.g. `setSwapFeeBps(5)` — the current value, idempotent) from the Governance Safe and execute 48 h later.

## Downstream tasks (not in this PR)

- [ ] Update SDK to point at new V3 Pool / Registry / LP addresses
- [ ] Update Vercel app env (`NEXT_PUBLIC_POOL_ADDR`, `NEXT_PUBLIC_REGISTRY_ADDR`)
- [ ] Update VPS keeper `.env` if any addresses changed — feeds reused so `FEED_*` unchanged; only the pool address (used for off-chain monitoring) differs
- [ ] Update auto-memory `arcoradex_role_eoas.md` with V3 addresses + governance addresses
- [ ] Announce in ops channel
- [ ] Track for P3:
  - TRYC/BRLC `maxOracleDeviationBps` tightening (currently 5000, audit-residual from P1)
  - Multi-source oracle aggregator (Chainlink + Pyth or TWAP fallback)
  - Cumulative deviation circuit breaker

## Rollback

The deployer EOA still controls 0 contracts directly post-migration. Reverting ownership requires a governance proposal (48 h delay). For emergency response within 48 h, only the Pause Guardian can act — it can pause the pool, halting user activity while the operator coordinates a recovery proposal.

For mainnet, the design will include a Sentinel module: after a multi-week no-activity timer, ownership can be returned to a designated recovery address. **Not implemented in this testnet rehearsal — out of scope.**

For testnet specifically, rollback is trivial: deploy a new V4 pool with deployer ownership and update SDK. The V3 stack remains paused/unowned but functional for inspection.

## Phase 2 status

✅ Pool `pauseGuardian` role added (Task 3, commit `89f4470`)
✅ SafeSigHelpers library (Task 4, commit `893cc13`)
✅ Full-stack Foundry dry-run suite (Task 5, commit `fce2f71`)
✅ DeployArcoraDexV3 script (Task 6)
✅ DeployGovernanceP2 script (Task 7)
✅ V3 redeploy live (Task 8)
✅ Governance stack live (Task 9)
✅ V2 P1 pool paused, V3 deployer-EOA revert verified (Task 10)
✅ Rollout doc (this file)
⏭ Next: P3 oracle hardening
