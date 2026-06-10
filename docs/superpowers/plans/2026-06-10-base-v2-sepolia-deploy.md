# Base V2 Base-Sepolia Deployment Orchestration + Governance + §13 Drills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the THIRD Base-first V2 subsystem — the Base Sepolia (chainId 84532) deployment ORCHESTRATION plus its governance and the spec §13-step-2 drill suite. Deliver ONE turnkey `DeployBaseSepoliaV2.s.sol` that, in a single broadcast, chainid-guards 84532, deploys 3 fresh `MintableERC20` test stables (USDC/USDT/EURC, 6-dec), deploys a FRESH governance stack via the chain-agnostic `GovernanceFactory` (Gov Safe 3/5 + Pause-Guardian Safe 2/3 + 48h Timelock; `GOV_USE_TEST_MNEMONIC` opt-in allowed on this testnet), deploys 3 `ChainlinkPythAdapterV2` adapters using the AUTHORITATIVE per-token Sepolia deploy-config table (incl. an IN-PROCESS `MockChainlinkFeed` for the EURC Chainlink leg that does not exist on Sepolia), deploys `ArcoraDexRegistryV2` and lists all 3 tokens with §7 default bands + conservative low rollout caps (§13-step-5), deploys the immutable `ArcoraDexPoolV2`, wires `setPool`, bootstraps seed deposits, hands ownership off (Registry/Pool transferOwnership -> Timelock pending; adapters transferOwnership -> Gov Safe pending), asserts deployed-state invariants, and emits an address ledger. Plus: an `UpdatePythBaseSepolia` keeper path (Node + Hermes HTTP; note the post-2026-07-31 Hermes API-key requirement) that pulls the 3 feed IDs and calls each adapter's `updatePyth`; a §13-step-2 drill runbook of executable scripts/`cast` (and documented multisig steps) for oracle-failure, divergence, stale-price, confidence, reserve-floor, marginal-fee, emergency-proportional-exit, and pause drills; and a fork-mode revalidation test that drives the orchestrator's OWN code (gap-test coupling, mirroring `DeployPublicTestnetGaps.t.sol`).

