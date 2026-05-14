# Phase 2 — Governance Migration Design Spec

**Date:** 2026-05-14
**Status:** Brainstorming complete — pending user review, then writing-plans
**Authors:** Hüseyin Arslan + Claude
**Roadmap parent:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §4
**Audit context:** Closes audit finding #3 (HIGH, mainnet blocker): deployer EOA is a single point of failure for every owner-controlled action on Pool, Registry, and feeds.

**Scope:** Testnet rehearsal only. Mainnet rotation deferred to P5 with real signers + hardware wallets.

---

## 1. Context & Motivation

After P1 (PR #6 + PR #7) the new ArcoraDexPool, ArcoraDexRegistry, and ArcoraDexLP are live on Arc testnet at:
- Pool `0xb01a7a4da9986e9eb197d98242cf74d15f1f648b`
- Registry `0x8748fc38718dd2985e2680e7fc122c7946fb2ad0`
- LP `0xfD431f8101405DD3781F92056347bd4D323c97c7`

All three (plus the seven `MockChainlinkFeedV2` instances from the 2026-05-10 cutover) are owned by the deployer EOA `0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b`. A compromise of that single key would allow an attacker to: change oracles to attacker-controlled feeds, set deviation caps to bypass economic protections, sync `lastAcceptedPrice` to any value, withdraw protocol fees, pause/unpause, rotate the feed writers, and effectively drain the pool over multiple transactions.

P2 closes this by migrating ownership to a Safe 3/5 governance multisig fronted by an OpenZeppelin `TimelockController` (48 h minimum delay), plus a separate Safe 2/3 Pause Guardian that bypasses the timelock for emergency `pause()` / `unpause()` only. Pool requires a small contract change to expose a `pauseGuardian` role; redeploy follows.

This phase is a **testnet rehearsal**: signers are eight throwaway test wallets derived from a documented BIP39 mnemonic. Mainnet rotation (real signer identities + hardware wallets + final multisig deployment) is scheduled for P5.

---

## 2. Goals & Non-Goals

### Goals

- Replace the deployer EOA as owner of Pool, Registry, and feeds with a multisig + timelock governance structure.
- Preserve fast emergency response: `pause()` and `unpause()` must remain executable within minutes, not 48 h.
- Demonstrate the full governance lifecycle end-to-end on testnet:
  - Propose a parameter change via governance multisig → wait 48 h → execute via timelock → verify on-chain effect.
  - Pause the pool via guardian multisig → verify pool is paused immediately, without timelock.
  - Confirm that legacy deployer-EOA direct calls (e.g. `pool.pause()`, `pool.setSwapFeeBps(...)`) revert after migration.
- Establish a reproducible deploy script for the mainnet equivalent (with signer/key inputs swapped at deploy time).

### Non-Goals

- Real signer identities or hardware wallets (deferred to P5).
- Mainnet deployment of the governance contracts (deferred to P5).
- Custom Safe modules beyond standard OZ `TimelockController` (out of scope; standard composition is sufficient).
- Per-action delay variation (one tier, 48 h minDelay for everything except pause; critical actions like `setOracle` use off-chain pre-announcement discipline for longer effective notice).
- On-chain DAO token / Compound-style governor (not in scope for first mainnet; Safe-based governance is sufficient at our scale).
- Migration of LP token ownership (LP has no separate owner; it is permissioned to mint/burn by Pool only).

---

## 3. Architecture

```
            ┌─────────────────────────────────┐
            │     Governance Safe 3/5         │  5 test signers (gov1..gov5)
            │     Proposer role on Timelock   │
            └────────────┬────────────────────┘
                         │ propose / cancel
                         ▼
            ┌─────────────────────────────────┐
            │   OZ TimelockController         │  minDelay = 48h
            │   Executor role = open (0x0)    │  ADMIN = Timelock (self-admin)
            └────────────┬────────────────────┘
                         │ execute() after 48h
                         ▼
                ┌────────┴───────────────┐
                │                        │
                ▼                        ▼
       ArcoraDexPool             ArcoraDexRegistry
       owner = Timelock          owner = Timelock
       pauseGuardian ◄───┐       (no guardian — admin-only changes)
                         │
            ┌────────────┴────────────┐
            │  Pause Guardian Safe 2/3 │  3 test signers (pg1..pg3)
            │  Bypasses timelock      │  Permission: pause / unpause only
            └─────────────────────────┘

                                  ┌─────────────────────────┐
                                  │  Governance Safe 3/5    │  ◄─── ALSO owns
                                  └────────────┬────────────┘
                                               │ direct (no timelock)
                                               ▼
                                        7× MockChainlinkFeedV2
                                        (writer rotation must be fast)
```

### Ownership matrix after migration

| Contract            | Owner                | Notes                                                        |
|---------------------|----------------------|--------------------------------------------------------------|
| ArcoraDexPool       | TimelockController   | 48h delay on all owner actions; pauseGuardian for instant pause |
| ArcoraDexRegistry   | TimelockController   | 48h delay on all owner actions (`listToken`, `setOracle`, `setDeviation`, `setMaxStaleSeconds`, `deactivateToken`, `reactivateToken`) |
| ArcoraDexLP         | (auto-bound to Pool) | No separate owner; Pool is the immutable MINTER              |
| MockChainlinkFeedV2 × 7 | Governance Safe (direct) | No timelock: `setWriter` must execute instantly during an emergency (writer key compromise scenario) |

### Action routing matrix

| Action                                  | Route                                              | Effective delay |
|-----------------------------------------|----------------------------------------------------|-----------------|
| `pause()` / `unpause()`                 | Pause Guardian Safe → Pool                         | 0 (instant)     |
| `setSwapFeeBps`                         | Gov Safe → Timelock → Pool                         | 48 h            |
| `setProtocolFeeShareBps`                | Gov Safe → Timelock → Pool                         | 48 h            |
| `withdrawProtocolFees`                  | Gov Safe → Timelock → Pool                         | 48 h            |
| `syncAcceptedPrice`                     | Gov Safe → Timelock → Pool                         | 48 h            |
| `setPauseGuardian`                      | Gov Safe → Timelock → Pool                         | 48 h            |
| `transferOwnership` (any owned contract)| Gov Safe → Timelock → target                       | 48 h            |
| `listToken`                             | Gov Safe → Timelock → Registry                     | 48 h (+ off-chain 7 d pre-announce in mainnet) |
| `setOracle`                             | Gov Safe → Timelock → Registry                     | 48 h (+ off-chain 7 d pre-announce in mainnet) |
| `setDeviation`, `setMaxStaleSeconds`    | Gov Safe → Timelock → Registry                     | 48 h            |
| `deactivateToken`, `reactivateToken`    | Gov Safe → Timelock → Registry                     | 48 h            |
| Feed `setWriter` (rotate keeper)        | Gov Safe → Feed (direct, no timelock)              | 0 (instant — emergency) |
| Feed `transferOwnership`                | Gov Safe → Feed (direct)                           | 0 (rare)        |

---

## 4. Contract Change: `pauseGuardian` role on Pool

Adding a guardian role requires modifying `ArcoraDexPool.sol`. The change is small and additive (one new storage slot + one new modifier + one setter).

### Source changes

**Storage** (after `paused`):
```solidity
address public pauseGuardian;
```

**New modifier** (after `whenNotPaused`):
```solidity
modifier onlyOwnerOrGuardian() {
    if (msg.sender != owner() && msg.sender != pauseGuardian) revert NotAuthorized();
    _;
}
```

**New error** (in interface):
```solidity
error NotAuthorized();
```

**New event** (in interface):
```solidity
event PauseGuardianUpdated(address indexed prev, address indexed next);
```

**Function changes:**
```solidity
function pause()   external override onlyOwnerOrGuardian { paused = true;  emit Paused(msg.sender); }
function unpause() external override onlyOwnerOrGuardian { paused = false; emit Unpaused(msg.sender); }
```

**New setter:**
```solidity
function setPauseGuardian(address newGuardian) external onlyOwner {
    if (newGuardian == address(0)) revert ZeroAddress();
    emit PauseGuardianUpdated(pauseGuardian, newGuardian);
    pauseGuardian = newGuardian;
}
```

### Interface change

In `IArcoraDexPool.sol`:
- Add `function pauseGuardian() external view returns (address);`
- Add `function setPauseGuardian(address newGuardian) external;`
- Add `event PauseGuardianUpdated(address indexed prev, address indexed next);`
- Add `error NotAuthorized();`

### Test additions (target: 3 tests in `ArcoraDexPool.t.sol`)

- `test_pauseGuardian_canPauseUnpause`: set guardian, pause from guardian, expect paused; unpause from guardian, expect not paused.
- `test_pauseGuardian_setterOnlyOwner`: non-owner call to `setPauseGuardian` reverts; owner succeeds; event emitted.
- `test_pause_revertsForUnauthorized`: third-party caller (neither owner nor guardian) reverts `NotAuthorized` when calling `pause()` or `unpause()`.

### Storage layout impact

`pauseGuardian` (160-bit address) goes into a new slot. Existing storage:
- slot 0: Ownable2Step `_owner`
- slot 1: Ownable2Step `_pendingOwner`
- slot 2: ReentrancyGuard `_status`
- slot 3: `reserves` mapping
- slot 4: `protocolFeesAccrued` mapping
- slot 5: `lastAcceptedPrice` mapping
- slot 6: `lastValidPrice` mapping (P1)
- slot 7: `lastValidPriceAt` mapping (P1)
- slot 8: `lastMintAt` mapping (P1)
- slot 9: `swapFeeBps` + `protocolFeeShareBps` + `paused` (packed)
- slot 10 (new): `pauseGuardian`

No collision. Backwards-compatible additive change.

---

## 5. Test Signer Derivation

Eight throwaway test wallets are derived deterministically from a documented BIP39 mnemonic. The mnemonic is plain-text in the rollout doc and source comments — explicitly tagged as testnet-only.

### Mnemonic

```
arcora p2 testnet rehearsal twentyone twentytwo twentythree twentyfour twentyfive twentysix twentyseven twentyeight
```

(12 words; this is a placeholder set — Foundry's `vm.deriveKey(mnemonic, index)` will derive the keys.)

### Index-to-role mapping

| Index | Role                     | Identifier |
|-------|--------------------------|------------|
| 0     | Governance signer        | gov1       |
| 1     | Governance signer        | gov2       |
| 2     | Governance signer        | gov3       |
| 3     | Governance signer        | gov4       |
| 4     | Governance signer        | gov5       |
| 5     | Pause Guardian signer    | pg1        |
| 6     | Pause Guardian signer    | pg2        |
| 7     | Pause Guardian signer    | pg3        |

### Funding

Each signer receives 0.1 ARC from the deployer at deploy time (sufficient for ≥10 Safe-confirmation transactions on Arc testnet at current gas prices).

### Mainnet rotation (P5)

In P5, the mainnet deploy script accepts the eight signer addresses as `vm.envAddress(...)` inputs instead of deriving from a mnemonic. Real hardware-wallet addresses are passed in. The testnet mnemonic and its derived addresses are never used on mainnet.

---

## 6. Deploy Scripts

P2 ships two Forge scripts that run sequentially.

### 6.1 `DeployArcoraDexV3.s.sol` — Pool/Registry/LP redeploy with `pauseGuardian` role

The pauseGuardian storage addition forces a Pool redeploy (the contract is not proxy-upgradable). Registry has no contract change but is redeployed alongside for symmetry (fresh deploy with the same `maxStaleSeconds` schema as P1). Feeds are reused from the 2026-05-10 cutover. Bootstrap is identical to P1 Task 7 (~$700 NAV).

Steps:

1. Read `DEPLOYER_PRIVATE_KEY` from env; broadcast as deployer.
2. Deploy new `ArcoraDexRegistry` (deployer as initial owner).
3. Deploy new `ArcoraDexPool` (registry, `swapFeeBps=5`, `protocolFeeShareBps=2500`, deployer as initial owner). LP token is auto-deployed by the Pool constructor.
4. Re-list all 7 stables on the new Registry using existing token + feed addresses with the per-token `maxStaleSeconds` defaults established in P1.
5. Bootstrap ~$100 USD-equivalent per token from deployer's existing balances (identical amounts to P1 Task 7).
6. Log new addresses.
7. (Operator-driven follow-up) Pause the P1 pool `0xb01a7a4da9986e9eb197d98242cf74d15f1f648b` via direct deployer call.

Output addresses (to be captured at deploy time): `REGISTRY_V3`, `POOL_V3`, `LP_V3`.

### 6.2 `DeployGovernanceP2.s.sol` — Governance stack + ownership transfers

Runs AFTER `DeployArcoraDexV3.s.sol` (consumes its output addresses via env vars).

1. Read `DEPLOYER_PRIVATE_KEY`, `POOL_V3`, `REGISTRY_V3` from env.
2. Derive 8 signer addresses from the testnet mnemonic (in-script, no env vars).
3. Fund each signer with 0.1 ARC (8 transfers).
4. Deploy Safe singleton + factory (use Safe's canonical factory address on Arc testnet if available; otherwise deploy locally).
5. Deploy `Governance Safe` (3/5, owners = gov1..gov5, threshold = 3) via the factory.
6. Deploy `Pause Guardian Safe` (2/3, owners = pg1..pg3, threshold = 2) via the factory.
7. Deploy `TimelockController`:
   - `minDelay = 0` (setup-mode value; locked down at step 13)
   - `proposers = [GovernanceSafe]`
   - `executors = [0x0000...]` (open executor)
   - `admin = address(0)` (no centralized admin; Timelock self-administers via Governance Safe proposals)
8. `Pool.transferOwnership(Timelock)` — deployer EOA initiates.
9. Governance Safe proposes + Timelock executes `Pool.acceptOwnership()` (Ownable2Step requires acceptance; minDelay = 0 makes this instant).
10. Governance Safe proposes + Timelock executes `Pool.setPauseGuardian(PauseGuardianSafe)`.
11. `Registry.transferOwnership(Timelock)` + Governance Safe schedules + Timelock executes `Registry.acceptOwnership()`.
12. For each of the 7 feeds (V2 feeds from 2026-05-10 cutover): `Feed.transferOwnership(GovernanceSafe)` + Governance Safe calls `Feed.acceptOwnership()` directly (no timelock for feed ownership).
13. **Lockdown**: Governance Safe proposes + Timelock executes `Timelock.updateDelay(48 hours)`. From this point onward, all future governance actions require the full 48-h delay.
14. Log all addresses + final state.

The "minDelay = 0 → lockdown" trick is standard for testnet rehearsals where the operator needs many initial owner-transfers to land in one session. Mainnet deploy script must skip this (set `minDelay = 48 hours` from the start, schedule initial ownership transfers off-chain with 48-h public announcements).

---

## 7. Dry-Run Tests (Foundry)

New test file: `contracts/test/governance/P2Governance.t.sol`. Tests the full governance lifecycle in an in-memory environment (no real broadcast). Each test deploys the full stack (mimicking the deploy script) and exercises one governance path end-to-end.

### Test list (target: 6 tests minimum)

1. **`test_governance_proposes_executes_setSwapFeeBps`** — Gov Safe schedules `setSwapFeeBps(10)` via Timelock; `vm.warp(48 h)`; executes; asserts `pool.swapFeeBps() == 10`.
2. **`test_governance_proposes_executes_setMaxStaleSeconds`** — Gov Safe schedules `Registry.setMaxStaleSeconds(USDC, 7200)`; advance 48 h; execute; assert.
3. **`test_pauseGuardian_canPauseInstantly`** — Pause Guardian Safe calls `pool.pause()` directly with 2/3 signatures; assert `pool.paused() == true`. No timelock delay.
4. **`test_pauseGuardian_canUnpauseInstantly`** — Same as above but for `unpause`.
5. **`test_deployerEOA_cannotPause`** — After migration, deployer EOA attempts `pool.pause()`; asserts revert `NotAuthorized` (or `OwnableUnauthorizedAccount` since owner is now Timelock).
6. **`test_governance_proposes_executes_setOracle`** — End-to-end oracle rotation via timelock. Confirms the most critical owner-only action works as designed.

Optional further tests if time allows:
- `test_timelock_minDelay_enforced` — execute before 48 h reverts.
- `test_executor_open_anyone_can_execute` — non-Safe address executes after delay; succeeds.

---

## 8. Migration Sequence (Operational Runbook)

After both scripts broadcast on Arc testnet (`DeployArcoraDexV3.s.sol` first, then `DeployGovernanceP2.s.sol`):

1. **Verify Pool/Registry V3 deploy**: cast call to confirm `paused=false`, owner=Timelock, pauseGuardian=PauseGuardianSafe, NAV ≈ $700.
2. **Verify governance deploy**: each new Safe and Timelock has correct owners, threshold, and minDelay = 48 h post-lockdown.
3. **Pause P1 pool**: deployer EOA calls `pause()` on the P1 pool `0xb01a7a4da9986e9eb197d98242cf74d15f1f648b`. (P1 pool is owned by the deployer until that pause; afterwards the pool can be abandoned.)
4. **Update SDK / app / VPS keeper `.env`**: point at the new V3 Pool/Registry/LP addresses. Feeds are reused so keeper env `FEED_*` does not change.
5. **Sanity ping** (≥48h after deploy so the lockdown delay is enforced):
   - Direct deployer call to `pool.setSwapFeeBps(5)` (no-op value) → expect revert (`OwnableUnauthorizedAccount`).
   - Gov Safe schedules `setSwapFeeBps(5)` via Timelock → wait 48 h → execute → confirm no change (value stays at 5 because it was already 5 — this is the rehearsal pattern).
   - Pause Guardian calls `pause()` → confirm paused immediately.
   - Pause Guardian calls `unpause()` → confirm unpaused immediately.
6. **Document**: write `docs/rollouts/2026-05-14-phase2-governance.md` with new V3 addresses + governance addresses + signer mnemonic + per-action runbook + dry-run results + downstream SDK update checklist.

---

## 9. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Test signer mnemonic leaks → testnet wallets compromised | High (it's plaintext) | Acknowledge in rollout doc; never use on mainnet; throwaway wallets only |
| Pool redeploy disrupts P1 testnet bootstrap | Certain | Old pool ($700 NAV) paused; new pool starts with fresh $700 bootstrap from deployer's existing balances |
| Setup-mode-then-lockdown leaves a window where minDelay=0 | Low (single tx graph) | Timelock `updateDelay(48h)` is the LAST setup action; document the window |
| Forge `vm.deriveKey` differs from real HD derivation | Low | Use canonical BIP39 / BIP32 path `m/44'/60'/0'/0/<index>`; tested against Anvil / ethers |
| Pause Guardian Safe set up but `setPauseGuardian` not called → pool can't be paused by anyone | Medium | Script asserts `pool.pauseGuardian() == PauseGuardianSafe` before exiting |
| Governance Safe 3/5 keys all derived from one mnemonic → entropy concern | High for mainnet, irrelevant for testnet | Rotate to real HW wallets in P5; explicitly forbid mainnet use of testnet mnemonic |
| OZ TimelockController operations API change between versions | Low | Pin OZ version in foundry.toml; document in lockfile |

---

## 10. Out of Scope (Deferred)

- Mainnet deployment of governance stack (P5)
- Real signer identity selection + onboarding (operator decision; P5)
- Hardware wallet (Ledger Nano) procurement + provisioning (P5)
- Per-action delay tiering (e.g. 7-day for `setOracle`) — off-chain pre-announce sufficient for now
- Custom Safe modules / sub-modules
- On-chain DAO governance (v1 stays Safe-based)
- Feed-write rotation playbook (P5 / ops doc)
- Litepaper update reflecting governance model (P4 / P5)

---

## 11. Acceptance Criteria

P2 is complete when:

- `contracts/src/ArcoraDexPool.sol` has `pauseGuardian` storage + `onlyOwnerOrGuardian` modifier + `setPauseGuardian(address)` setter; tests cover all three new behaviors.
- `forge test` count ≥97 (P1's 91 + 3 new pause-guardian unit tests + ≥3 governance dry-run tests).
- Both deploy scripts exist, dry-run cleanly, and have been broadcast to Arc testnet:
  - `DeployArcoraDexV3.s.sol` deployed new Pool+Registry+LP with bootstrap NAV ~$700.
  - `DeployGovernanceP2.s.sol` deployed Governance Safe + Pause Guardian Safe + TimelockController, transferred ownerships, set pauseGuardian, locked down Timelock to 48h.
- All ownership transfers visible on-chain: `Pool.owner() == Timelock`, `Registry.owner() == Timelock`, each `Feed.owner() == GovernanceSafe`.
- `Pool.pauseGuardian() == PauseGuardianSafe` post-deploy.
- `Timelock.getMinDelay() == 48 hours` post-lockdown.
- P1 pool `0xb01a7a4da9986e9eb197d98242cf74d15f1f648b` is paused (deployer-initiated, before SDK/app cutover).
- At least one full propose-wait-execute cycle performed on testnet via Governance Safe (any owner action; the operation is the demonstration).
- At least one direct pause via Pause Guardian Safe demonstrated on testnet.
- Rollout doc `docs/rollouts/2026-05-14-phase2-governance.md` written and committed with all addresses, signer mnemonic, and per-action runbook.

---

## 12. Open Questions Deferred to Plan / Implementation

1. **Safe singleton + factory addresses on Arc testnet** — verify whether Safe has canonical addresses on Arc 5042002; if not, the script deploys a local Safe singleton. (Implementation will probe via cast call before deploy.)
2. **Should the pool redeploy bundle the pause-guardian change with any other queued contract changes?** — No queued changes exist; keep the redeploy scoped strictly to the pause-guardian addition.
3. **Should the deploy script accept a `--rehearse` flag** to do everything in setup mode (minDelay = 0 throughout)? — Probably yes for ergonomics; resolved during writing-plans.
4. **Funding amount per signer** — 0.1 ARC each is a guess; final amount calibrated against Arc testnet's actual gas price during deploy.
5. **Whether to publish the signer addresses in the rollout doc** — yes, since they're testnet throwaways; security-by-obscurity is not the model.