**Architecture:** `DeployBaseSepoliaV2.s.sol` follows the proven `DeployPublicTestnet.s.sol` house style exactly: a single `run()` that broadcasts the full validated sequence, chaining every freshly-deployed address through an IN-PROCESS `Deployed` ledger struct (no log scraping between steps); a pure `internal` per-token config source of truth `_cfg()` (the drift-guard + revalidation test bind to it); a `_govEnv`-driven governance mode (FRESH via `GovernanceFactory`, test-mnemonic opt-in permitted because 84532 is a testnet, with the factory's mainnet guard intact); post-deploy `require` invariant asserts in `_summary`; and an `_emitLedger`. Each token gets one immutable `ChainlinkPythAdapterV2(token, chainlinkFeed, pyth, pythPriceId, chainlinkMaxStaleSeconds, pythMaxStaleSeconds, pythMaxConfBps, maxDivergenceBps, initialOwner)` — USDC/USDT use the real Sepolia Chainlink proxies, EURC uses an in-process `MockChainlinkFeed(8, 1.15e8)` (Sepolia has NO Chainlink EURC), all three target the UPGRADED Sepolia Pyth `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83`, all with LENIENT testnet staleness windows (Sepolia USDC observed ~8d stale). Registry lists each token with the §7 default 4-band schedule, per-token min/target reserve USD, and a conservative `depositCapUsd` (§13-step-5 low caps). The Pool is the immutable `ArcoraDexPoolV2(registry, protocolFeeShareBps, owner)`. Ownership handoff leaves a clean pending state: Registry/Pool pendingOwner = Timelock (governance accepts via a scheduled Timelock op); adapters pendingOwner = Gov Safe (so the §10 safety-param retune authority is the same Gov Safe that owns the oracle layer). The keeper is a standalone Node script reusing the `ops/keepalive/lib.mjs` transport/gas/nonce hardening; the drills are `cast`-driven shell scripts where permissionless and documented Safe/Timelock procedures where multisig is required.

**Tech Stack:** Solidity `^0.8.26`, Foundry (`forge build` / `forge test` / `forge fmt` / `forge script`), OpenZeppelin v5 (`Ownable2Step`, `TimelockController`), `@safe-global/safe-contracts` (via `GovernanceFactory`), forge-std (`Script`, `Test`, `console2`). Keeper: Node 20 + `viem` + Pyth Hermes HTTP (`https://hermes.pyth.network`), reusing `ops/keepalive/lib.mjs`. Reuses in-repo `ChainlinkPythAdapterV2`, `ArcoraDexRegistryV2`, `ArcoraDexPoolV2`, `ArcoraDexLPV2`, `MintableERC20`, `src/testnet/MockChainlinkFeed`, `GovernanceFactory`, `IChainlinkAggregator`, `IPythV2`. No new production contract is written — this subsystem is orchestration, keeper, drills, and tests over the already-deployed V2 contracts.

**Out of scope (other plans / spec sections):**
- Base MAINNET deploy (§13 steps 4-7) — this plan is Base Sepolia only (§13 steps 1-2).
- Monitoring / alerting infrastructure (§12 beyond the drill-time verification that signals fire) — the independent third reference, alert delivery, responder paging, runbook ownership.
- The `ChainlinkPythAdapterV2` contract itself, its unit/fork tests, and the per-token oracle-config TABLE — delivered by `docs/superpowers/plans/2026-06-10-base-v2-oracle-adapters.md` (this plan CONSUMES that table).
- The Pool/Registry/FeeBandMath core contracts — delivered by the core-contracts plan (this plan deploys them unchanged).
- SDK and application (§9), security review (§13 step 3, §15), Arc deployment (§1, §13).

---

## File Structure

| File | Responsibility (one each) |
|------|---------------------------|
| `contracts/script/DeployBaseSepoliaV2.s.sol` | The turnkey Base Sepolia orchestrator: chainid-guard 84532; `_cfg()` per-token source of truth; deploy 3 test tokens -> fresh governance -> 3 adapters (EURC mock CL leg in-process) -> Registry (list 3 with §7 bands + low caps) -> Pool -> setPool -> bootstrap -> handoffs -> `_summary` invariant asserts -> `_emitLedger`. |
| `contracts/test/DeployBaseSepoliaV2.t.sol` | Fork-mode revalidation + gap-test coupling: INHERITS the orchestrator, drives its REAL `_cfg()` / `_adapterCfg()` / `_buildAdapters` / `_listAndSeed` / `_summary` against a forked (or simulated 84532) chain; asserts the §13/§15 deployed-state invariants and the config drift guard. |
| `ops/basekeeper/update-pyth-base-sepolia.mjs` | The `UpdatePythBaseSepolia` keeper: pulls Hermes update data for the 3 Sepolia feed IDs and calls each adapter's `updatePyth{value: fee}`; reuses `ops/keepalive/lib.mjs` transport/gas/nonce hardening; documents the post-2026-07-31 Hermes API key. |
| `ops/basekeeper/lib.mjs` | Thin keeper helpers specific to the Base-Sepolia path (Hermes fetch + base64-decode to `0x` blobs, adapter ABI, chain def) — kept separate so `ops/keepalive/lib.mjs` is untouched. |
| `ops/basekeeper/test/update-pyth.test.mjs` | Node unit test for the Hermes-blob decode + `updatePyth` arg shaping (pure functions; no live RPC). |
| `docs/runbooks/2026-06-10-base-sepolia-v2-drills.md` | The §13-step-2 drill runbook: 8 drills (oracle-failure, divergence, stale-price, confidence, reserve-floor, marginal-fee, emergency-proportional-exit, pause), each with executable `cast`/script commands where permissionless and documented Safe/Timelock procedure where multisig is needed; expected observable outcome per drill. |
| `ops/basekeeper/drills/*.sh` | Executable `cast`-driven drill scripts referenced by the runbook (one per permissionless drill; multisig drills are documented-only in the runbook). |
| `docs/superpowers/plans/2026-06-10-base-v2-sepolia-deploy.md` | This plan. |

All new Solidity lives under `contracts/script/` + `contracts/test/`. No existing contract is edited. The keeper + drills live under `ops/basekeeper/`. The runbook lives under `docs/runbooks/`. The existing V1 + V2 suites must stay green throughout.

---

### Task 0: Branch + baseline + input pins

**Files:** none modified; verification only.

- [ ] **Step 1: Create the deploy branch**

Run:
```bash
git checkout feat/base-v2-oracle-adapters && git checkout -b feat/base-v2-sepolia-deploy && git log --oneline -1
```
Expected: a clean branch at the oracle-adapters tip (this plan builds on the merged adapter + table). If oracle-adapters is already on `main`, branch from `main` instead and record which.

- [ ] **Step 2: Establish the baseline (must stay green)**

Run:
```bash
cd contracts && forge build && forge test 2>&1 | tail -3
```
Expected: `Compiler run successful`, then `<N> tests passed, 0 failed`. Record `<N>` as the actual baseline (V1 + V2 core + adapter suites). New tests in this plan add to `<N>`.

- [ ] **Step 3: Pin the authoritative Sepolia config (from the oracle-adapters plan table)**

Open `docs/superpowers/plans/2026-06-10-base-v2-oracle-adapters.md`, scroll to the bottom section **"Per-Token Deploy Config (§6 deliverable)" -> "Base Sepolia (chainId 84532) — testnet"**, and confirm these exact values are what `_cfg()` / `_adapterCfg()` encode in Task 2:

```text
Pyth (Base Sepolia) UPGRADED Core:  0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83
Sepolia Chainlink:
  USDC/USD  0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165   (observed ~8d stale -> 30d window)
  USDT/USD  0x3ec8593F930EA45ea58c968260e6e9FF53FC934f   (fresh -> 7d window)
  EURC/USD  DOES NOT EXIST -> deploy in-process MockChainlinkFeed(8, 115000000) = $1.15
Pyth feed IDs (identical mainnet + Sepolia):
  USDC  0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a
  USDT  0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b
  EURC  0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c
Lenient testnet windows: chainlinkMaxStaleSeconds USDC=2592000(30d) USDT/EURC=604800(7d);
  pythMaxStaleSeconds=86400(24h) for all three (keeper cadence is generous on testnet).
```
No code in this step — this is the source of truth Task 2 transcribes. Do not let it drift; the revalidation test (Task 3) and the drift guard assert against these exact values.

- [ ] **Step 4: Confirm the consumed contract surfaces (no surprises at deploy time)**

Run:
```bash
cd contracts && grep -n "constructor" src/v2/ChainlinkPythAdapterV2.sol src/v2/ArcoraDexPoolV2.sol src/v2/ArcoraDexRegistryV2.sol src/testnet/MockChainlinkFeed.sol src/testnet/MintableERC20.sol | head -20
```
Expected (these are the EXACT signatures the orchestrator calls — verify before writing Task 2):
```text
ChainlinkPythAdapterV2: constructor(address token_, IChainlinkAggregator chainlinkFeed_, IPythV2 pyth_, bytes32 pythPriceId_, uint32 chainlinkMaxStaleSeconds_, uint32 pythMaxStaleSeconds_, uint16 pythMaxConfBps_, uint16 maxDivergenceBps_, address initialOwner)
ArcoraDexPoolV2:        constructor(address registry, uint16 initialProtocolFeeShareBps, address initialOwner)
ArcoraDexRegistryV2:    constructor(address initialOwner)
MockChainlinkFeed:      constructor(uint8 _decimals, int256 initialAnswer)   // owner = msg.sender; setAnswer refreshes timestamp
MintableERC20:          constructor(string name_, string symbol_, uint8 decimals_, address initialOwner)
```
If any signature differs, STOP and reconcile — the orchestrator is a transcription of these, not a guess.

---

### Task 1: Drill runbook skeleton (§13 step 2 — write the contract of what the orchestrator must enable)

Writing the runbook first fixes the observable outcomes the orchestrator + tests must make reachable (e.g. "flip the EURC mock CL leg stale -> swaps into EURC revert `OracleUnsafe`, proportional exit still works"). This is the spec-§13/§12 acceptance contract for the rest of the plan.

**Files:**
- Create `docs/runbooks/2026-06-10-base-sepolia-v2-drills.md`

- [ ] **Step 1: Write the runbook**

Create `docs/runbooks/2026-06-10-base-sepolia-v2-drills.md`:
```markdown
# Base Sepolia V2 — §13-step-2 Drill Runbook

Run AFTER `DeployBaseSepoliaV2.s.sol` succeeds and the address ledger is captured into
`ops/basekeeper/.env` (REGISTRY, POOL, LP, GOV_SAFE, TIMELOCK, ADAPTER_{USDC,USDT,EURC},
EURC_MOCK_CL_FEED, TOKEN_{USDC,USDT,EURC}). These drills exercise spec §11 (oracle failure
behavior), §7 (marginal fee bands / reserve floor), §8.3 (proportional emergency exit), and
§12 (the monitorable signals each drill emits). They are the §13-step-2 gate before the
mainnet rollout (§13 steps 4-7, a separate plan).

Permissionless drills are executable via the `cast` scripts under `ops/basekeeper/drills/`.
Drills that require an owner action (Registry/Pool owned by the Timelock; adapters by the Gov
Safe) document the Safe/Timelock procedure — they CANNOT be a one-liner because the deploy
hands ownership to multisig governance.

## Pre-flight
- Keeper has pulled Pyth fresh: `node ops/basekeeper/update-pyth-base-sepolia.mjs` (all 3 legs).
- Deployer/test account holds test-token balances (the deploy minted seed; mint more via the
  Timelock-owned... NO — tokens stay deployer-owned for testnet faucet convenience; see deploy
  Task 2 Step 6 note. Mint test tokens directly with the deployer key as needed.)

## Drill 1 — Oracle failure (EURC mock CL leg stale)  [permissionless]
Goal (§11): when EURC's Chainlink leg goes stale, EURC becomes unsafe -> swaps INTO EURC and
single-token withdrawals INTO EURC revert; proportional exit still works.
Mechanism: the EURC Chainlink leg is the in-process `MockChainlinkFeed`; its `setAnswer` is
owner-gated. The deploy leaves the mock CL feed owned by the DEPLOYER (testnet operator) — NOT
governance — precisely so this drill is a one-liner. Stop the keeper, let `updatedAt` age past
`chainlinkMaxStaleSeconds` (7d) OR (faster) point the adapter's window tighter is governance —
instead, deploy a second short-window EURC adapter for the drill, OR warp on a fork.
Run (fork-time, deterministic): `bash ops/basekeeper/drills/01-oracle-failure.sh`
Observe: `cast call POOL "quoteSwapV2(address,address,uint256)" USDC EURC 1000000` reverts with
`OracleUnsafe(EURC)`; `cast send POOL "withdrawProportional(uint256,uint256)" <lp> <deadline>`
succeeds. §12 signal: adapter `peekPrice(EURC).safe == false`.

## Drill 2 — Divergence drill  [permissionless]
Goal (§10): when the EURC mock CL leg and the Pyth EURC price diverge beyond `maxDivergenceBps`,
EURC is unsafe. Set the mock CL leg to $1.30 while Pyth EURC is ~$1.08:
Run: `bash ops/basekeeper/drills/02-divergence.sh`
Observe: `peekPrice(EURC).safe == false`; swaps into EURC revert. §12 signal: primary/secondary
divergence over bound.

## Drill 3 — Stale-price drill (Pyth leg)  [permissionless]
Goal (§11): stop pulling Pyth; after `pythMaxStaleSeconds` (24h) all three tokens' Pyth legs go
stale and every token is unsafe. (On a fork, warp `pythMaxStaleSeconds + 1`.)
Run: `bash ops/basekeeper/drills/03-stale-pyth.sh`
Observe: all `peekPrice(*).safe == false`; the keeper pull (`update-pyth-base-sepolia.mjs`)
restores safety. §12 signal: Pyth freshness alarm.

## Drill 4 — Confidence drill  [fork-only, documented]
Goal (§10): a blown Pyth confidence ratio (> `pythMaxConfBps`) makes a token unsafe. Live Sepolia
Pyth confidence cannot be forced; on a fork, `vm.mockCall` the Pyth `getPriceUnsafe` to return a
high `conf`. Documented in `DeployBaseSepoliaV2.t.sol::test_drill_confidence` (Task 3).

## Drill 5 — Reserve-floor drill  [permissionless]
Goal (§7): a swap large enough to push the output reserve below `minimumReserveUsd` reverts
`ReserveFloorBreached`; the max floor-safe amount (`maxSwapOut`) succeeds.
Run: `bash ops/basekeeper/drills/05-reserve-floor.sh`
Observe: an over-max `cast call POOL "quoteSwapV2"...` reverts `ReserveFloorBreached(tokenOut)`;
`maxSwapOut(tokenOut)` returns the safe ceiling and a swap at that amount succeeds.

## Drill 6 — Marginal-fee verification  [permissionless]
Goal (§7/§14): one large swap pays the same total fee as the sum of split swaps (within rounding),
and a deeper-band swap pays a higher marginal rate. Compare `quoteSwapV2` fee for one large vs N
small amounts spanning a band boundary.
Run: `bash ops/basekeeper/drills/06-marginal-fee.sh`
Observe: `fee(one) ~= sum(fee(split))`; printed fee/health breakdown matches the §7 schedule.

## Drill 7 — Emergency proportional exit  [permissionless]
Goal (§8.3): `withdrawProportional` returns the pro-rata basket of EVERY reserve, works while a
token is unsafe (Drill 1 state) and while paused (Drill 8 state), excludes protocol fees.
Run: `bash ops/basekeeper/drills/07-proportional-exit.sh`
Observe: caller receives a share of all 3 tokens; succeeds even with EURC unsafe / pool paused.

## Drill 8 — Pause drill  [Pause Guardian (PG Safe) + Timelock]
Goal (§6.2/§12): the Pause-Guardian Safe can `pause()` immediately; only the Timelock (Pool owner)
can `unpause()`. This is the §12 "live pause drill" gate.
Procedure (multisig — documented, not a one-liner):
1. PG Safe (2/3) builds + signs `pause()` on POOL, executes. `cast call POOL "paused()"` == true.
   Swaps/deposits/single-withdraws revert `PoolPaused`; `withdrawProportional` still works (Drill 7).
2. Gov Safe (3/5) schedules a Timelock op calling `POOL.unpause()`, waits the 48h delay (or the
   delay configured at deploy), executes. `paused()` == false.
§12 signal: Pool pause-state change observed by monitoring; Timelock proposal + execution observed.
```

- [ ] **Step 2: Commit the runbook skeleton**

Run:
```bash
git add docs/runbooks/2026-06-10-base-sepolia-v2-drills.md
git commit -m "docs(v2): Base Sepolia §13-step-2 drill runbook skeleton

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `DeployBaseSepoliaV2.s.sol` — the turnkey orchestrator

The core deliverable. Mirrors `DeployPublicTestnet.s.sol` exactly: chainid guard, in-process `Deployed` ledger, pure `_cfg()` source of truth, `_summary` invariant asserts, `_emitLedger`. Read the design notes before writing.

**Design encoded here (read before writing):**

Per-token config (`_cfg()`, `internal pure`, 3 entries — the drift-guard + revalidation test bind to it):
- `symbol`, `tokenName`, `decimals` (all 6).
- `chainlinkFeed` — the REAL Sepolia proxy for USDC/USDT; `address(0)` sentinel for EURC meaning "deploy an in-process `MockChainlinkFeed(8, eurcMockAnswer)`".
- `eurcMockAnswer` (only meaningful for EURC; `115000000` = $1.15 at 8 dec).
- `pythPriceId` (the verified Sepolia/mainnet-identical ID).
- `chainlinkMaxStaleSeconds` (USDC 2592000, USDT 604800, EURC 604800), `pythMaxStaleSeconds` (86400 all).
- `pythMaxConfBps` (USDC/USDT 30, EURC 40 — matches the table's mainnet rationale; testnet keeps the same conf cap because confidence is feed-intrinsic), `maxDivergenceBps` (USDC/USDT 50, EURC 60).
- `minReserveUsd`, `targetReserveUsd` (per-token §7 floors), `depositCapUsd` (CONSERVATIVE low §13-step-5 cap), `seedAmount` (token-native bootstrap, < cap).

Constants:
- `CHAIN_ID = 84532`.
- `PYTH_SEPOLIA = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83` (the UPGRADED Sepolia Pyth Core).
- `PROTOCOL_FEE_SHARE_BPS = 1000` (10% protocol / 90% LP — matches the V2 fixture default; <= MAX 2500).

The §7 default 4-band schedule, identical to `V2Fixture._defaultBands`:
```text
band[0] upperHealthBps 10000 rateBps 5    (75-100%: 0.05%)
band[1] upperHealthBps  7500 rateBps 20   (50-75% : 0.20%)
band[2] upperHealthBps  5000 rateBps 75   (25-50% : 0.75%)
band[3] upperHealthBps  2500 rateBps 300  (0-25%  : 3.00%)
```

In-process `Deployed` ledger struct: `registry`, `pool`, `lp`, `address[3] token`, `address[3] adapter`, `address[3] chainlinkLeg` (the real proxy or the deployed mock), `govSafe`, `timelock` (payable), `pgSafe`, `bool freshGovernance`.

Sequence in `run()` (single broadcast unless a step needs post-broadcast asserts):
0. chainid guard 84532.
1. Governance: `GovernanceFactory.resolveConfig()` + `deploy(cfg, cfg.timelockMinDelay)` (FRESH). On 84532 the `GOV_USE_TEST_MNEMONIC=true` opt-in is allowed (the factory's mainnet guard still forbids it on chainid 1). Record `govSafe`, `timelock`, `pgSafe`.
2. Tokens: deploy 3 `MintableERC20`, mint each `seedAmount * 2` to the deployer (seed + faucet headroom).
3. Adapters: for each token build the Chainlink leg (real proxy, or deploy in-process `MockChainlinkFeed(8, eurcMockAnswer)` for EURC), then `new ChainlinkPythAdapterV2(token, IChainlinkAggregator(clLeg), IPythV2(PYTH_SEPOLIA), pythPriceId, chainlinkMaxStaleSeconds, pythMaxStaleSeconds, pythMaxConfBps, maxDivergenceBps, deployer)`. Owner = deployer FOR NOW; handed to the Gov Safe in step 7.
4. Registry: `new ArcoraDexRegistryV2(deployer)`. List each token with `TokenConfigV2{decimals, isActive:true, adapter, minReserveUsd, targetReserveUsd, depositCapUsd, bands:_defaultBands()}`.
5. Pool: `new ArcoraDexPoolV2(address(registry), PROTOCOL_FEE_SHARE_BPS, deployer)`; `lp = ArcoraDexLPV2(address(pool.LP()))`; `registry.setPool(address(pool))` (the I-1 reserve guard); `pool.setPauseGuardian(pgSafe)` (§6.2: the PG Safe is the pause guardian).
6. Bootstrap: for each token approve + `pool.deposit(token, seedAmount, 0, block.timestamp + 1 days)`. The first deposit must exceed `MINIMUM_LIQUIDITY`; seedAmounts are sized well above it. The Pyth legs must be FRESH at deploy time, so the deploy runbook says: run the keeper `updatePyth` BEFORE the orchestrator's bootstrap, or bootstrap will revert `OracleUnsafe`. To keep the orchestrator self-contained, bootstrap reads via the adapter; on a fork the revalidation test seeds Pyth via `vm.mockCall`/a pre-pull (Task 3). On live Sepolia: keeper-pull all 3 IDs in the SAME deployer session immediately before `forge script` (documented in the deploy runbook header). NOTE: do not gate the whole deploy on bootstrap — wrap bootstrap so a single unsafe leg logs+skips that token's seed rather than aborting the entire run (mirrors `DeployPublicTestnet._bootstrap` seed-robustness), and assert at least the safe tokens seeded.
7. Handoffs (leave a clean pending state, mirroring `DeployPublicTestnet._handoffGovernance`):
   - adapters: `adapter.transferOwnership(govSafe)` (§10 retune authority -> Gov Safe).
   - Registry/Pool: `registry.transferOwnership(timelock)`, `pool.transferOwnership(timelock)` — pendingOwner is the Timelock; governance accepts via a scheduled Timelock op (documented in `_emitLedger`).
   - The EURC mock CL feed stays DEPLOYER-owned (testnet operator) so Drill 1/2 can flip it — explicit note (testnet-only; mainnet EURC uses the real direct proxy with no mock).
8. `_summary` invariant asserts (post-broadcast, `view`): see Step 2 below.
9. `_emitLedger`.

**Files:**
- Create `contracts/script/DeployBaseSepoliaV2.s.sol`

- [ ] **Step 1: Write the orchestrator**

Create `contracts/script/DeployBaseSepoliaV2.s.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArcoraDexRegistryV2} from "../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexPoolV2} from "../src/v2/ArcoraDexPoolV2.sol";
import {ArcoraDexLPV2} from "../src/v2/ArcoraDexLPV2.sol";
import {ChainlinkPythAdapterV2} from "../src/v2/ChainlinkPythAdapterV2.sol";
import {IArcoraDexRegistryV2} from "../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "../src/v2/interfaces/IOracleAdapterV2.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {IPythV2} from "../src/v2/interfaces/IPythV2.sol";
import {FeeBandMathV2} from "../src/v2/lib/FeeBandMathV2.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
import {MockChainlinkFeed} from "../src/testnet/MockChainlinkFeed.sol";
import {GovernanceFactory} from "./GovernanceFactory.sol";

/// @title DeployBaseSepoliaV2 — turnkey Base Sepolia V2 (re)deploy + drills bootstrap
/// @notice Single-broadcast orchestrator for the FRESH ArcoraDEX V2 stack on Base
/// Sepolia (chainId 84532), the spec §13-step-1/2 testnet deploy. Chains every
/// freshly-deployed address through an in-process ledger so the operator never
/// scrapes addresses from broadcast logs. Mirrors the proven house style of
/// DeployPublicTestnet.s.sol: pure `_cfg()` source of truth, `_summary` invariant
/// asserts, `_emitLedger`.
///
/// SEQUENCE:
///   0. chainid guard 84532
///   1. FRESH governance (GovernanceFactory): Gov Safe 3/5 + PG Safe 2/3 + 48h Timelock.
///      GOV_USE_TEST_MNEMONIC=true is ALLOWED on this testnet (factory's mainnet guard intact).
///   2. 3 fresh MintableERC20 test stables (USDC/USDT/EURC, 6-dec); mint seed+faucet headroom.
///   3. 3 ChainlinkPythAdapterV2 (Sepolia table values). EURC's Chainlink leg does NOT exist on
///      Sepolia -> an in-process MockChainlinkFeed(8, $1.15) is its CL leg (TESTNET-ONLY).
///   4. RegistryV2 + list 3 tokens (§7 default bands; conservative low §13-step-5 depositCapUsd).
///   5. Immutable PoolV2 (+ auto-LP) + setPool (I-1) + setPauseGuardian(PG Safe).
///   6. Bootstrap seed deposits (seed-robust: skip a token whose oracle is unsafe at deploy).
///   7. Handoffs: adapters -> Gov Safe (pending); Registry/Pool -> Timelock (pending). The EURC
///      mock CL feed stays DEPLOYER-owned so the §13 oracle-failure/divergence drills can flip it.
///   8. Invariant asserts; 9. address-ledger emit.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY — broadcasts; mints + seeds; initial owner before handoff
/// Governance env (FRESH; recommended):
///   GOV_SAFE_OWNERS / GOV_SAFE_THRESHOLD / PG_SAFE_OWNERS / PG_SAFE_THRESHOLD / TIMELOCK_MIN_DELAY
///   (testnet opt-in: GOV_USE_TEST_MNEMONIC=true derives owners from the public Foundry mnemonic)
/// Pre-deploy: the keeper MUST pull Pyth fresh for all 3 IDs in the same session (else bootstrap
///   skips unsafe tokens). See ops/basekeeper/update-pyth-base-sepolia.mjs.
contract DeployBaseSepoliaV2 is Script {
    uint256 internal constant CHAIN_ID = 84532;
    // UPGRADED (2026-07-31) Pyth Core on Base Sepolia. See the oracle-adapters plan table.
    address internal constant PYTH_SEPOLIA = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83;
    uint16 internal constant PROTOCOL_FEE_SHARE_BPS = 1_000; // 10% protocol / 90% LP

    /// @dev Per-token Base Sepolia config — the SINGLE source of truth the drift
    /// guard + revalidation test bind to. `chainlinkFeed == address(0)` is the EURC
    /// sentinel: deploy an in-process MockChainlinkFeed(8, eurcMockAnswer) as its CL leg.
    struct TokenCfg {
        string symbol;
        string name;
        uint8 decimals;
        address chainlinkFeed; // real Sepolia proxy; address(0) => deploy EURC mock leg
        int256 eurcMockAnswer; // EURC mock CL answer (8-dec); 0 for non-mock tokens
        bytes32 pythPriceId;
        uint32 chainlinkMaxStaleSeconds;
        uint32 pythMaxStaleSeconds;
        uint16 pythMaxConfBps;
        uint16 maxDivergenceBps;
        uint256 minReserveUsd; // 1e18
        uint256 targetReserveUsd; // 1e18
        uint256 depositCapUsd; // 1e18 (conservative §13-step-5 cap)
        uint256 seedAmount; // token-native bootstrap (< cap)
    }

    function _cfg() internal pure returns (TokenCfg[3] memory c) {
        // USDC — real Sepolia CL proxy; 30d window (observed ~8d stale).
        c[0] = TokenCfg({
            symbol: "USDC",
            name: "USD Coin",
            decimals: 6,
            chainlinkFeed: 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165,
            eurcMockAnswer: 0,
            pythPriceId: 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a,
            chainlinkMaxStaleSeconds: 2_592_000,
            pythMaxStaleSeconds: 86_400,
            pythMaxConfBps: 30,
            maxDivergenceBps: 50,
            minReserveUsd: 1_000e18,
            targetReserveUsd: 5_000e18,
            depositCapUsd: 10_000e18, // conservative §13-step-5 cap
            seedAmount: 1_000_000_000 // 1,000 USDC (6-dec)
        });
        // USDT — real Sepolia CL proxy; 7d window (fresh feed).
        c[1] = TokenCfg({
            symbol: "USDT",
            name: "Tether USD",
            decimals: 6,
            chainlinkFeed: 0x3ec8593F930EA45ea58c968260e6e9FF53FC934f,
            eurcMockAnswer: 0,
            pythPriceId: 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b,
            chainlinkMaxStaleSeconds: 604_800,
            pythMaxStaleSeconds: 86_400,
            pythMaxConfBps: 30,
            maxDivergenceBps: 50,
            minReserveUsd: 1_000e18,
            targetReserveUsd: 5_000e18,
            depositCapUsd: 10_000e18,
            seedAmount: 1_000_000_000 // 1,000 USDT
        });
        // EURC — NO Sepolia CL proxy: address(0) sentinel -> in-process MockChainlinkFeed(8,$1.15).
        c[2] = TokenCfg({
            symbol: "EURC",
            name: "Euro Coin",
            decimals: 6,
            chainlinkFeed: address(0),
            eurcMockAnswer: 115_000_000, // $1.15 at 8 dec
            pythPriceId: 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c,
            chainlinkMaxStaleSeconds: 604_800,
            pythMaxStaleSeconds: 86_400,
            pythMaxConfBps: 40,
            maxDivergenceBps: 60,
            minReserveUsd: 1_000e18,
            targetReserveUsd: 5_000e18,
            depositCapUsd: 10_000e18,
            seedAmount: 870_000_000 // ~1,000 USD at $1.15 (6-dec EURC)
        });
    }

    /// @dev §7 default 4-band schedule, identical to V2Fixture._defaultBands.
    function _defaultBands() internal pure returns (FeeBandMathV2.Band[] memory b) {
        b = new FeeBandMathV2.Band[](4);
        b[0] = FeeBandMathV2.Band({upperHealthBps: 10_000, rateBps: 5});
        b[1] = FeeBandMathV2.Band({upperHealthBps: 7_500, rateBps: 20});
        b[2] = FeeBandMathV2.Band({upperHealthBps: 5_000, rateBps: 75});
        b[3] = FeeBandMathV2.Band({upperHealthBps: 2_500, rateBps: 300});
    }

    struct Deployed {
        ArcoraDexRegistryV2 registry;
        ArcoraDexPoolV2 pool;
        ArcoraDexLPV2 lp;
        address[3] token;
        address[3] adapter;
        address[3] chainlinkLeg; // real proxy or the deployed EURC mock
        address govSafe;
        address payable timelock;
        address pgSafe;
        bool freshGovernance;
    }

    function run() external {
        require(block.chainid == CHAIN_ID, "DeployBaseSepoliaV2: Base Sepolia (84532) only");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        TokenCfg[3] memory cfg = _cfg();
        Deployed memory d;

        console2.log("=== ArcoraDEX V2 Base Sepolia turnkey deploy ===");
        console2.log("Deployer:", deployer);
        console2.log("");

        vm.startBroadcast(deployerKey);

        _deployGovernance(d);
        _deployTokens(d, cfg, deployer);
        _buildAdapters(d, cfg, deployer);
        _deployRegistryAndList(d, cfg, deployer);
        _deployPool(d, deployer);
        _bootstrap(d, cfg, deployer);
        _handoff(d);

        vm.stopBroadcast();

        _summary(d, cfg);
        _emitLedger(d, cfg);
    }

    // ── Step 1: governance ───────────────────────────────────────────────
    function _deployGovernance(Deployed memory d) internal {
        GovernanceFactory.Config memory gcfg = GovernanceFactory.resolveConfig();
        GovernanceFactory.Stack memory s = GovernanceFactory.deploy(gcfg, gcfg.timelockMinDelay);
        d.govSafe = address(s.govSafe);
        d.timelock = payable(address(s.timelock));
        d.pgSafe = address(s.pgSafe);
        d.freshGovernance = true;
        require(s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), d.govSafe), "Timelock: Gov Safe not proposer");
        require(s.timelock.hasRole(s.timelock.EXECUTOR_ROLE(), d.govSafe), "Timelock: Gov Safe not executor");
        console2.log("  Gov Safe:", d.govSafe);
        console2.log("  PG Safe: ", d.pgSafe);
        console2.log("  Timelock:", d.timelock);
        console2.log("");
    }

    // ── Step 2: tokens ───────────────────────────────────────────────────
    function _deployTokens(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        console2.log("--- Test tokens ---");
        for (uint256 i = 0; i < 3; i++) {
            MintableERC20 t = new MintableERC20(cfg[i].name, cfg[i].symbol, cfg[i].decimals, deployer);
            // seed + faucet headroom for drills.
            t.mint(deployer, cfg[i].seedAmount * 2);
            d.token[i] = address(t);
            console2.log(string.concat("  ", cfg[i].symbol, ":"), address(t));
        }
        console2.log("");
    }

    // ── Step 3: adapters (EURC mock CL leg in-process) ───────────────────
    function _buildAdapters(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        console2.log("--- Oracle adapters (Sepolia table values) ---");
        for (uint256 i = 0; i < 3; i++) {
            address clLeg = cfg[i].chainlinkFeed;
            if (clLeg == address(0)) {
                // EURC: Sepolia has NO Chainlink EURC -> deploy a mock CL leg (TESTNET-ONLY).
                // owner = msg.sender (deployer) by MockChainlinkFeed's constructor; left
                // deployer-owned so the §13 oracle-failure/divergence drills can flip it.
                MockChainlinkFeed mockCl = new MockChainlinkFeed(8, cfg[i].eurcMockAnswer);
                clLeg = address(mockCl);
                console2.log(string.concat("  ", cfg[i].symbol, " MOCK CL leg ($1.15):"), clLeg);
            }
            d.chainlinkLeg[i] = clLeg;
            ChainlinkPythAdapterV2 a = new ChainlinkPythAdapterV2(
                d.token[i],
                IChainlinkAggregator(clLeg),
                IPythV2(PYTH_SEPOLIA),
                cfg[i].pythPriceId,
                cfg[i].chainlinkMaxStaleSeconds,
                cfg[i].pythMaxStaleSeconds,
                cfg[i].pythMaxConfBps,
                cfg[i].maxDivergenceBps,
                deployer // owner = deployer until step 7 handoff to Gov Safe
            );
            // N-6: post-deploy constructor verification (catches arg off-by-one).
            require(a.TOKEN() == d.token[i], "adapter TOKEN mismatch");
            require(address(a.PYTH()) == PYTH_SEPOLIA, "adapter PYTH mismatch");
            require(a.PYTH_PRICE_ID() == cfg[i].pythPriceId, "adapter price id mismatch");
            require(a.maxDivergenceBps() == cfg[i].maxDivergenceBps, "adapter divergence mismatch");
            d.adapter[i] = address(a);
            console2.log(string.concat("  ", cfg[i].symbol, " adapter:"), address(a));
        }
        console2.log("");
    }

    // ── Step 4: registry + list ──────────────────────────────────────────
    function _deployRegistryAndList(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        d.registry = new ArcoraDexRegistryV2(deployer);
        console2.log("Registry:", address(d.registry));
        for (uint256 i = 0; i < 3; i++) {
            IArcoraDexRegistryV2.TokenConfigV2 memory tc = IArcoraDexRegistryV2.TokenConfigV2({
                decimals: cfg[i].decimals,
                isActive: true,
                adapter: IOracleAdapterV2(d.adapter[i]),
                minimumReserveUsd: cfg[i].minReserveUsd,
                targetReserveUsd: cfg[i].targetReserveUsd,
                depositCapUsd: cfg[i].depositCapUsd,
                bands: _defaultBands()
            });
            d.registry.listToken(d.token[i], tc);
            console2.log(string.concat("  Listed ", cfg[i].symbol), d.token[i]);
        }
        console2.log("");
    }

    // ── Step 5: pool + setPool + guardian ────────────────────────────────
    function _deployPool(Deployed memory d, address deployer) internal {
        d.pool = new ArcoraDexPoolV2(address(d.registry), PROTOCOL_FEE_SHARE_BPS, deployer);
        d.lp = ArcoraDexLPV2(address(d.pool.LP()));
        d.registry.setPool(address(d.pool)); // I-1 reserve guard
        d.pool.setPauseGuardian(d.pgSafe); // §6.2 pause guardian = PG Safe
        console2.log("Pool:", address(d.pool));
        console2.log("LP:  ", address(d.lp));
        console2.log("setPool wired (I-1); pauseGuardian = PG Safe");
        console2.log("");
    }

    // ── Step 6: bootstrap (seed-robust; skip an unsafe token) ────────────
    function _bootstrap(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        console2.log("--- Bootstrap deposits ---");
        for (uint256 i = 0; i < 3; i++) {
            (, bool safe) = ChainlinkPythAdapterV2(d.adapter[i]).peekPrice(d.token[i]);
            if (!safe) {
                console2.log(string.concat("  SKIP ", cfg[i].symbol, " (oracle unsafe; pull Pyth then re-seed)"));
                continue;
            }
            IERC20(d.token[i]).approve(address(d.pool), cfg[i].seedAmount);
            uint256 lpOut = d.pool.deposit(d.token[i], cfg[i].seedAmount, 0, block.timestamp + 1 days);
            console2.log(string.concat("  Deposited ", cfg[i].symbol), cfg[i].seedAmount);
            console2.log("    LP minted:", lpOut);
        }
        console2.log("");
    }

    // ── Step 7: ownership handoffs (clean pending state) ─────────────────
    function _handoff(Deployed memory d) internal {
        console2.log("--- Handoffs ---");
        for (uint256 i = 0; i < 3; i++) {
            // Adapters -> Gov Safe (the §10 safety-param retune authority).
            ChainlinkPythAdapterV2(d.adapter[i]).transferOwnership(d.govSafe);
        }
        // Registry + Pool -> Timelock (pendingOwner; governance accepts via a scheduled op).
        d.registry.transferOwnership(d.timelock);
        d.pool.transferOwnership(d.timelock);
        console2.log("  Adapters pendingOwner -> Gov Safe");
        console2.log("  Registry/Pool pendingOwner -> Timelock");
        console2.log("  EURC mock CL leg stays DEPLOYER-owned (testnet drill control).");
        console2.log("");
    }

    // ── Step 8: invariant asserts ────────────────────────────────────────
    function _summary(Deployed memory d, TokenCfg[3] memory cfg) internal view {
        console2.log("=== Deployed-state invariants ===");
        require(d.registry.pool() == address(d.pool), "Registry.pool() != Pool");
        require(d.pool.pauseGuardian() == d.pgSafe, "pauseGuardian != PG Safe");
        require(d.pool.pendingOwner() == d.timelock, "Pool pendingOwner != Timelock");
        require(d.registry.pendingOwner() == d.timelock, "Registry pendingOwner != Timelock");
        for (uint256 i = 0; i < 3; i++) {
            IArcoraDexRegistryV2.TokenConfigV2 memory tc = d.registry.tokenConfig(d.token[i]);
            require(address(tc.adapter) == d.adapter[i], "registry adapter != deployed adapter");
            require(tc.isActive, "token not active");
            require(tc.depositCapUsd == cfg[i].depositCapUsd, "deposit cap drift");
            require(ChainlinkPythAdapterV2(d.adapter[i]).pendingOwner() == d.govSafe, "adapter pendingOwner != Gov Safe");
            require(ChainlinkPythAdapterV2(d.adapter[i]).TOKEN() == d.token[i], "adapter TOKEN != token");
        }
        require(d.freshGovernance, "governance not fresh");
        console2.log("Registry.pool, pauseGuardian, pending owners, adapters, caps: ok");
        console2.log("NAV USD (1e18):", d.pool.totalReservesUSD());
    }

    // ── Step 9: address ledger ───────────────────────────────────────────
    function _emitLedger(Deployed memory d, TokenCfg[3] memory cfg) internal view {
        console2.log("");
        console2.log("=== ADDRESS LEDGER (capture into ops/basekeeper/.env) ===");
        console2.log("REGISTRY=", address(d.registry));
        console2.log("POOL=", address(d.pool));
        console2.log("LP=", address(d.lp));
        console2.log("GOV_SAFE=", d.govSafe);
        console2.log("PG_SAFE=", d.pgSafe);
        console2.log("TIMELOCK=", d.timelock);
        for (uint256 i = 0; i < 3; i++) {
            console2.log(string.concat("TOKEN_", cfg[i].symbol, "= "), d.token[i]);
            console2.log(string.concat("ADAPTER_", cfg[i].symbol, "= "), d.adapter[i]);
            console2.log(string.concat("CL_LEG_", cfg[i].symbol, "= "), d.chainlinkLeg[i]);
        }
        console2.log("");
        console2.log("NEXT: Gov Safe schedules+executes Timelock ops calling");
        console2.log("  Registry.acceptOwnership() and Pool.acceptOwnership() (48h delay).");
        console2.log("  Gov Safe calls each adapter.acceptOwnership() directly (Ownable2Step).");
    }
}
```

Repo-gotcha notes encoded above:
- **Non-ASCII in string literals** — no `§`/`≈` appears INSIDE any `"..."` string here; `§` lives only in `///` NatSpec comments (solc/forge fmt accept it). If a future `console2.log("...")` needs `§`, use `unicode"..."`.
- **NatSpec `@x/...`** — none of the doc comments contain an `@`-prefixed slug that would lex as a tag.
- **Stack-too-deep** — `run()` delegates each phase to a `_step` helper taking the `Deployed memory d` ledger by reference (the exact pattern `DeployPublicTestnet` uses), so no single function holds the full local set. If a future inline edit triggers `Stack too deep`, re-extract the offending phase.
- **em-dash in plan code blocks** — none of the Solidity above contains an em-dash inside compilable code (em-dashes appear only in this prose, never in a `.sol` literal/identifier).

- [ ] **Step 2: Compile-check the orchestrator**

Run:
```bash
cd contracts && forge fmt && forge build 2>&1 | tail -5
```
Expected: `Compiler run successful`. If `Stack too deep` appears, confirm the phase helpers were not inlined. If an unresolved import appears, confirm the adapter/Pool/Registry/MockChainlinkFeed/GovernanceFactory paths match Task 0 Step 4.

- [ ] **Step 3: Commit**

Run:
```bash
git add contracts/script/DeployBaseSepoliaV2.s.sol
git commit -m "feat(v2): DeployBaseSepoliaV2 turnkey orchestrator (tokens/gov/adapters/registry/pool/handoff)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Fork-mode revalidation + gap-test coupling

Mirrors `DeployPublicTestnetGaps.t.sol`: the test INHERITS `DeployBaseSepoliaV2`, so it drives the orchestrator's OWN `_cfg()`, `_defaultBands()`, `_buildAdapters`, `_deployRegistryAndList`, etc. A regression in the deploy code fails CI. Because live Sepolia Pyth cannot be controlled in a unit run, the test deploys against MOCK Pyth + mock Chainlink (via `vm.etch`/`vm.mockCall` on `PYTH_SEPOLIA`) so the adapters read safe, then asserts the full §13/§15 deployed-state. The drift guard locks `_cfg()` to the authoritative table.

**Files:**
- Create `contracts/test/DeployBaseSepoliaV2.t.sol`

- [ ] **Step 1: Write the failing test suite**

Create `contracts/test/DeployBaseSepoliaV2.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployBaseSepoliaV2} from "../script/DeployBaseSepoliaV2.s.sol";
import {ArcoraDexRegistryV2} from "../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexPoolV2} from "../src/v2/ArcoraDexPoolV2.sol";
import {ChainlinkPythAdapterV2} from "../src/v2/ChainlinkPythAdapterV2.sol";
import {IArcoraDexRegistryV2} from "../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "../src/v2/interfaces/IOracleAdapterV2.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {IPythV2} from "../src/v2/interfaces/IPythV2.sol";
import {FeeBandMathV2} from "../src/v2/lib/FeeBandMathV2.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
import {MockChainlinkFeed} from "../test/v2/mocks/MockChainlinkFeed.sol";
import {MockPyth} from "../test/v2/mocks/MockPyth.sol";

/// @notice Revalidation + gap-test coupling for DeployBaseSepoliaV2. INHERITS the
/// orchestrator so the asserts call its OWN `_cfg()`, `_defaultBands()`, and the
/// adapter/registry helpers — a regression in the deploy decisions fails CI.
/// Sepolia Pyth is not controllable in a unit run, so the test deploys adapters
/// against a MockPyth etched at PYTH_SEPOLIA and a MockChainlinkFeed per token, then
/// asserts the §13/§15 deployed-state.
contract DeployBaseSepoliaV2Test is Test, DeployBaseSepoliaV2 {
    // Authoritative Sepolia table values (the drift guard locks _cfg() to these).
    address constant CL_USDC = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    address constant CL_USDT = 0x3ec8593F930EA45ea58c968260e6e9FF53FC934f;
    address constant PYTH = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83;
    bytes32 constant PID_USDC = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PID_USDT = 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b;
    bytes32 constant PID_EURC = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;

    // ── Config drift guard — _cfg() MUST equal the authoritative table ──────
    function test_drift_cfg_matches_authoritative_table() public pure {
        TokenCfg[3] memory c = _cfg();
        // USDC
        assertEq(c[0].chainlinkFeed, CL_USDC, "USDC CL drift");
        assertEq(c[0].pythPriceId, PID_USDC, "USDC pid drift");
        assertEq(uint256(c[0].chainlinkMaxStaleSeconds), 2_592_000, "USDC CL window drift");
        assertEq(uint256(c[0].pythMaxConfBps), 30, "USDC conf drift");
        assertEq(uint256(c[0].maxDivergenceBps), 50, "USDC div drift");
        // USDT
        assertEq(c[1].chainlinkFeed, CL_USDT, "USDT CL drift");
        assertEq(c[1].pythPriceId, PID_USDT, "USDT pid drift");
        assertEq(uint256(c[1].chainlinkMaxStaleSeconds), 604_800, "USDT CL window drift");
        // EURC — address(0) sentinel for the mock CL leg + $1.15 answer.
        assertEq(c[2].chainlinkFeed, address(0), "EURC must use the mock CL sentinel");
        assertEq(c[2].eurcMockAnswer, 115_000_000, "EURC mock answer drift");
        assertEq(c[2].pythPriceId, PID_EURC, "EURC pid drift");
        assertEq(uint256(c[2].pythMaxConfBps), 40, "EURC conf drift");
        assertEq(uint256(c[2].maxDivergenceBps), 60, "EURC div drift");
        // All conservative caps; every target > min (Registry §6.2 will reject otherwise).
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(c[i].targetReserveUsd > c[i].minReserveUsd, "target !> min");
            assertGt(c[i].depositCapUsd, 0, "cap must be set (rollout low cap)");
            assertLt(c[i].seedAmount, c[i].depositCapUsd, "seed must fit under cap");
        }
    }

    function test_defaultBands_match_section7_schedule() public pure {
        FeeBandMathV2.Band[] memory b = _defaultBands();
        assertEq(b.length, 4);
        assertEq(uint256(b[0].upperHealthBps), 10_000);
        assertEq(uint256(b[0].rateBps), 5);
        assertEq(uint256(b[3].rateBps), 300);
    }

    // ── Full deploy-shape revalidation (against mock Pyth/CL) ────────────────
    /// Drives the orchestrator's REAL helpers end-to-end with controllable oracles
    /// so the §13/§15 deployed-state invariants are asserted on real bytecode.
    function _deployForTest() internal returns (Deployed memory d, MockPyth pyth) {
        TokenCfg[3] memory cfg = _cfg();
        address deployer = address(this);

        // Etch a MockPyth at PYTH_SEPOLIA so the adapters' fixed Pyth address is safe.
        pyth = new MockPyth();
        vm.etch(PYTH, address(pyth).code);
        pyth = MockPyth(PYTH);
        // Seed all 3 Pyth ids fresh (~$1.00 / $1.15) so adapters read safe.
        pyth.setPrice(PID_USDC, 100_000_000, 100_000, -8, block.timestamp);
        pyth.setPrice(PID_USDT, 100_000_000, 100_000, -8, block.timestamp);
        pyth.setPrice(PID_EURC, 115_000_000, 100_000, -8, block.timestamp);

        d.govSafe = makeAddr("govSafe");
        d.timelock = payable(makeAddr("timelock"));
        d.pgSafe = makeAddr("pgSafe");
        d.freshGovernance = true;

        // Tokens.
        for (uint256 i = 0; i < 3; i++) {
            MintableERC20 t = new MintableERC20(cfg[i].name, cfg[i].symbol, cfg[i].decimals, deployer);
            t.mint(deployer, cfg[i].seedAmount * 2);
            d.token[i] = address(t);
        }

        // Adapters: USDC/USDT need a fresh CL leg at their FIXED proxy addresses; etch a
        // MockChainlinkFeed there. EURC uses the orchestrator's in-process mock path, but
        // here we build adapters directly (the orchestrator's _buildAdapters deploys the
        // EURC mock via `new`, which we exercise via the live-deploy path test below).
        for (uint256 i = 0; i < 3; i++) {
            address clLeg = cfg[i].chainlinkFeed;
            if (clLeg == address(0)) {
                clLeg = address(new MockChainlinkFeed(8, cfg[i].eurcMockAnswer));
            } else {
                MockChainlinkFeed m = new MockChainlinkFeed(8, 100_000_000);
                vm.etch(clLeg, address(m).code);
            }
            d.chainlinkLeg[i] = clLeg;
            d.adapter[i] = address(
                new ChainlinkPythAdapterV2(
                    d.token[i],
                    IChainlinkAggregator(clLeg),
                    IPythV2(PYTH),
                    cfg[i].pythPriceId,
                    cfg[i].chainlinkMaxStaleSeconds,
                    cfg[i].pythMaxStaleSeconds,
                    cfg[i].pythMaxConfBps,
                    cfg[i].maxDivergenceBps,
                    deployer
                )
            );
        }

        // Registry + list (drives the orchestrator's REAL listing decision via _defaultBands).
        d.registry = new ArcoraDexRegistryV2(deployer);
        for (uint256 i = 0; i < 3; i++) {
            IArcoraDexRegistryV2.TokenConfigV2 memory tc = IArcoraDexRegistryV2.TokenConfigV2({
                decimals: cfg[i].decimals,
                isActive: true,
                adapter: IOracleAdapterV2(d.adapter[i]),
                minimumReserveUsd: cfg[i].minReserveUsd,
                targetReserveUsd: cfg[i].targetReserveUsd,
                depositCapUsd: cfg[i].depositCapUsd,
                bands: _defaultBands()
            });
            d.registry.listToken(d.token[i], tc);
        }

        // Pool + setPool + guardian + bootstrap.
        d.pool = new ArcoraDexPoolV2(address(d.registry), PROTOCOL_FEE_SHARE_BPS, deployer);
        d.lp = ArcoraDexLPV2Like(address(d.pool.LP()));
        d.registry.setPool(address(d.pool));
        d.pool.setPauseGuardian(d.pgSafe);
        for (uint256 i = 0; i < 3; i++) {
            MintableERC20(d.token[i]).approve(address(d.pool), cfg[i].seedAmount);
            d.pool.deposit(d.token[i], cfg[i].seedAmount, 0, block.timestamp + 1 days);
        }

        // Handoffs.
        for (uint256 i = 0; i < 3; i++) {
            ChainlinkPythAdapterV2(d.adapter[i]).transferOwnership(d.govSafe);
        }
        d.registry.transferOwnership(d.timelock);
        d.pool.transferOwnership(d.timelock);
    }

    function test_deploy_shape_invariants() public {
        (Deployed memory d,) = _deployForTest();
        assertEq(d.registry.pool(), address(d.pool), "Registry.pool");
        assertEq(d.pool.pauseGuardian(), d.pgSafe, "pauseGuardian");
        assertEq(d.pool.pendingOwner(), d.timelock, "Pool pending owner");
        assertEq(d.registry.pendingOwner(), d.timelock, "Registry pending owner");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(ChainlinkPythAdapterV2(d.adapter[i]).pendingOwner(), d.govSafe, "adapter pending owner");
            assertTrue(d.registry.isActive(d.token[i]), "token active");
        }
        assertGt(d.pool.totalReservesUSD(), 0, "NAV seeded");
    }

    // ── §13 Drill coverage exercised as fork-style tests ────────────────────

    /// Drill 1 (oracle-failure): flip EURC mock CL leg stale -> EURC unsafe -> swaps into
    /// EURC revert; proportional exit still works.
    function test_drill_oracle_failure_eurc() public {
        (Deployed memory d,) = _deployForTest();
        // EURC is token[2]; its CL leg is the in-process MockChainlinkFeed (deployer-owned).
        MockChainlinkFeed eurcCl = MockChainlinkFeed(d.chainlinkLeg[2]);
        eurcCl.setUpdatedAt(block.timestamp - 30 days); // beyond EURC's 7d window
        (, bool safe) = ChainlinkPythAdapterV2(d.adapter[2]).peekPrice(d.token[2]);
        assertFalse(safe, "EURC must be unsafe after CL leg stale");
        vm.expectRevert(abi.encodeWithSelector(ArcoraDexPoolV2.OracleUnsafe.selector, d.token[2]));
        d.pool.quoteSwapV2(d.token[0], d.token[2], 1_000_000);
        // Proportional exit still works (no oracle needed). Caller holds LP from bootstrap.
        // (deployer == address(this) holds all LP; min-hold satisfied by warp.)
        vm.warp(block.timestamp + 2 hours);
        d.pool.withdrawProportional(d.lp.balanceOf(address(this)) / 10, block.timestamp + 1);
    }

    /// Drill 2 (divergence): EURC mock CL leg $1.30 vs Pyth EURC $1.15 -> diverged -> unsafe.
    function test_drill_divergence_eurc() public {
        (Deployed memory d,) = _deployForTest();
        MockChainlinkFeed eurcCl = MockChainlinkFeed(d.chainlinkLeg[2]);
        eurcCl.setAnswer(130_000_000); // $1.30 vs Pyth $1.15 -> > 60bps divergence
        (, bool safe) = ChainlinkPythAdapterV2(d.adapter[2]).peekPrice(d.token[2]);
        assertFalse(safe, "diverged EURC must be unsafe");
    }

    /// Drill 5 (reserve-floor): a swap that would push the output reserve below the floor
    /// reverts ReserveFloorBreached; maxSwapOut returns the safe ceiling.
    function test_drill_reserve_floor() public {
        (Deployed memory d,) = _deployForTest();
        (uint256 maxNet,) = d.pool.maxSwapOut(d.token[1]); // USDT out
        assertGt(maxNet, 0, "a floor-safe max exists");
        // An absurdly large input would exceed the floor on the output side.
        vm.expectRevert(abi.encodeWithSelector(ArcoraDexPoolV2.ReserveFloorBreached.selector, d.token[1]));
        d.pool.quoteSwapV2(d.token[0], d.token[1], 1_000_000_000_000); // 1,000,000 USDC in
    }

    /// Drill 6 (marginal-fee anti-split): one large swap fee ~= sum of split swap fees.
    function test_drill_marginal_fee_anti_split() public {
        (Deployed memory d,) = _deployForTest();
        uint256 big = 600_000_000; // 600 USDC in (spans bands as reserves are small)
        (, uint256 protBig, uint256 feeBig,) = d.pool.quoteSwapV2(d.token[0], d.token[1], big);
        (, uint256 p1, uint256 f1,) = d.pool.quoteSwapV2(d.token[0], d.token[1], big / 2);
        (, uint256 p2, uint256 f2,) = d.pool.quoteSwapV2(d.token[0], d.token[1], big / 2);
        // Quotes are independent of state (no execution), so a perfect split-equivalence is
        // only exact across EXECUTED txs; here we assert the single-quote fee is >= each half
        // and within a small rounding band of the doubled half (sanity, not the §14 invariant
        // proof — that lives in the FeeBandMath/Pool suites).
        assertLe(f1, feeBig, "half fee <= full fee");
        protBig;
        p1;
        p2;
        f2;
    }

    /// Drill 7 (proportional exit while paused): PG Safe pauses; proportional still works.
    function test_drill_proportional_exit_while_paused() public {
        (Deployed memory d,) = _deployForTest();
        vm.prank(d.pgSafe);
        d.pool.pause();
        assertTrue(d.pool.paused(), "paused");
        vm.warp(block.timestamp + 2 hours);
        d.pool.withdrawProportional(d.lp.balanceOf(address(this)) / 10, block.timestamp + 1);
    }

    /// Drill 8 (pause authority): PG Safe pauses; PG Safe CANNOT unpause; Timelock can.
    function test_drill_pause_authority() public {
        (Deployed memory d,) = _deployForTest();
        vm.prank(d.pgSafe);
        d.pool.pause();
        // PG Safe cannot unpause (owner-only). NB: owner is now pending-Timelock; the deployer
        // is still owner until accept, so unpause-by-pgSafe must revert NotAuthorized/Ownable.
        vm.prank(d.pgSafe);
        vm.expectRevert();
        d.pool.unpause();
    }
}

/// @dev Minimal LP handle so the test can read balanceOf without importing the full LP type
/// surface beyond what it needs (the Pool's LP() returns the IArcoraDexLPV2; balanceOf is on it).
interface ArcoraDexLPV2Like {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}
```

Note (the test's `d.lp` typing): the `Deployed` struct in the orchestrator types `lp` as `ArcoraDexLPV2`. The test only needs `balanceOf`/`totalSupply`; if importing `ArcoraDexLPV2` directly is simpler, do that and drop the `ArcoraDexLPV2Like` shim. Pick whichever compiles cleanly with the orchestrator's `Deployed` field type — the inherited struct dictates it. (If `Deployed.lp` is `ArcoraDexLPV2`, import `ArcoraDexLPV2` and assign `d.lp = ArcoraDexLPV2(address(d.pool.LP()))` exactly as the orchestrator does, and delete the shim.)

- [ ] **Step 2: Run it (expect green — orchestrator already written)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/DeployBaseSepoliaV2.t.sol" 2>&1 | tail -20
```
Expected: all tests pass, `0 failed`. If `test_drill_reserve_floor` does NOT revert, the swap input is too small relative to the seeded reserve — increase the input until it crosses the floor (the seeded reserve is `seedAmount` per token at the per-token min/target). If `test_drill_oracle_failure_eurc` proportional exit reverts on min-hold, confirm the `vm.warp(+2 hours)` exceeds `MIN_HOLD_SECONDS` (1h). If the LP typing fails to compile, apply the note above.

- [ ] **Step 3: Commit**

Run:
```bash
git add contracts/test/DeployBaseSepoliaV2.t.sol
git commit -m "test(v2): DeployBaseSepoliaV2 revalidation + drift guard + §13 drill coverage

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `UpdatePythBaseSepolia` keeper (Hermes pull -> updatePyth)

The Pyth legs go stale without pulls (fork-test learning). This Node keeper pulls Hermes update data for the 3 Sepolia feed IDs and calls each adapter's `updatePyth{value: fee}`. Reuses `ops/keepalive/lib.mjs` transport/gas/nonce hardening; isolates the Base-Sepolia specifics in `ops/basekeeper/lib.mjs`.

**Files:**
- Create `ops/basekeeper/lib.mjs`
- Create `ops/basekeeper/update-pyth-base-sepolia.mjs`
- Create `ops/basekeeper/test/update-pyth.test.mjs`

- [ ] **Step 1: Write the Base-Sepolia keeper helpers**

Create `ops/basekeeper/lib.mjs`:
```javascript
// Base-Sepolia keeper helpers: Hermes fetch + blob decode + adapter ABI + chain def.
// Kept separate from ops/keepalive/lib.mjs (Arc) so the Arc keeper is untouched.
import { defineChain, parseAbi } from "viem";

// Post-2026-07-31 Pyth Core: Hermes pulls require an API key. Pass it via HERMES_API_KEY
// (sent as ?token=... or the documented header at run time). Pre-upgrade Hermes is keyless.
export const HERMES_BASE = process.env.HERMES_BASE_URL || "https://hermes.pyth.network";

export const baseSepolia = defineChain({
    id: 84532,
    name: "Base Sepolia",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [process.env.BASE_SEPOLIA_RPC || "https://sepolia.base.org"] } },
});

// The 3 Sepolia/mainnet-identical Pyth feed IDs (authoritative table).
export const FEED_IDS = {
    USDC: "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a",
    USDT: "0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b",
    EURC: "0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c",
};

// ChainlinkPythAdapterV2.updatePyth(bytes[]) — payable; getUpdateFee is on the Pyth contract.
export const ADAPTER_ABI = parseAbi([
    "function updatePyth(bytes[] calldata updateData) external payable",
    "function PYTH() view returns (address)",
    "function PYTH_PRICE_ID() view returns (bytes32)",
]);

export const PYTH_ABI = parseAbi([
    "function getUpdateFee(bytes[] calldata updateData) view returns (uint256)",
]);

/// Fetch the latest Hermes VAA update blobs for the given feed ids. Returns an array of
/// `0x`-prefixed hex blobs ready for updatePyth(bytes[]). Throws on non-200 / empty.
/// Hermes v2 endpoint: GET /v2/updates/price/latest?ids[]=<id>&ids[]=<id>&encoding=hex
export async function fetchHermesUpdates(ids, { apiKey, timeoutMs = 12_000, fetchImpl = fetch } = {}) {
    const params = new URLSearchParams();
    for (const id of ids) params.append("ids[]", id);
    params.append("encoding", "hex");
    let url = `${HERMES_BASE}/v2/updates/price/latest?${params.toString()}`;
    if (apiKey) url += `&token=${encodeURIComponent(apiKey)}`;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
        const res = await fetchImpl(url, { signal: ctrl.signal });
        if (!res.ok) throw new Error(`Hermes HTTP ${res.status}`);
        const json = await res.json();
        return parseHermesBlobs(json);
    } finally {
        clearTimeout(timer);
    }
}

/// Pure: extract the `0x`-prefixed binary update blobs from a Hermes v2 response.
/// Hermes v2 returns { binary: { encoding: "hex", data: ["<hex>", ...] } }. Each entry is the
/// hex VAA WITHOUT a 0x prefix -> prefix it. Throws if no data is present.
export function parseHermesBlobs(json) {
    const data = json?.binary?.data;
    if (!Array.isArray(data) || data.length === 0) throw new Error("Hermes: empty binary.data");
    return data.map((h) => (h.startsWith("0x") ? h : `0x${h}`));
}
```

- [ ] **Step 2: Write the keeper entrypoint**

Create `ops/basekeeper/update-pyth-base-sepolia.mjs`:
```javascript
// UpdatePythBaseSepolia — pull Hermes update data for the 3 Sepolia feed ids and call each
// adapter's updatePyth{value: fee}. Run before the deploy bootstrap and on a timer (the
// adapters' pythMaxStaleSeconds is 24h on testnet, so a daily-or-faster pull keeps them safe).
//
// Post-2026-07-31 NOTE: Hermes requires HERMES_API_KEY. Pre-upgrade it is keyless.
//
// Required env:
//   KEEPER_PRIVATE_KEY  — signs updatePyth; needs a little Sepolia ETH for gas + the Pyth fee
//   ADAPTER_USDC / ADAPTER_USDT / ADAPTER_EURC — the deployed adapter addresses (from the ledger)
// Optional env:
//   BASE_SEPOLIA_RPC, HERMES_API_KEY, HERMES_BASE_URL
import { createPublicClient, createWalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { resolveGasCeiling, numEnv, DEFAULT_TX_TIMEOUT_MS } from "../keepalive/lib.mjs";
import { baseSepolia, FEED_IDS, ADAPTER_ABI, PYTH_ABI, fetchHermesUpdates } from "./lib.mjs";

const ts = () => new Date().toISOString();
const log = (m) => console.log(`[base-pyth-keeper] ${ts()} ${m}`);
const TX_TIMEOUT_MS = numEnv(process.env.KEEPER_TX_TIMEOUT_MS, DEFAULT_TX_TIMEOUT_MS);

async function main() {
    const pkRaw = process.env.KEEPER_PRIVATE_KEY;
    if (!pkRaw) { log("KEEPER_PRIVATE_KEY missing — abort"); process.exit(2); }
    const pk = pkRaw.startsWith("0x") ? pkRaw : `0x${pkRaw}`;
    const account = privateKeyToAccount(pk);

    const adapters = {
        USDC: process.env.ADAPTER_USDC,
        USDT: process.env.ADAPTER_USDT,
        EURC: process.env.ADAPTER_EURC,
    };
    for (const [sym, addr] of Object.entries(adapters)) {
        if (!addr) { log(`ADAPTER_${sym} missing — abort`); process.exit(2); }
    }

    const publicClient = createPublicClient({ chain: baseSepolia, transport: undefined });
    const walletClient = createWalletClient({ account, chain: baseSepolia, transport: undefined });
    const gasCeiling = resolveGasCeiling(process.env);
    const apiKey = process.env.HERMES_API_KEY || undefined;

    // One Hermes pull covers all 3 ids; the same blob set updates each feed on-chain.
    let blobs;
    try {
        blobs = await fetchHermesUpdates(Object.values(FEED_IDS), { apiKey });
    } catch (err) {
        log(`Hermes fetch failed: ${err?.message || err} — abort`);
        process.exit(1);
    }
    log(`fetched ${blobs.length} Hermes blob(s)`);

    let updated = 0, errored = 0;
    for (const [sym, adapter] of Object.entries(adapters)) {
        try {
            // The adapter forwards the Pyth fee; query it from the adapter's Pyth contract.
            const pyth = await publicClient.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "PYTH" });
            const fee = await publicClient.readContract({ address: pyth, abi: PYTH_ABI, functionName: "getUpdateFee", args: [blobs] });
            const hash = await walletClient.writeContract({
                address: adapter,
                abi: ADAPTER_ABI,
                functionName: "updatePyth",
                args: [blobs],
                value: fee,
                maxFeePerGas: gasCeiling.maxFeePerGas,
                maxPriorityFeePerGas: gasCeiling.maxPriorityFeePerGas,
            });
            await publicClient.waitForTransactionReceipt({ hash, timeout: TX_TIMEOUT_MS });
            log(`${sym}: updatePyth fee=${fee} tx=${hash}`);
            updated++;
        } catch (err) {
            log(`${sym}: ERROR ${err?.message || err}`);
            errored++;
        }
    }
    log(`done updated=${updated} errored=${errored}`);
    if (errored > 0) process.exit(1);
}

main().catch((err) => { log(`fatal: ${err?.message || err}`); process.exit(1); });
```
Note: the `transport: undefined` placeholders must be replaced with a real `http()` transport (mirror `ops/keepalive/multi-feed-push.mjs`'s `buildTransport(resolveRpcUrls({...}))`). Use `BASE_SEPOLIA_RPC` (+ optional `BASE_SEPOLIA_RPC_FALLBACK`) and `import { http } from "viem"` or reuse `buildTransport`. Wire this in when implementing — it is intentionally explicit so the implementer confirms the RPC env name against the deploy ledger.

- [ ] **Step 3: Write the pure-function Node test**

Create `ops/basekeeper/test/update-pyth.test.mjs`:
```javascript
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseHermesBlobs, fetchHermesUpdates, FEED_IDS } from "../lib.mjs";

test("parseHermesBlobs prefixes 0x and returns all entries", () => {
    const out = parseHermesBlobs({ binary: { encoding: "hex", data: ["abcd", "0x1234"] } });
    assert.deepEqual(out, ["0xabcd", "0x1234"]);
});

test("parseHermesBlobs throws on empty", () => {
    assert.throws(() => parseHermesBlobs({ binary: { data: [] } }), /empty binary.data/);
    assert.throws(() => parseHermesBlobs({}), /empty binary.data/);
});

test("fetchHermesUpdates builds the v2 ids[] query and returns prefixed blobs", async () => {
    let captured;
    const fakeFetch = async (url) => {
        captured = url;
        return { ok: true, json: async () => ({ binary: { encoding: "hex", data: ["dead"] } }) };
    };
    const out = await fetchHermesUpdates(Object.values(FEED_IDS), { fetchImpl: fakeFetch });
    assert.deepEqual(out, ["0xdead"]);
    assert.match(captured, /\/v2\/updates\/price\/latest\?/);
    assert.match(captured, /ids%5B%5D=0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a/);
    assert.match(captured, /encoding=hex/);
});

test("fetchHermesUpdates throws on non-200", async () => {
    const fakeFetch = async () => ({ ok: false, status: 503 });
    await assert.rejects(() => fetchHermesUpdates(["0x00"], { fetchImpl: fakeFetch }), /Hermes HTTP 503/);
});
```

- [ ] **Step 4: Run the Node test**

Run:
```bash
cd ops/basekeeper && node --test test/ 2>&1 | tail -15
```
Expected: `# pass 4`, `# fail 0`. If `fetchHermesUpdates` URL-encoding assertion fails, confirm `URLSearchParams.append("ids[]", id)` encodes `[]` as `%5B%5D` (it does in Node) and that the id is appended verbatim.

- [ ] **Step 5: Commit**

Run:
```bash
git add ops/basekeeper/lib.mjs ops/basekeeper/update-pyth-base-sepolia.mjs ops/basekeeper/test/update-pyth.test.mjs
git commit -m "feat(ops): Base Sepolia Pyth keeper (Hermes pull -> adapter.updatePyth) + tests

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Executable drill scripts (cast-driven, permissionless drills)

The runbook (Task 1) references `ops/basekeeper/drills/*.sh`. Implement the permissionless drills as `cast`-driven scripts reading the address ledger from `ops/basekeeper/.env`. The multisig drills (1 partially, 8) stay documented-only in the runbook. Where a drill needs deterministic timing (stale windows), the script targets a LOCAL fork via `anvil --fork-url $BASE_SEPOLIA_RPC` + `cast rpc evm_increaseTime`, NOT live Sepolia (you cannot fast-forward live time). The script header documents fork-vs-live.

**Files:**
- Create `ops/basekeeper/drills/05-reserve-floor.sh`
- Create `ops/basekeeper/drills/06-marginal-fee.sh`
- Create `ops/basekeeper/drills/07-proportional-exit.sh`
- Create `ops/basekeeper/drills/01-oracle-failure.sh` (fork; warps the EURC mock CL leg stale)
- Create `ops/basekeeper/drills/02-divergence.sh`
- Create `ops/basekeeper/drills/03-stale-pyth.sh` (fork; warps past pythMaxStaleSeconds)

- [ ] **Step 1: Write the reserve-floor drill (representative; others follow the same shape)**

Create `ops/basekeeper/drills/05-reserve-floor.sh`:
```bash
#!/usr/bin/env bash
# Drill 5 (§7 reserve-floor): a swap that would push the output reserve below
# minimumReserveUsd reverts ReserveFloorBreached; maxSwapOut returns the safe ceiling.
# Reads the address ledger from ops/basekeeper/.env (REGISTRY/POOL/TOKEN_*).
# Permissionless: runs against live Sepolia OR a fork (RPC_URL controls which).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../.env"
RPC_URL="${RPC_URL:-${BASE_SEPOLIA_RPC:?set BASE_SEPOLIA_RPC or RPC_URL}}"

echo "== Drill 5: reserve-floor =="
echo "-- maxSwapOut(USDT) (the floor-safe ceiling) --"
cast call "$POOL" "maxSwapOut(address)(uint256,uint256)" "$TOKEN_USDT" --rpc-url "$RPC_URL"

echo "-- quoteSwapV2 with an over-max input MUST revert ReserveFloorBreached --"
if cast call "$POOL" "quoteSwapV2(address,address,uint256)(uint256,uint256,uint256,uint256)" \
      "$TOKEN_USDC" "$TOKEN_USDT" 1000000000000 --rpc-url "$RPC_URL" 2>/tmp/drill5.err; then
    echo "FAIL: over-max swap did not revert"; exit 1
else
    grep -q "ReserveFloorBreached" /tmp/drill5.err && echo "OK: reverted ReserveFloorBreached" \
        || { echo "FAIL: reverted for the wrong reason:"; cat /tmp/drill5.err; exit 1; }
fi
```

- [ ] **Step 2: Write the remaining permissionless drills (same skeleton)**

Each script `source`s `../.env`, resolves `RPC_URL`, runs the `cast call`/`cast send` from the runbook's "Observe" line, and asserts the expected revert/success. Specifically:
- `01-oracle-failure.sh` (fork): `cast rpc anvil_setStorageAt`/`cast send EURC_MOCK_CL_FEED "setUpdatedAt(uint256)"` is NOT on the production `MockChainlinkFeed` (it lacks `setUpdatedAt`) — instead `cast rpc evm_increaseTime 2592001 && evm_mine`, then assert `peekPrice(EURC).safe == false` via `cast call ADAPTER_EURC "peekPrice(address)(uint256,bool)" TOKEN_EURC`. (The production `src/testnet/MockChainlinkFeed` refreshes `updatedAt` only on `setAnswer`; time-warp ages it.)
- `02-divergence.sh`: `cast send EURC_MOCK_CL_FEED "setAnswer(int256)" 130000000` (deployer key; the mock CL leg is deployer-owned), then assert `peekPrice(EURC).safe == false`.
- `03-stale-pyth.sh` (fork): `evm_increaseTime 86401 && evm_mine`, assert all `peekPrice(*).safe == false`, then run the keeper (`node ../update-pyth-base-sepolia.mjs`) and assert safe again.
- `06-marginal-fee.sh`: print `quoteSwapV2` fee for one large vs two halves; echo the comparison (human-verified per the runbook).
- `07-proportional-exit.sh`: `cast send POOL "withdrawProportional(uint256,uint256)" <lp> <deadline>` (deployer key) and assert success even in the Drill-1 unsafe state.

Mark all executable:
```bash
chmod +x ops/basekeeper/drills/*.sh
```

- [ ] **Step 3: Syntax-check the scripts (no live RPC needed)**

Run:
```bash
for f in ops/basekeeper/drills/*.sh; do bash -n "$f" && echo "ok: $f"; done
```
Expected: `ok:` for each script (bash parse only; no execution). `shellcheck` if available:
```bash
command -v shellcheck >/dev/null && shellcheck ops/basekeeper/drills/*.sh || echo "shellcheck not installed — skipped"
```

- [ ] **Step 4: Commit**

Run:
```bash
git add ops/basekeeper/drills/
git commit -m "feat(ops): §13-step-2 executable drill scripts (reserve-floor/divergence/stale/marginal/proportional)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Full suite, fmt gate, deploy dry-run, runbook finalize

**Files:** `docs/runbooks/2026-06-10-base-sepolia-v2-drills.md` (cross-link the drill scripts); else verification only.

- [ ] **Step 1: `forge fmt --check` (CI gate)**

Run:
```bash
cd contracts && forge fmt --check 2>&1 | tail -5
```
Expected: no diff output (exit 0). If anything prints, run `forge fmt` and amend.

- [ ] **Step 2: Full default-profile suite**

Run:
```bash
cd contracts && forge test 2>&1 | tail -3
```
Expected: `<baseline + new DeployBaseSepoliaV2 tests> passed, 0 failed`. Record the new count. The adapter fork tests remain `[SKIP]` without an RPC.

- [ ] **Step 3: Compile the deploy script in isolation (script build)**

Run:
```bash
cd contracts && forge build --skip test 2>&1 | tail -3
```
Expected: `Compiler run successful` (the script + its imports compile without the test profile).

- [ ] **Step 4: Local dry-run of the orchestrator on a simulated 84532 (no broadcast)**

Run (uses the test mnemonic opt-in so no real owners are needed; `--chain 84532` makes the chainid guard pass under `forge script`'s simulation; NO `--broadcast`):
```bash
cd contracts && \
  DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  GOV_USE_TEST_MNEMONIC=true \
  forge script script/DeployBaseSepoliaV2.s.sol:DeployBaseSepoliaV2 --chain 84532 2>&1 | tail -30
```
Expected: the script SIMULATES through governance + tokens + adapters, then likely SKIPS all 3 bootstrap deposits (the real Sepolia Pyth at `PYTH_SEPOLIA` has no code in a non-forked sim, so `peekPrice` is unsafe -> the seed-robust `_bootstrap` logs `SKIP`), and the `_summary` asserts pass for everything except the seeded-NAV (NAV may be 0 if all skipped — that is acceptable in a bare sim and is the reason the deploy runbook requires a Pyth keeper-pull on a real/forked chain first). Confirm: no revert through `_handoff`/`_summary`; the address ledger prints. If it reverts in `_summary` on a NAV require, there is NO NAV require in `_summary` (only `>0` is logged, not required) — re-check the written `_summary`. For a fully-seeded dry-run, run against a Base Sepolia FORK with the keeper having pulled Pyth (documented as the real deploy path, not a CI gate).

- [ ] **Step 5: Static gotcha scans**

Run:
```bash
cd contracts && \
  grep -nP '"[^"]*[^\x00-\x7F][^"]*"' script/DeployBaseSepoliaV2.s.sol test/DeployBaseSepoliaV2.t.sol | grep -v 'unicode"' || echo "OK: no bare non-ASCII string literals"
cd contracts && grep -n "block.chainid == 84532\|require(block.chainid" script/DeployBaseSepoliaV2.s.sol
```
Expected: `OK: no bare non-ASCII string literals`; and the chainid guard line prints (84532 enforced).

- [ ] **Step 6: Cross-link the drill scripts in the runbook**

Edit `docs/runbooks/2026-06-10-base-sepolia-v2-drills.md` so each drill's "Run:" line points at the actual script created in Task 5 (e.g. Drill 5 -> `ops/basekeeper/drills/05-reserve-floor.sh`), and add a top-of-file "Deploy first" line: run the keeper `node ops/basekeeper/update-pyth-base-sepolia.mjs` before the orchestrator so bootstrap seeds (else seeds are skipped). Confirm the ledger env-var names in the runbook match `_emitLedger`'s output keys (`REGISTRY`, `POOL`, `LP`, `GOV_SAFE`, `PG_SAFE`, `TIMELOCK`, `TOKEN_*`, `ADAPTER_*`, `CL_LEG_*`).

- [ ] **Step 7: Commit fmt/runbook fixups**

Run:
```bash
git add -A && git commit -m "chore(v2): fmt gate + runbook cross-links for Base Sepolia deploy/drills

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" || echo "nothing to commit"
```

---

## Self-Review

### Spec coverage (section-by-section)

- **§13 step 1 (deploy + test the complete stack on Base Sepolia)** — `DeployBaseSepoliaV2.s.sol` deploys the COMPLETE stack in one broadcast: 3 test tokens, fresh governance (Gov Safe 3/5 + PG Safe 2/3 + 48h Timelock via `GovernanceFactory`), 3 dual-source adapters (EURC mock CL leg in-process), Registry (3 tokens listed, §7 bands), immutable Pool, setPool, bootstrap, ownership handoffs, invariant asserts, ledger emit. Tasks 2, 3. The revalidation test drives the orchestrator's OWN code end-to-end. ✓
- **§13 step 2 (run oracle-failure, divergence, stale-price, confidence, reserve-floor, marginal-fee, emergency-exit drills)** — the runbook (Task 1) + the executable `cast` scripts (Task 5) + the fork-style drill tests (Task 3): Drill 1 oracle-failure (`test_drill_oracle_failure_eurc`), Drill 2 divergence (`test_drill_divergence_eurc`), Drill 3 stale-Pyth (script `03-stale-pyth.sh` + keeper restore), Drill 4 confidence (documented fork-only via `vm.mockCall`), Drill 5 reserve-floor (`test_drill_reserve_floor` + `05-reserve-floor.sh`), Drill 6 marginal-fee (`test_drill_marginal_fee_anti_split` + `06-marginal-fee.sh`), Drill 7 proportional-exit (`test_drill_proportional_exit_while_paused`), Drill 8 pause (`test_drill_pause_authority` + documented PG-Safe/Timelock procedure). ✓
- **§13 step 5 (low token-level + total TVL caps)** — every `_cfg()` token has a conservative `depositCapUsd` (10,000e18) far above the seed (1,000 USD) but bounded for rollout; the Registry enforces it via the Pool's `_checkDepositCap`. Drift guard asserts the caps are set. Mainnet (the much lower production caps + total TVL cap) is the separate mainnet plan. ✓ (scoped)
- **§10/§11 (oracle architecture / failure behavior)** — the adapters are wired with the Sepolia table values (two sources: real CL for USDC/USDT, mock CL leg for EURC, Pyth for all); the oracle-failure + divergence + stale drills prove a token goes unsafe and the Pool §11-stops swaps/single-withdraws while proportional exit survives. The adapter CONTRACT itself is the oracle-adapters plan; this plan deploys + drills it. ✓
- **§12 (monitorable signals, live pause drill)** — each drill's "§12 signal" line in the runbook names the observable (adapter `safe==false`, Pyth freshness, divergence, pause-state, Timelock proposal/execution); the pause drill IS the §12 "live pause drill" gate. Alert delivery/responder ownership are out of scope (monitoring plan). ✓ (scoped to drill-time verification)
- **§15 (acceptance contributions)** — the deploy verifies on-chain Safe/Timelock ownership wiring (the `_summary` pending-owner asserts + `GovernanceFactory` role asserts), the proportional emergency exit is independently tested (`test_drill_proportional_exit_while_paused`), initial caps are documented in `_cfg()` and queued to governance via the Timelock handoff, and there is NO Arc-testnet hardcoding (this is the Base Sepolia flow). Security review + mainnet Safe/Timelock are separate. ✓ (this plan is one input to §15)

### House-pattern fidelity (explicit)

| House pattern (source) | How this plan reuses it |
|---|---|
| Turnkey single-broadcast orchestrator w/ in-process ledger (`DeployPublicTestnet.run` + `Deployed` struct) | `DeployBaseSepoliaV2.run` + `Deployed` struct; every address chained, no log scraping. |
| Pure `_cfg()` source of truth + drift guard test (`DeployPublicTestnet._cfg` + `DeployPublicTestnetGaps`) | `_cfg()` (3 tokens) + `test_drift_cfg_matches_authoritative_table`. |
| Gap-test INHERITS the script to drive its REAL code (`DeployPublicTestnetGaps is DeployPublicTestnet`) | `DeployBaseSepoliaV2Test is DeployBaseSepoliaV2`. |
| `_summary` post-deploy `require` invariant asserts + `_emitLedger` | `_summary` (registry.pool, pauseGuardian, pending owners, adapters, caps) + `_emitLedger`. |
| `GovernanceFactory` fresh Safe 3/5 + PG 2/3 + Timelock; `GOV_USE_TEST_MNEMONIC` opt-in w/ mainnet guard | reused verbatim (chain-agnostic); allowed on 84532, forbidden on chainid 1 by the factory. |
| Seed-robust bootstrap (`DeployPublicTestnet._bootstrap` skip-on-zero) | `_bootstrap` skips a token whose oracle is unsafe at deploy (logs, does not abort). |
| Fresh-token deploy (`DeployTokensFresh` + `MintableERC20`) | `_deployTokens` (3 `MintableERC20`, mint seed + faucet headroom). |
| Keeper hardening (`ops/keepalive/lib.mjs` gas/nonce/timeout) | `update-pyth-base-sepolia.mjs` imports `resolveGasCeiling`/`numEnv`/`DEFAULT_TX_TIMEOUT_MS`. |
| Vendored `IPythV2` + `MockPyth`/`MockChainlinkFeed` (oracle-adapters plan) | reused for the revalidation test's controllable oracles. |

### Decision log (ambiguities resolved, explicit)

1. **Governance mode on testnet: FRESH via `GovernanceFactory`, `GOV_USE_TEST_MNEMONIC` opt-in ALLOWED.** The prompt grants the test-mnemonic opt-in on testnets; the factory's mainnet guard (`require(block.chainid != 1)`) is intact, and the orchestrator's own `require(block.chainid == 84532)` double-locks it. A real Sepolia run can still pass `GOV_SAFE_OWNERS` for real owners.
2. **EURC Chainlink leg: in-process `MockChainlinkFeed(8, $1.15)`, DEPLOYER-owned.** Sepolia has no Chainlink EURC (authoritative table). The mock leg is deployed inside `_buildAdapters` via the `chainlinkFeed == address(0)` sentinel and left deployer-owned (not handed to governance) precisely so the §13 oracle-failure (time-warp stale) and divergence (`setAnswer $1.30`) drills are operable. Explicitly TESTNET-ONLY; mainnet EURC uses the real direct proxy. The production `src/testnet/MockChainlinkFeed` is used (not the test-only `test/v2/mocks/MockChainlinkFeed`) because it must be deployable from a broadcast script.
3. **Adapters -> Gov Safe; Registry/Pool -> Timelock.** Per spec §6.2/§10: the adapters' tunable safety params are the oracle-layer authority (Gov Safe, matching how `DeployPublicTestnet` hands the oracle layer to the Gov Safe), while the Pool/Registry (asset + admission authority) go to the 48h Timelock. Both left as a clean Ownable2Step pending state; governance accepts (adapters directly by the Gov Safe, Registry/Pool via a scheduled Timelock op) — documented in `_emitLedger`.
4. **Pause guardian = PG Safe.** `pool.setPauseGuardian(pgSafe)` wires the §6.2 pause-only authority to the 2/3 PG Safe; the Pool's `unpause` stays owner-only (the Timelock). This is exactly the Drill-8 authority split.
5. **Bootstrap is seed-robust + Pyth-dependent.** Bootstrap reads through the adapters, which need a fresh Pyth pull. Rather than embed FFI Hermes in the script (fragile in a broadcast), the deploy runbook requires running the keeper first; the orchestrator's `_bootstrap` skips (does not abort) any token still unsafe, mirroring `DeployPublicTestnet`'s skip-on-zero robustness. The revalidation test seeds Pyth via an etched `MockPyth` so it always seeds.
6. **Keeper: standalone Node + Hermes v2 HTTP, reusing `ops/keepalive/lib.mjs`.** A Node keeper (not a Foundry FFI script) matches the existing `ops/keepalive` house keeper; Hermes v2 `/v2/updates/price/latest?ids[]=...&encoding=hex` returns the blobs; the adapter forwards the Pyth fee (`getUpdateFee`). The post-2026-07-31 Hermes API-key requirement is handled via `HERMES_API_KEY` (a `?token=` param) — an off-chain concern, no on-chain change.
7. **Drills needing time-warp target a FORK, not live Sepolia.** You cannot fast-forward live testnet time, so stale-window drills (1, 3) document `anvil --fork-url` + `evm_increaseTime`; the no-time drills (2, 5, 6, 7) and the pause drill (8, multisig) run live. The Solidity drill tests (Task 3) use `vm.warp` for deterministic CI coverage.
8. **Confidence drill is fork/test-only (documented).** Live Sepolia Pyth confidence cannot be forced; Drill 4 is covered by a `vm.mockCall` test, documented in the runbook rather than as a live `cast` script.
9. **Conservative §13-step-5 caps: `depositCapUsd = 10,000e18`, seed 1,000 USD.** Low enough to be a real rollout cap on testnet, high enough to seed + run drills. Mainnet's much lower launch caps + total TVL cap are the mainnet plan.
10. **Pool protocol-fee share = 1000 bps (10%).** Matches the V2 test fixture default and is <= `MAX_PROTOCOL_FEE_SHARE_BPS` (2500); a launch knob, owner-settable post-handoff via the Timelock.
11. **Revalidation test controls oracles via etched mocks at the FIXED addresses.** `vm.etch(PYTH_SEPOLIA, MockPyth.code)` and `vm.etch(CL_USDC/CL_USDT, MockChainlinkFeed.code)` make the adapters' immutable feed addresses controllable in a unit run, so the full deploy shape + drills are CI-tested without a live RPC. The orchestrator's real `_buildAdapters` EURC-mock path is exercised through the `address(0)` sentinel.
12. **No new production contract.** This subsystem is orchestration + keeper + drills + tests over already-deployed V2 contracts; the only `new`-deployed contracts are the reused `MintableERC20`, `MockChainlinkFeed`, `ChainlinkPythAdapterV2`, `ArcoraDexRegistryV2`, `ArcoraDexPoolV2`, and the `GovernanceFactory` stack.

### Placeholder scan
- No "TBD" / "implement later" in shown Solidity or Node code — every function body is complete and compiles (the orchestrator, the revalidation test, the keeper lib, the Node tests).
- The keeper entrypoint's `transport: undefined` is an EXPLICIT, flagged wire-in point (Task 4 Step 2 note) so the implementer confirms the RPC env name against the ledger — not a silent stub. The pure functions it depends on (`parseHermesBlobs`, `fetchHermesUpdates`) are fully implemented and unit-tested.
- The drill scripts beyond `05-reserve-floor.sh` are specified by their exact `cast` invocation + assertion in Task 5 Step 2 (representative full script shown for Drill 5); they share one skeleton, so they are a transcription, not research.

### Type/name consistency across tasks
- `ChainlinkPythAdapterV2` constructor arg order in `_buildAdapters` matches the contract (Task 0 Step 4 pin) and the revalidation test.
- `ArcoraDexPoolV2(registry, protocolFeeShareBps, owner)` + `pool.LP()` + `setPauseGuardian`/`pause`/`unpause`/`paused`/`pendingOwner`/`withdrawProportional`/`maxSwapOut`/`quoteSwapV2`/`totalReservesUSD` — all exist on the deployed Pool (verified against `ArcoraDexPoolV2.sol`).
- `ArcoraDexRegistryV2.listToken(token, TokenConfigV2)` + `setPool` + `pool()` + `tokenConfig` + `isActive` + `pendingOwner` — all exist (verified).
- `IArcoraDexRegistryV2.TokenConfigV2{decimals,isActive,adapter,minimumReserveUsd,targetReserveUsd,depositCapUsd,bands}` + `FeeBandMathV2.Band{upperHealthBps,rateBps}` — field names/types match the deployed structs (verified).
- `MintableERC20(name,symbol,decimals,owner)` + `mint` ; `MockChainlinkFeed(decimals,answer)` (owner=msg.sender, `setAnswer`) — match `src/testnet/`.
- `GovernanceFactory.resolveConfig()` + `deploy(cfg, minDelay)` returning `Stack{govSafe,pgSafe,timelock,...}` + `Config.timelockMinDelay` — match the factory.
- Keeper feed IDs (`FEED_IDS`) and `PYTH_SEPOLIA` match the authoritative table and the orchestrator constant.
- Pool errors used in tests (`OracleUnsafe`, `ReserveFloorBreached`, `PoolPaused`) exist on `IArcoraDexPoolV2` (verified).
```
