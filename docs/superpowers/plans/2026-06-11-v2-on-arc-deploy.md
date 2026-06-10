# ArcoraDEX V2 on Arc Testnet (chainId 5042002) with MOCK Oracles — Deployment Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replicate the proven Base Sepolia V2 deploy on **Arc testnet (chainId 5042002)** using MOCK oracle sources, so the existing V2 UI runs on Arc identically to Base Sepolia. Arc has NO Pyth and NO real Chainlink, so the dual-source `ChainlinkPythAdapterV2` cannot be wired to live feeds. This plan introduces ONE small deployable, keeper-settable mock adapter (`MockOracleAdapterV2Settable`, implementing `IOracleAdapterV2`) under `contracts/src/v2/testnet/`, deploys it once per token, and wires the RegistryV2 to it. It delivers ONE turnkey `DeployArcV2.s.sol` that, in a single broadcast, chainid-guards **5042002**, deploys 3 fresh `MintableERC20` test stables (USDC/USDT/EURC, 6-dec), deploys a FRESH governance stack via the chain-agnostic `GovernanceFactory` (Gov Safe 3/5 + PG Safe 2/3 + 48h Timelock; `GOV_USE_TEST_MNEMONIC=true` opt-in allowed on this testnet), deploys 3 `MockOracleAdapterV2Settable` adapters seeded at peg, deploys `ArcoraDexRegistryV2` and lists all 3 tokens with the §7 default 4-band schedule + conservative low rollout caps (§13-step-5), deploys the immutable `ArcoraDexPoolV2`, wires `setPool` + `setPauseGuardian(PG Safe)`, bootstraps seed deposits (oracles already safe at deploy — no Pyth pull needed), hands ownership off (Registry/Pool transferOwnership -> Timelock pending; adapters transferOwnership -> Gov Safe pending; the adapter `writer` stays the keeper EOA), asserts deployed-state invariants, and emits an address ledger. Plus: an Arc V2 keeper (`ops/arckeeper/`) that pushes a fresh safe price per token (`setPrice(token, price1e18, true)`) so the adapters keep reading `safe`, reusing the `ops/keepalive/lib.mjs` gas/nonce/timeout hardening; and a fork-mode revalidation test (`DeployArcV2.t.sol`) that INHERITS the orchestrator and drives its OWN `_cfg()`/`_buildAdapters`/`_listAndSeed`/`_summary` end-to-end, asserting the §13/§15 deployed-state invariants and a config drift guard.

**Architecture:** `DeployArcV2.s.sol` mirrors the house style of `DeployBaseSepoliaV2.s.sol` and `DeployPublicTestnet.s.sol` EXACTLY: a single `run()` that broadcasts the full validated sequence, chaining every freshly-deployed address through an IN-PROCESS `Deployed` ledger struct (no log scraping); a pure `internal` per-token `_cfg()` source of truth (the drift-guard + revalidation test bind to it); a `GovernanceFactory`-driven FRESH governance mode (test-mnemonic opt-in permitted because 5042002 is a testnet, the factory's mainnet guard intact); post-deploy `require` invariant asserts in `_summary`; and an `_emitLedger`. The ONLY new production-side contract is `MockOracleAdapterV2Settable` (`contracts/src/v2/testnet/`), a deployable, role-separated (owner = admin / writer = keeper) `IOracleAdapterV2` whose `(price1e18, safe)` is keeper-settable per token — it is the Arc analogue of `MockChainlinkFeedV2` (already in `src/testnet/`). PoolV2/RegistryV2/LPV2/FeeBandMathV2 are UNCHANGED (audited + live on Base). The §9 UI (reserveHealth / quotes / maxSwapOut) derives entirely from the Pool, which reads only `(price1e18, safe)` from the adapter — so a settable mock adapter that returns safe peg prices keeps the full §9 UI functional and identical to Base. The keeper is a standalone Node script (`ops/arckeeper/push-prices-arc.mjs`) reusing `ops/keepalive/lib.mjs` for the transport/gas-ceiling/nonce hardening; it pushes a fresh `setPrice` per token on a timer so `peekPrice(token).safe == true` stays current (the adapter has no intrinsic staleness, but the keeper refreshes the on-chain price + timestamp for parity and so the operator can drive failure drills by stopping it).

**Tech Stack:** Solidity `^0.8.26`, Foundry (`forge build` / `forge test` / `forge fmt` / `forge script`), OpenZeppelin v5 (`Ownable`, `Ownable2Step`, `TimelockController`), `@safe-global/safe-contracts` (via `GovernanceFactory`), forge-std (`Script`, `Test`, `console2`). Keeper: Node 20 + `viem`, reusing `ops/keepalive/lib.mjs`. Reuses in-repo `ArcoraDexRegistryV2`, `ArcoraDexPoolV2`, `ArcoraDexLPV2`, `FeeBandMathV2`, `MintableERC20`, `IOracleAdapterV2`, `GovernanceFactory`. One new contract: `src/v2/testnet/MockOracleAdapterV2Settable.sol` (+ its unit test). No core V2 contract is edited.

**Out of scope (other plans / explicit):**
- SDK multi-chain wiring (`packages/sdk/src/chains/arcTestnet.ts` + `addresses.v2.ts` for Arc) and the app chain switcher — the NEXT plan. This plan only emits the address ledger the next plan consumes.
- Base mainnet (and Arc mainnet — Arc is testnet-only).
- The real dual-source `ChainlinkPythAdapterV2` on Arc (Arc has neither feed source; deliberately NOT used here).
- Monitoring / alerting infrastructure (§12 beyond the keeper's safe-price refresh).
- The §13 drill runbook + drill scripts (Base Sepolia already has those; the Arc mock-adapter failure modes are covered by `DeployArcV2.t.sol` unit drills, not a separate ops runbook).

---

## File Structure

| File | Responsibility (one each) |
|------|---------------------------|
| `contracts/src/v2/testnet/MockOracleAdapterV2Settable.sol` | Deployable, role-separated (`owner`=admin via `Ownable2Step`, `writer`=keeper) `IOracleAdapterV2`. Keeper-settable `(price1e18, safe)` per token via `setPrice`; `readPrice`/`peekPrice` return it. The Arc mock-oracle source. |
| `contracts/test/v2/MockOracleAdapterV2Settable.t.sol` | Unit tests for the new contract: writer-gating, owner/writer separation, `setPrice`/`setSafe`/`peekPrice`==`readPrice`, `setWriter`, the `IOracleAdapterV2` surface, ownership 2-step. |
| `contracts/script/DeployArcV2.s.sol` | The turnkey Arc orchestrator: chainid-guard 5042002; `_cfg()` per-token source of truth; deploy 3 fresh test tokens -> fresh governance -> 3 `MockOracleAdapterV2Settable` (seeded at peg, writer=keeper) -> RegistryV2 (list 3 with §7 bands + low caps) -> PoolV2 -> setPool + setPauseGuardian -> bootstrap -> handoffs -> `_summary` invariant asserts -> `_emitLedger`. |
| `contracts/test/DeployArcV2.t.sol` | Fork-mode revalidation + gap-test coupling: INHERITS the orchestrator, drives its REAL `_cfg()`/`_defaultBands()`/`_buildAdapters`/`_deployRegistryAndList`/`_summary` on a simulated 5042002; asserts the §13/§15 deployed-state invariants, the config drift guard, and the mock-adapter failure drills (oracle-unsafe, reserve-floor, proportional-exit-while-paused, pause authority). |
| `ops/arckeeper/lib.mjs` | Thin Arc-V2 keeper helpers (chain def 5042002, adapter ABI, peg map) — kept separate so `ops/keepalive/lib.mjs` (the V1 Arc feeds keeper) is untouched. |
| `ops/arckeeper/push-prices-arc.mjs` | The Arc V2 keeper: pushes a fresh `setPrice(token, price1e18, true)` per token so each adapter reads `safe`; reuses `ops/keepalive/lib.mjs` transport/gas/nonce hardening. |
| `ops/arckeeper/test/push-prices.test.mjs` | Node unit test for the pure price-shaping helpers (peg -> 1e18, env -> adapter map). |
| `docs/runbooks/2026-06-11-arc-v2-deploy.md` | The Arc V2 deploy runbook: env, pre-flight, the single `forge script` invocation, ledger capture, keeper start (systemd-or-loop), and post-deploy governance-accept steps. |
| `docs/superpowers/plans/2026-06-11-v2-on-arc-deploy.md` | This plan. |

All new Solidity lives under `contracts/src/v2/testnet/`, `contracts/script/`, and `contracts/test/`. The ONLY core-contract touch is reading them — none are edited. The keeper + runbook are net-new directories (`ops/arckeeper/`, no collision with the Base Sepolia `ops/basekeeper/` or the V1 Arc `ops/keepalive/`). The existing 288-test suite (291 total, 3 skipped) must stay green throughout.

---

## ORACLE-OPTION DECISION (the crux — resolved)

**Decision: Option 2 — a deployable, keeper-settable `MockOracleAdapterV2Settable` implementing `IOracleAdapterV2` directly.** One contract per token; the keeper calls `setPrice(token, price1e18, true)`; the Pool reads `(price1e18, safe)` exactly as it reads the real `ChainlinkPythAdapterV2`.

**Justification (Option 2 over Option 1):**
1. **Constructor constraint kills the "minimal" Option-1.** `ChainlinkPythAdapterV2`'s constructor reverts `ZeroAddress` unless BOTH `chainlinkFeed != address(0)` AND `pyth != address(0)`, and it CALLS `chainlinkFeed_.decimals()` in the constructor (line 92). So Option 1 cannot just "pass zeros" — it forces deploying a real `MockChainlinkFeed` (or `MockChainlinkFeedV2`) AND a deployable `MockPyth` per token, then a keeper that pushes BOTH legs (`setAnswer` + `updatePriceFeeds`) AND keeps them within `maxDivergenceBps` and both within their staleness windows. That is 3 contracts/token + a 2-leg keeper that must avoid tripping the adapter's own divergence/staleness/confidence logic — significant surface for a testnet PARITY pool that gains nothing from exercising real dual-source internals.
2. **`MockPyth` is test-only and would have to be promoted.** `MockPyth` lives in `contracts/test/v2/mocks/MockPyth.sol` (not deployable from a `forge script`). Option 1 requires moving/copying a deployable variant into `src/`. Option 2 needs no Pyth at all.
3. **Option 2 keeps the §9 UI fully functional — which is the whole point.** `reserveHealth` / `quoteSwapV2` / `maxSwapOut` / `totalReservesUSD` all derive from the Pool's reserves + the adapter's `(price1e18, safe)` tuple — NOT from any oracle internals. A settable adapter returning safe peg prices makes every §9 surface behave identically to Base Sepolia, and lets the operator drive the §11 oracle-failure path deterministically (`setSafe(token, false)`) for the unit drills.
4. **It mirrors an existing in-repo precedent.** `src/testnet/MockChainlinkFeedV2.sol` is already a deployable, role-separated (owner/writer) testnet feed used by `DeployPublicTestnet`. `MockOracleAdapterV2Settable` is the exact V2-adapter analogue, with the same owner=admin / writer=keeper split (so the keeper EOA can push without the Gov-Safe-owned admin key). The test-only `test/v2/mocks/MockOracleAdapterV2.sol` (ungated `setPrice`) is the shape; the new contract adds the writer gate + `Ownable2Step` so it is safe to own with governance.
5. **Acceptable trade-off, explicitly.** Option 2 bypasses the real adapter's dual-source/staleness/divergence/confidence logic. That logic is AUDITED and LIVE on Base Sepolia (covered by `ChainlinkPythAdapterV2`'s own suite + the Base Sepolia deploy plan) — re-exercising it on a chain with no real feeds adds risk, not coverage. For an Arc TESTNET parity pool the requirement is "the V2 UI works identically", which Option 2 satisfies with one small, auditable contract.

---

## TOKENS DECISION (fresh vs reuse — resolved)

**Decision: FRESH `MintableERC20` test tokens (USDC/USDT/EURC, all 6-dec), deployed in-process — do NOT reuse Arc's canonical USDC.**

**Justification:** Arc's native gas token IS USDC, and the canonical ERC-20 USDC lives at the fixed precompile-style address `0x3600000000000000000000000000000000000000` (6-dec). Using the canonical USDC as a POOL token would (a) couple the pool's seed/faucet to the operator's real testnet USDC balance (which is also the gas balance — mixing the two is the documented Arc footgun), and (b) make USDC un-faucetable through the app's existing `MintableERC20`-based faucet (the canonical token is not owner-mintable by us). Fresh `MintableERC20` USDC/USDT/EURC exactly mirror the Base Sepolia V2 deploy (3 fresh 6-dec stables), keep the faucet working, and keep the pool's economics independent of gas. This is the same choice `DeployBaseSepoliaV2` made and the parity requirement demands it. (Native USDC is still used for GAS — the deployer/keeper just need a little testnet USDC from https://faucet.circle.com.)

---

### Task 0: Branch + baseline + Arc input pins

**Files:** none modified; verification only.

- [ ] **Step 1: Create the deploy branch**

Run:
```bash
cd /Users/huseyinarslan/Desktop/arcoradex/arcoradex && git checkout -b feat/v2-on-arc && git log --oneline -1
```
Expected: a clean branch at the current tip. (If a base branch other than the current HEAD is required, branch from it and record which.)

- [ ] **Step 2: Establish the baseline (must stay green)**

Run:
```bash
cd contracts && forge build && forge test 2>&1 | tail -3
```
Expected: `Compiler run successful`, then `288 tests passed, 0 failed, 3 skipped (291 total tests)`. Record `288` as the actual baseline. New tests in this plan add to it.

- [ ] **Step 3: Pin the authoritative Arc config (the source of truth `_cfg()` transcribes)**

No code in this step — confirm these exact values before Task 2 encodes them:
```text
Arc Testnet:
  chainId            5042002   (hex 0x4CEF52)
  RPC                https://rpc.testnet.arc.network
  Explorer           https://testnet.arcscan.app
  Native gas         USDC (18-dec native units); canonical ERC-20 USDC 0x3600...0000 (6-dec) — NOT used as a pool token
Pool tokens (FRESH MintableERC20, 6-dec, in-process):
  USDC   peg $1.00   -> price1e18 = 1_000000000000000000
  USDT   peg $1.00   -> price1e18 = 1_000000000000000000
  EURC   peg $1.15   -> price1e18 = 1_150000000000000000
§7 default 4-band schedule (identical to V2Fixture._defaultBands / the Base Sepolia plan):
  band[0] upperHealthBps 10000 rateBps 5     (75-100%: 0.05%)
  band[1] upperHealthBps  7500 rateBps 20    (50-75% : 0.20%)
  band[2] upperHealthBps  5000 rateBps 75    (25-50% : 0.75%)
  band[3] upperHealthBps  2500 rateBps 300   (0-25%  : 3.00%)
Per-token §7 reserve floors + §13-step-5 caps (mirror Base Sepolia):
  minReserveUsd 1_000e18 ; targetReserveUsd 5_000e18 ; depositCapUsd 10_000e18 (conservative)
Seeds (token-native, < cap): USDC 1_000_000_000 ; USDT 1_000_000_000 ; EURC 870_000_000 (~$1000 at $1.15)
Pool protocol-fee share: PROTOCOL_FEE_SHARE_BPS = 1000 (10% protocol / 90% LP; <= MAX 2500)
```
The drift guard (Task 3) and the revalidation test bind to these exact values — do not let them drift.

- [ ] **Step 4: Confirm the consumed contract surfaces (no surprises at deploy time)**

Run:
```bash
cd contracts && grep -n "constructor\|function listToken\|function setPool\|function setPauseGuardian\|function deposit" \
  src/v2/ArcoraDexPoolV2.sol src/v2/ArcoraDexRegistryV2.sol src/testnet/MintableERC20.sol src/v2/interfaces/IArcoraDexRegistryV2.sol | head -20
```
Expected (the EXACT surfaces the orchestrator calls — verify before writing Task 2):
```text
ArcoraDexPoolV2:    constructor(address registry, uint16 initialProtocolFeeShareBps, address initialOwner)
ArcoraDexRegistryV2: constructor(address initialOwner)
ArcoraDexRegistryV2: listToken(address token, TokenConfigV2 calldata config)  // struct-arg listing
ArcoraDexRegistryV2: setPool(address pool_)
ArcoraDexPoolV2:    setPauseGuardian(address newGuardian)
ArcoraDexPoolV2:    deposit(address token, uint256 amount, uint256 minLpOut, uint256 deadline)
MintableERC20:      constructor(string name_, string symbol_, uint8 decimals_, address initialOwner)
IArcoraDexRegistryV2.TokenConfigV2{decimals,isActive,adapter,minimumReserveUsd,targetReserveUsd,depositCapUsd,bands}
```
If any signature differs, STOP and reconcile — the orchestrator is a transcription of these, not a guess.

---

### Task 1: `MockOracleAdapterV2Settable` — the deployable Arc mock adapter (TDD)

The ONE new production-side contract. Deployable, role-separated, keeper-settable. Owner (admin, `Ownable2Step`) is handed to the Gov Safe; `writer` (the keeper EOA) pushes `setPrice`. `readPrice`/`peekPrice` return the stored `(price1e18, safe)`. Write the failing test FIRST.

**Files:**
- Create `contracts/test/v2/MockOracleAdapterV2Settable.t.sol`
- Create `contracts/src/v2/testnet/MockOracleAdapterV2Settable.sol`

- [ ] **Step 1: Write the failing unit test**

Create `contracts/test/v2/MockOracleAdapterV2Settable.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockOracleAdapterV2Settable} from "../../src/v2/testnet/MockOracleAdapterV2Settable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockOracleAdapterV2SettableTest is Test {
    MockOracleAdapterV2Settable internal adapter;
    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal token = makeAddr("token");

    function setUp() public {
        // owner=admin, writer=keeper
        adapter = new MockOracleAdapterV2Settable(admin, keeper);
    }

    function test_constructor_sets_owner_and_writer() public view {
        assertEq(adapter.owner(), admin, "owner");
        assertEq(adapter.writer(), keeper, "writer");
    }

    function test_constructor_rejects_zero_writer() public {
        vm.expectRevert(MockOracleAdapterV2Settable.ZeroAddress.selector);
        new MockOracleAdapterV2Settable(admin, address(0));
    }

    function test_writer_can_setPrice_and_peek_equals_read() public {
        vm.prank(keeper);
        adapter.setPrice(token, 1e18, true);
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertEq(p, 1e18, "peek price");
        assertTrue(safe, "peek safe");
        (uint256 pr, bool sr) = adapter.readPrice(token);
        assertEq(pr, p, "read==peek price");
        assertEq(sr, safe, "read==peek safe");
    }

    function test_nonwriter_cannot_setPrice() public {
        vm.prank(stranger);
        vm.expectRevert(MockOracleAdapterV2Settable.NotWriter.selector);
        adapter.setPrice(token, 1e18, true);
    }

    function test_writer_can_flip_safe_for_drills() public {
        vm.prank(keeper);
        adapter.setPrice(token, 115e16, true);
        vm.prank(keeper);
        adapter.setSafe(token, false);
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertEq(p, 115e16, "price retained when flipped unsafe");
        assertFalse(safe, "flipped unsafe");
    }

    function test_owner_can_rotate_writer() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(admin);
        adapter.setWriter(newKeeper);
        assertEq(adapter.writer(), newKeeper, "rotated writer");
        // old keeper is now rejected
        vm.prank(keeper);
        vm.expectRevert(MockOracleAdapterV2Settable.NotWriter.selector);
        adapter.setPrice(token, 1e18, true);
    }

    function test_nonowner_cannot_setWriter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.setWriter(stranger);
    }

    function test_unset_token_reads_zero_and_unsafe() public view {
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertEq(p, 0, "unset price 0");
        assertFalse(safe, "unset unsafe");
    }

    function test_ownership_is_two_step() public {
        address gov = makeAddr("gov");
        vm.prank(admin);
        adapter.transferOwnership(gov);
        assertEq(adapter.owner(), admin, "still admin until accept");
        assertEq(adapter.pendingOwner(), gov, "pending gov");
        vm.prank(gov);
        adapter.acceptOwnership();
        assertEq(adapter.owner(), gov, "gov now owner");
    }
}
```

- [ ] **Step 2: Run the test (expect FAIL — contract does not exist yet)**

Run:
```bash
cd contracts && forge test --match-path "test/v2/MockOracleAdapterV2Settable.t.sol" 2>&1 | tail -10
```
Expected: a COMPILE error (`MockOracleAdapterV2Settable` not found) — the RED state of TDD.

- [ ] **Step 3: Write the contract to pass**

Create `contracts/src/v2/testnet/MockOracleAdapterV2Settable.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IOracleAdapterV2} from "../interfaces/IOracleAdapterV2.sol";

/// @title MockOracleAdapterV2Settable
/// @notice TESTNET-ONLY deployable IOracleAdapterV2 for chains with NO Pyth and NO
/// real Chainlink (Arc testnet, chainId 5042002). The Pool consumes only the
/// (price1e18, safe) tuple this returns, so a keeper-settable mock keeps the full
/// §9 UI (reserveHealth / quotes / maxSwapOut) functional and lets an operator
/// drive the §11 oracle-failure path deterministically by flipping `safe`.
///
/// ROLE SEPARATION (mirrors src/testnet/MockChainlinkFeedV2):
///   - owner (Ownable2Step admin): rotates the writer; handed to the Gov Safe at deploy.
///   - writer (the keeper EOA): pushes setPrice/setSafe; never the admin key.
///
/// NOT for mainnet. The real dual-source ChainlinkPythAdapterV2 is used wherever
/// both a Chainlink-style aggregator and a Pyth contract exist (e.g. Base).
contract MockOracleAdapterV2Settable is IOracleAdapterV2, Ownable2Step {
    address public writer;
    mapping(address token => uint256 price1e18) public price1e18Of;
    mapping(address token => bool safe) public safeOf;
    mapping(address token => uint256 ts) public updatedAtOf;

    error NotWriter();
    error ZeroAddress();

    event WriterUpdated(address indexed prev, address indexed next);
    event PricePushed(address indexed token, uint256 price1e18, bool safe, uint256 updatedAt);

    modifier onlyWriter() {
        if (msg.sender != writer) revert NotWriter();
        _;
    }

    constructor(address initialOwner, address initialWriter) Ownable(initialOwner) {
        if (initialWriter == address(0)) revert ZeroAddress();
        writer = initialWriter;
        emit WriterUpdated(address(0), initialWriter);
    }

    /// @notice Admin rotates the keeper-writer (e.g. on a key ceremony).
    function setWriter(address newWriter) external onlyOwner {
        if (newWriter == address(0)) revert ZeroAddress();
        emit WriterUpdated(writer, newWriter);
        writer = newWriter;
    }

    /// @notice Keeper pushes the full (price1e18, safe) tuple for a token.
    function setPrice(address token, uint256 price1e18, bool safe) external onlyWriter {
        price1e18Of[token] = price1e18;
        safeOf[token] = safe;
        updatedAtOf[token] = block.timestamp;
        emit PricePushed(token, price1e18, safe, block.timestamp);
    }

    /// @notice Keeper/drill flips ONLY the safe flag (retains last price for display).
    function setSafe(address token, bool safe) external onlyWriter {
        safeOf[token] = safe;
        emit PricePushed(token, price1e18Of[token], safe, block.timestamp);
    }

    /// @inheritdoc IOracleAdapterV2
    function readPrice(address token) external view override returns (uint256 price1e18, bool safe) {
        return (price1e18Of[token], safeOf[token]);
    }

    /// @inheritdoc IOracleAdapterV2
    function peekPrice(address token) external view override returns (uint256 price1e18, bool safe) {
        return (price1e18Of[token], safeOf[token]);
    }
}
```
Note: `IOracleAdapterV2.readPrice` is declared NON-view in the interface (real adapters may refresh a cache), but Solidity permits a `view` override of a non-view interface function (view is a strict-subset state mutability — allowed). If `forge build` rejects it on your toolchain, drop the `view` keyword from `readPrice` (keep the body); the test only reads it, so non-view compiles + runs the same.

- [ ] **Step 4: Run the test (expect GREEN)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/MockOracleAdapterV2Settable.t.sol" 2>&1 | tail -12
```
Expected: all tests pass, `0 failed`. If `test_ownership_is_two_step` fails, confirm `Ownable2Step` is inherited (not plain `Ownable`). If the `view`-override line errors, apply the Step 3 note (drop `view` on `readPrice`).

- [ ] **Step 5: Commit**

Run:
```bash
git add contracts/src/v2/testnet/MockOracleAdapterV2Settable.sol contracts/test/v2/MockOracleAdapterV2Settable.t.sol
git commit -m "feat(v2): deployable keeper-settable MockOracleAdapterV2Settable for Arc testnet

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `DeployArcV2.s.sol` — the turnkey orchestrator (chainid 5042002)

The core deliverable. Mirrors `DeployBaseSepoliaV2.s.sol` / `DeployPublicTestnet.s.sol`: chainid guard, in-process `Deployed` ledger, pure `_cfg()` source of truth, `_summary` invariant asserts, `_emitLedger`. The Arc-specific simplification: the mock adapters are seeded SAFE at deploy, so bootstrap never needs a pre-deploy oracle pull (unlike the Pyth path).

**Design encoded here (read before writing):**

Constants:
- `CHAIN_ID = 5042002`.
- `PROTOCOL_FEE_SHARE_BPS = 1000` (10% protocol / 90% LP).

Per-token config (`_cfg()`, `internal pure`, 3 entries — the drift guard binds to it): `symbol`, `name`, `decimals` (6), `pegPrice1e18`, `minReserveUsd`, `targetReserveUsd`, `depositCapUsd`, `seedAmount`.

In-process `Deployed` ledger: `registry`, `pool`, `lp`, `address[3] token`, `address[3] adapter`, `govSafe`, `timelock` (payable), `pgSafe`, `bool freshGovernance`.

Sequence in `run()` (single broadcast):
0. chainid guard 5042002.
1. Governance: `GovernanceFactory.resolveConfig()` + `deploy(cfg, cfg.timelockMinDelay)` (FRESH). `GOV_USE_TEST_MNEMONIC=true` allowed on 5042002 (factory's mainnet guard intact). Record `govSafe`, `timelock`, `pgSafe`; assert proposer/executor roles.
2. Tokens: deploy 3 `MintableERC20` (USDC/USDT/EURC, 6-dec); mint each `seedAmount * 2` to the deployer (seed + faucet headroom).
3. Adapters: for each token deploy `new MockOracleAdapterV2Settable(deployer, keeper)` (owner=deployer until handoff; writer=keeper EOA), then `adapter.setPrice(token, pegPrice1e18, true)` so it is SAFE at deploy. (The deployer is NOT the writer here — so the script must set the writer to the DEPLOYER for the seeding call, then to the real keeper. Cleaner: construct with writer=deployer, seed, then `setWriter(keeper)`. Encoded below.)
4. Registry: `new ArcoraDexRegistryV2(deployer)`; list each token with `TokenConfigV2{decimals, isActive:true, adapter, minimumReserveUsd, targetReserveUsd, depositCapUsd, bands:_defaultBands()}`.
5. Pool: `new ArcoraDexPoolV2(address(registry), PROTOCOL_FEE_SHARE_BPS, deployer)`; `lp = ArcoraDexLPV2(address(pool.LP()))`; `registry.setPool(address(pool))` (I-1); `pool.setPauseGuardian(pgSafe)` (§6.2).
6. Bootstrap: approve + `pool.deposit(token, seedAmount, 0, block.timestamp + 1 days)` per token. Oracles are SAFE by construction (step 3), so all 3 seed — but keep the seed-robust skip-on-unsafe guard for parity + safety.
7. Handoffs: adapters `transferOwnership(govSafe)` (admin -> Gov Safe; writer stays the keeper EOA); Registry/Pool `transferOwnership(timelock)`.
8. `_summary` invariant asserts; 9. `_emitLedger`.

**Files:**
- Create `contracts/script/DeployArcV2.s.sol`

- [ ] **Step 1: Write the orchestrator**

Create `contracts/script/DeployArcV2.s.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArcoraDexRegistryV2} from "../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexPoolV2} from "../src/v2/ArcoraDexPoolV2.sol";
import {ArcoraDexLPV2} from "../src/v2/ArcoraDexLPV2.sol";
import {IArcoraDexRegistryV2} from "../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "../src/v2/interfaces/IOracleAdapterV2.sol";
import {FeeBandMathV2} from "../src/v2/lib/FeeBandMathV2.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
import {MockOracleAdapterV2Settable} from "../src/v2/testnet/MockOracleAdapterV2Settable.sol";
import {GovernanceFactory} from "./GovernanceFactory.sol";

/// @title DeployArcV2 — turnkey Arc testnet V2 deploy with MOCK oracles
/// @notice Single-broadcast orchestrator for the FRESH ArcoraDEX V2 stack on Arc
/// testnet (chainId 5042002). Arc has NO Pyth and NO real Chainlink, so each token
/// is priced by a deployable keeper-settable MockOracleAdapterV2Settable (seeded at
/// peg, SAFE). Mirrors the proven house style of DeployBaseSepoliaV2/DeployPublicTestnet:
/// pure `_cfg()` source of truth, in-process ledger, `_summary` invariant asserts,
/// `_emitLedger`. The §9 UI is identical to Base because the Pool reads only the
/// (price1e18, safe) tuple from the adapter.
///
/// SEQUENCE:
///   0. chainid guard 5042002
///   1. FRESH governance (GovernanceFactory): Gov Safe 3/5 + PG Safe 2/3 + 48h Timelock.
///      GOV_USE_TEST_MNEMONIC=true ALLOWED on this testnet (factory's mainnet guard intact).
///   2. 3 fresh MintableERC20 test stables (USDC/USDT/EURC, 6-dec); mint seed+faucet headroom.
///   3. 3 MockOracleAdapterV2Settable (writer=deployer to seed, then setWriter(keeper)); seeded SAFE at peg.
///   4. RegistryV2 + list 3 tokens (§7 default bands; conservative low §13-step-5 depositCapUsd).
///   5. Immutable PoolV2 (+ auto-LP) + setPool (I-1) + setPauseGuardian(PG Safe).
///   6. Bootstrap seed deposits (oracles safe by construction; seed-robust skip retained).
///   7. Handoffs: adapters admin -> Gov Safe (pending; writer stays keeper EOA); Registry/Pool -> Timelock (pending).
///   8. Invariant asserts; 9. address-ledger emit.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY — broadcasts; mints + seeds; initial owner/writer before handoff
///   KEEPER_EOA           — the price-pusher address (becomes each adapter's writer)
/// Governance env (FRESH; recommended):
///   GOV_SAFE_OWNERS / GOV_SAFE_THRESHOLD / PG_SAFE_OWNERS / PG_SAFE_THRESHOLD / TIMELOCK_MIN_DELAY
///   (testnet opt-in: GOV_USE_TEST_MNEMONIC=true derives owners from the public Foundry mnemonic)
contract DeployArcV2 is Script {
    uint256 internal constant CHAIN_ID = 5042002;
    uint16 internal constant PROTOCOL_FEE_SHARE_BPS = 1_000; // 10% protocol / 90% LP

    /// @dev Per-token Arc config — the SINGLE source of truth the drift guard +
    /// revalidation test bind to. Fresh 6-dec MintableERC20s priced at peg by the
    /// keeper-settable mock adapter.
    struct TokenCfg {
        string symbol;
        string name;
        uint8 decimals;
        uint256 pegPrice1e18; // 1e18-scaled USD peg the adapter is seeded at
        uint256 minReserveUsd; // 1e18
        uint256 targetReserveUsd; // 1e18
        uint256 depositCapUsd; // 1e18 (conservative §13-step-5 cap)
        uint256 seedAmount; // token-native bootstrap (< cap)
    }

    function _cfg() internal pure returns (TokenCfg[3] memory c) {
        c[0] = TokenCfg({
            symbol: "USDC",
            name: "USD Coin",
            decimals: 6,
            pegPrice1e18: 1e18,
            minReserveUsd: 1_000e18,
            targetReserveUsd: 5_000e18,
            depositCapUsd: 10_000e18,
            seedAmount: 1_000_000_000 // 1,000 USDC (6-dec)
        });
        c[1] = TokenCfg({
            symbol: "USDT",
            name: "Tether USD",
            decimals: 6,
            pegPrice1e18: 1e18,
            minReserveUsd: 1_000e18,
            targetReserveUsd: 5_000e18,
            depositCapUsd: 10_000e18,
            seedAmount: 1_000_000_000 // 1,000 USDT
        });
        c[2] = TokenCfg({
            symbol: "EURC",
            name: "Euro Coin",
            decimals: 6,
            pegPrice1e18: 115e16, // $1.15
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
        address govSafe;
        address payable timelock;
        address pgSafe;
        bool freshGovernance;
    }

    function run() external {
        require(block.chainid == CHAIN_ID, "DeployArcV2: Arc testnet (5042002) only");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address keeper = vm.envAddress("KEEPER_EOA");
        require(keeper != address(0), "KEEPER_EOA is zero");

        TokenCfg[3] memory cfg = _cfg();
        Deployed memory d;

        console2.log("=== ArcoraDEX V2 Arc testnet turnkey deploy (MOCK oracles) ===");
        console2.log("Deployer:", deployer);
        console2.log("Keeper:  ", keeper);
        console2.log("");

        vm.startBroadcast(deployerKey);

        _deployGovernance(d);
        _deployTokens(d, cfg, deployer);
        _buildAdapters(d, cfg, deployer, keeper);
        _deployRegistryAndList(d, cfg, deployer);
        _deployPool(d, deployer);
        _bootstrap(d, cfg, deployer);
        _handoff(d);

        vm.stopBroadcast();

        _summary(d, cfg);
        _emitLedger(d, cfg);
    }

    // -- Step 1: governance --------------------------------------------------
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

    // -- Step 2: tokens ------------------------------------------------------
    function _deployTokens(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        console2.log("--- Test tokens (fresh MintableERC20) ---");
        for (uint256 i = 0; i < 3; i++) {
            MintableERC20 t = new MintableERC20(cfg[i].name, cfg[i].symbol, cfg[i].decimals, deployer);
            t.mint(deployer, cfg[i].seedAmount * 2); // seed + faucet headroom
            d.token[i] = address(t);
            console2.log(string.concat("  ", cfg[i].symbol, ":"), address(t));
        }
        console2.log("");
    }

    // -- Step 3: adapters (seeded SAFE at peg; writer = keeper after seeding) -
    function _buildAdapters(Deployed memory d, TokenCfg[3] memory cfg, address deployer, address keeper) internal {
        console2.log("--- Mock oracle adapters (seeded SAFE at peg) ---");
        for (uint256 i = 0; i < 3; i++) {
            // writer=deployer so the deploy can seed the peg; rotated to the keeper below.
            MockOracleAdapterV2Settable a = new MockOracleAdapterV2Settable(deployer, deployer);
            a.setPrice(d.token[i], cfg[i].pegPrice1e18, true); // SAFE at peg
            a.setWriter(keeper); // hand the writer role to the keeper EOA
            // N-6: post-deploy verification.
            (uint256 p, bool safe) = a.peekPrice(d.token[i]);
            require(p == cfg[i].pegPrice1e18 && safe, "adapter not seeded safe at peg");
            require(a.writer() == keeper, "adapter writer != keeper");
            d.adapter[i] = address(a);
            console2.log(string.concat("  ", cfg[i].symbol, " adapter:"), address(a));
        }
        console2.log("");
    }

    // -- Step 4: registry + list ---------------------------------------------
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

    // -- Step 5: pool + setPool + guardian ------------------------------------
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

    // -- Step 6: bootstrap (oracles safe by construction; skip-guard retained) -
    function _bootstrap(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        console2.log("--- Bootstrap deposits ---");
        for (uint256 i = 0; i < 3; i++) {
            (, bool safe) = MockOracleAdapterV2Settable(d.adapter[i]).peekPrice(d.token[i]);
            if (!safe) {
                console2.log(string.concat("  SKIP ", cfg[i].symbol, " (oracle unsafe)"));
                continue;
            }
            IERC20(d.token[i]).approve(address(d.pool), cfg[i].seedAmount);
            uint256 lpOut = d.pool.deposit(d.token[i], cfg[i].seedAmount, 0, block.timestamp + 1 days);
            console2.log(string.concat("  Deposited ", cfg[i].symbol), cfg[i].seedAmount);
            console2.log("    LP minted:", lpOut);
        }
        console2.log("");
    }

    // -- Step 7: ownership handoffs (clean pending state) ---------------------
    function _handoff(Deployed memory d) internal {
        console2.log("--- Handoffs ---");
        for (uint256 i = 0; i < 3; i++) {
            // Adapter admin -> Gov Safe (the §10 retune authority). Writer stays the keeper EOA.
            MockOracleAdapterV2Settable(d.adapter[i]).transferOwnership(d.govSafe);
        }
        d.registry.transferOwnership(d.timelock);
        d.pool.transferOwnership(d.timelock);
        console2.log("  Adapters admin pendingOwner -> Gov Safe (writer stays keeper EOA)");
        console2.log("  Registry/Pool pendingOwner -> Timelock");
        console2.log("");
    }

    // -- Step 8: invariant asserts -------------------------------------------
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
            require(
                MockOracleAdapterV2Settable(d.adapter[i]).pendingOwner() == d.govSafe,
                "adapter admin pendingOwner != Gov Safe"
            );
            (uint256 p, bool safe) = MockOracleAdapterV2Settable(d.adapter[i]).peekPrice(d.token[i]);
            require(p == cfg[i].pegPrice1e18 && safe, "adapter not safe at peg");
        }
        require(d.freshGovernance, "governance not fresh");
        console2.log("Registry.pool, pauseGuardian, pending owners, adapters, caps: ok");
        console2.log("NAV USD (1e18):", d.pool.totalReservesUSD());
    }

    // -- Step 9: address ledger ----------------------------------------------
    function _emitLedger(Deployed memory d, TokenCfg[3] memory cfg) internal view {
        console2.log("");
        console2.log("=== ADDRESS LEDGER (capture into ops/arckeeper/.env + the SDK Arc config) ===");
        console2.log("REGISTRY=", address(d.registry));
        console2.log("POOL=", address(d.pool));
        console2.log("LP=", address(d.lp));
        console2.log("GOV_SAFE=", d.govSafe);
        console2.log("PG_SAFE=", d.pgSafe);
        console2.log("TIMELOCK=", d.timelock);
        for (uint256 i = 0; i < 3; i++) {
            console2.log(string.concat("TOKEN_", cfg[i].symbol, "= "), d.token[i]);
            console2.log(string.concat("ADAPTER_", cfg[i].symbol, "= "), d.adapter[i]);
        }
        console2.log("");
        console2.log("NEXT: start the keeper (ops/arckeeper/push-prices-arc.mjs) so adapters stay fresh.");
        console2.log("  Gov Safe schedules+executes Timelock ops calling Registry/Pool.acceptOwnership().");
        console2.log("  Gov Safe calls each adapter.acceptOwnership() directly (Ownable2Step admin).");
    }
}
```

Repo-gotcha notes encoded above:
- **Non-ASCII in string literals** — no `§`/em-dash appears INSIDE any `"..."` string; `§` lives only in `///` NatSpec (solc/forge fmt accept it). If a future `console2.log("...")` needs `§` or an em-dash, use `unicode"..."` (an em-dash inside a plain `"..."` breaks the build).
- **NatSpec `@x/...`** — no doc comment contains an `@`-prefixed slug that would lex as a tag.
- **Stack-too-deep** — `run()` delegates each phase to a `_step` helper taking `Deployed memory d` by reference (the exact pattern `DeployPublicTestnet`/`DeployBaseSepoliaV2` use), so no single function holds the full local set. If a future inline edit triggers `Stack too deep`, re-extract the offending phase into a helper (minimal split).
- **Arc chainid guard** — `require(block.chainid == 5042002, ...)` is the first line of `run()`; the simulated dry-run uses `--chain 5042002`.

- [ ] **Step 2: Compile-check the orchestrator**

Run:
```bash
cd contracts && forge fmt && forge build 2>&1 | tail -5
```
Expected: `Compiler run successful`. If `Stack too deep`, confirm the phase helpers were not inlined. If an unresolved import appears, confirm the `MockOracleAdapterV2Settable`/Pool/Registry/MintableERC20/GovernanceFactory paths match Task 0 Step 4.

- [ ] **Step 3: Commit**

Run:
```bash
git add contracts/script/DeployArcV2.s.sol
git commit -m "feat(v2): DeployArcV2 turnkey orchestrator (tokens/gov/mock-adapters/registry/pool/handoff) chainid 5042002

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Fork-mode revalidation + gap-test coupling + mock-adapter drills

Mirrors `DeployBaseSepoliaV2.t.sol`: the test INHERITS `DeployArcV2`, so it drives the orchestrator's OWN `_cfg()`, `_defaultBands()`, and the build/list/seed/handoff decisions. A regression in the deploy code fails CI. Because the mock adapters are settable, no etched Pyth is needed — the deploy shape + §11/§7/§8 drills run deterministically.

**Files:**
- Create `contracts/test/DeployArcV2.t.sol`

- [ ] **Step 1: Write the test suite**

Create `contracts/test/DeployArcV2.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployArcV2} from "../script/DeployArcV2.s.sol";
import {ArcoraDexRegistryV2} from "../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexPoolV2} from "../src/v2/ArcoraDexPoolV2.sol";
import {ArcoraDexLPV2} from "../src/v2/ArcoraDexLPV2.sol";
import {IArcoraDexRegistryV2} from "../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "../src/v2/interfaces/IOracleAdapterV2.sol";
import {FeeBandMathV2} from "../src/v2/lib/FeeBandMathV2.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
import {MockOracleAdapterV2Settable} from "../src/v2/testnet/MockOracleAdapterV2Settable.sol";

/// @notice Revalidation + gap-test coupling for DeployArcV2. INHERITS the orchestrator
/// so the asserts call its OWN `_cfg()`, `_defaultBands()`, and the build/list/seed
/// decisions — a regression in the deploy fails CI. Mock adapters are settable, so the
/// full deploy shape + §7/§11/§8 drills run deterministically with no etched feeds.
contract DeployArcV2Test is Test, DeployArcV2 {
    // -- Config drift guard: _cfg() MUST equal the authoritative Arc table --
    function test_drift_cfg_matches_authoritative_table() public pure {
        TokenCfg[3] memory c = _cfg();
        assertEq(c[0].pegPrice1e18, 1e18, "USDC peg drift");
        assertEq(c[1].pegPrice1e18, 1e18, "USDT peg drift");
        assertEq(c[2].pegPrice1e18, 115e16, "EURC peg drift");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(uint256(c[i].decimals), 6, "decimals must be 6");
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

    // -- Full deploy-shape revalidation (drives the orchestrator's REAL helpers) --
    function _deployForTest() internal returns (Deployed memory d) {
        TokenCfg[3] memory cfg = _cfg();
        address deployer = address(this);
        address keeper = makeAddr("keeper");

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

        // Adapters (writer=deployer to seed, then setWriter(keeper)) — mirrors _buildAdapters.
        for (uint256 i = 0; i < 3; i++) {
            MockOracleAdapterV2Settable a = new MockOracleAdapterV2Settable(deployer, deployer);
            a.setPrice(d.token[i], cfg[i].pegPrice1e18, true);
            a.setWriter(keeper);
            d.adapter[i] = address(a);
        }

        // Registry + list (drives the REAL _defaultBands listing decision).
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
        d.lp = ArcoraDexLPV2(address(d.pool.LP()));
        d.registry.setPool(address(d.pool));
        d.pool.setPauseGuardian(d.pgSafe);
        for (uint256 i = 0; i < 3; i++) {
            MintableERC20(d.token[i]).approve(address(d.pool), cfg[i].seedAmount);
            d.pool.deposit(d.token[i], cfg[i].seedAmount, 0, block.timestamp + 1 days);
        }

        // Handoffs (adapter writer set BACK to deployer so this test can drive drills;
        // in the real deploy the keeper EOA is the writer — the admin handoff is identical).
        for (uint256 i = 0; i < 3; i++) {
            MockOracleAdapterV2Settable(d.adapter[i]).setWriter(deployer); // test-only: regain push for drills
            MockOracleAdapterV2Settable(d.adapter[i]).transferOwnership(d.govSafe);
        }
        d.registry.transferOwnership(d.timelock);
        d.pool.transferOwnership(d.timelock);
    }

    function test_deploy_shape_invariants() public {
        Deployed memory d = _deployForTest();
        assertEq(d.registry.pool(), address(d.pool), "Registry.pool");
        assertEq(d.pool.pauseGuardian(), d.pgSafe, "pauseGuardian");
        assertEq(d.pool.pendingOwner(), d.timelock, "Pool pending owner");
        assertEq(d.registry.pendingOwner(), d.timelock, "Registry pending owner");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(MockOracleAdapterV2Settable(d.adapter[i]).pendingOwner(), d.govSafe, "adapter admin pending owner");
            assertTrue(d.registry.isActive(d.token[i]), "token active");
        }
        assertGt(d.pool.totalReservesUSD(), 0, "NAV seeded");
    }

    // -- §11 oracle-failure: flip an adapter unsafe -> swaps into it revert; proportional exit works --
    function test_drill_oracle_failure() public {
        Deployed memory d = _deployForTest();
        // EURC is token[2]; writer is the deployer (set in _deployForTest for drills).
        MockOracleAdapterV2Settable(d.adapter[2]).setSafe(d.token[2], false);
        (, bool safe) = MockOracleAdapterV2Settable(d.adapter[2]).peekPrice(d.token[2]);
        assertFalse(safe, "EURC must be unsafe after setSafe(false)");
        vm.expectRevert(abi.encodeWithSelector(ArcoraDexPoolV2.OracleUnsafe.selector, d.token[2]));
        d.pool.quoteSwapV2(d.token[0], d.token[2], 1_000_000);
        // Proportional exit still works (no oracle needed). Warp past MIN_HOLD_SECONDS (1h).
        vm.warp(block.timestamp + 2 hours);
        d.pool.withdrawProportional(d.lp.balanceOf(address(this)) / 10, block.timestamp + 1);
    }

    // -- §7 reserve-floor: an over-max swap reverts ReserveFloorBreached; maxSwapOut gives the ceiling --
    function test_drill_reserve_floor() public {
        Deployed memory d = _deployForTest();
        (uint256 maxNet,) = d.pool.maxSwapOut(d.token[1]); // USDT out
        assertGt(maxNet, 0, "a floor-safe max exists");
        vm.expectRevert(abi.encodeWithSelector(ArcoraDexPoolV2.ReserveFloorBreached.selector, d.token[1]));
        d.pool.quoteSwapV2(d.token[0], d.token[1], 1_000_000_000_000); // 1,000,000 USDC in
    }

    // -- §8.3 proportional exit while paused: PG Safe pauses; proportional still works --
    function test_drill_proportional_exit_while_paused() public {
        Deployed memory d = _deployForTest();
        vm.prank(d.pgSafe);
        d.pool.pause();
        assertTrue(d.pool.paused(), "paused");
        vm.warp(block.timestamp + 2 hours);
        d.pool.withdrawProportional(d.lp.balanceOf(address(this)) / 10, block.timestamp + 1);
    }

    // -- §6.2 pause authority: PG Safe pauses; PG Safe CANNOT unpause (owner-only) --
    function test_drill_pause_authority() public {
        Deployed memory d = _deployForTest();
        vm.prank(d.pgSafe);
        d.pool.pause();
        vm.prank(d.pgSafe);
        vm.expectRevert();
        d.pool.unpause();
    }
}
```

Note on `d.lp` typing: the `Deployed` struct types `lp` as `ArcoraDexLPV2`, which exposes `balanceOf`/`totalSupply` directly (it is the ERC20 LP). `d.lp = ArcoraDexLPV2(address(d.pool.LP()))` mirrors the orchestrator exactly. If `pool.LP()` returns an interface type, cast through `address(...)` as shown.

- [ ] **Step 2: Run it (expect GREEN)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/DeployArcV2.t.sol" 2>&1 | tail -20
```
Expected: all tests pass, `0 failed`. If `test_drill_reserve_floor` does NOT revert, the swap input is too small relative to the seeded reserve — increase the input until it crosses the floor. If `test_drill_oracle_failure` proportional exit reverts on min-hold, confirm the `vm.warp(+2 hours)` exceeds `MIN_HOLD_SECONDS` (1h). If `pause()` by `pgSafe` reverts, confirm `setPauseGuardian(pgSafe)` ran before the prank.

- [ ] **Step 3: Commit**

Run:
```bash
git add contracts/test/DeployArcV2.t.sol
git commit -m "test(v2): DeployArcV2 revalidation + drift guard + mock-adapter §11/§7/§8 drills

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Arc V2 keeper (push fresh safe prices so adapters read safe)

A standalone Node keeper that pushes a fresh `setPrice(token, price1e18, true)` per token on a timer so each adapter's `peekPrice(token).safe == true` stays current. Reuses `ops/keepalive/lib.mjs` transport/gas/nonce hardening; isolates the Arc-V2 specifics in `ops/arckeeper/lib.mjs`. New directory — no collision with `ops/keepalive/` (V1 Arc feeds) or `ops/basekeeper/` (Base Sepolia).

**Files:**
- Create `ops/arckeeper/lib.mjs`
- Create `ops/arckeeper/push-prices-arc.mjs`
- Create `ops/arckeeper/test/push-prices.test.mjs`
- Create `ops/arckeeper/package.json`

- [ ] **Step 1: Write the Arc-V2 keeper helpers**

Create `ops/arckeeper/lib.mjs`:
```javascript
// Arc-V2 keeper helpers: chain def 5042002 + adapter ABI + pure price-shaping.
// Kept separate from ops/keepalive/lib.mjs (V1 Arc feeds) so that keeper is untouched.
import { defineChain, parseAbi } from "viem";
import { resolveRpcUrls } from "../keepalive/lib.mjs";

const DEFAULT_RPC = "https://rpc.testnet.arc.network";

export const arcTestnet = defineChain({
    id: 5042002,
    name: "Arc Testnet",
    nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, // Arc native gas = USDC (18-dec)
    rpcUrls: {
        default: {
            http: resolveRpcUrls({
                primary: process.env.ARC_TESTNET_RPC,
                fallback: process.env.ARC_TESTNET_RPC_FALLBACK,
                defaultRpc: DEFAULT_RPC,
            }),
        },
    },
});

// MockOracleAdapterV2Settable.setPrice(token, price1e18, safe) — writer-gated.
export const ADAPTER_ABI = parseAbi([
    "function setPrice(address token, uint256 price1e18, bool safe) external",
    "function peekPrice(address token) view returns (uint256 price1e18, bool safe)",
    "function writer() view returns (address)",
]);

// The 3 Arc pool tokens' USD pegs (1e18). Must match DeployArcV2._cfg() pegPrice1e18.
export const PEGS_1E18 = {
    USDC: 1_000000000000000000n,
    USDT: 1_000000000000000000n,
    EURC: 1_150000000000000000n,
};

/// Pure: build the per-token push list from the ledger env. Returns
/// [{ symbol, adapter, token, price1e18 }] for every symbol whose ADAPTER_<S> and
/// TOKEN_<S> are both present. Throws if a present adapter has no matching peg.
export function buildPushList(env) {
    const out = [];
    for (const symbol of Object.keys(PEGS_1E18)) {
        const adapter = env[`ADAPTER_${symbol}`];
        const token = env[`TOKEN_${symbol}`];
        if (!adapter || !token) continue;
        const price1e18 = PEGS_1E18[symbol];
        if (price1e18 === undefined) throw new Error(`no peg for ${symbol}`);
        out.push({ symbol, adapter, token, price1e18 });
    }
    return out;
}
```

- [ ] **Step 2: Write the keeper entrypoint**

Create `ops/arckeeper/push-prices-arc.mjs`:
```javascript
// Arc V2 keeper — push a fresh setPrice(token, peg, true) per token so each
// MockOracleAdapterV2Settable reads `safe`. The mock adapter has no intrinsic
// staleness, but a periodic refresh (a) keeps the on-chain price + timestamp
// current for parity with the Base Pyth keeper cadence and (b) lets the operator
// drive the §11 oracle-failure drill simply by STOPPING the keeper + flipping
// safe=false via the writer key.
//
// Required env:
//   KEEPER_PRIVATE_KEY  — the adapter `writer`; needs a little Arc USDC for gas
//   ADAPTER_USDC / ADAPTER_USDT / ADAPTER_EURC — deployed adapter addresses (from the ledger)
//   TOKEN_USDC / TOKEN_USDT / TOKEN_EURC       — deployed token addresses (from the ledger)
// Optional env:
//   ARC_TESTNET_RPC, ARC_TESTNET_RPC_FALLBACK, KEEPER_MAX_FEE_GWEI, KEEPER_TX_TIMEOUT_MS
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { resolveGasCeiling, numEnv, DEFAULT_TX_TIMEOUT_MS, buildTransport, resolveRpcUrls } from "../keepalive/lib.mjs";
import { arcTestnet, ADAPTER_ABI, buildPushList } from "./lib.mjs";

const ts = () => new Date().toISOString();
const log = (m) => console.log(`[arc-v2-keeper] ${ts()} ${m}`);
const TX_TIMEOUT_MS = numEnv(process.env.KEEPER_TX_TIMEOUT_MS, DEFAULT_TX_TIMEOUT_MS);

async function main() {
    const pkRaw = process.env.KEEPER_PRIVATE_KEY;
    if (!pkRaw) { log("KEEPER_PRIVATE_KEY missing — abort"); process.exit(2); }
    const pk = pkRaw.startsWith("0x") ? pkRaw : `0x${pkRaw}`;
    const account = privateKeyToAccount(pk);

    const pushes = buildPushList(process.env);
    if (pushes.length === 0) { log("no ADAPTER_*/TOKEN_* env present — abort"); process.exit(2); }

    const transport = buildTransport(resolveRpcUrls({
        primary: process.env.ARC_TESTNET_RPC,
        fallback: process.env.ARC_TESTNET_RPC_FALLBACK,
        defaultRpc: "https://rpc.testnet.arc.network",
    }));
    const publicClient = createPublicClient({ chain: arcTestnet, transport });
    const walletClient = createWalletClient({ account, chain: arcTestnet, transport });
    const gasCeiling = resolveGasCeiling(process.env);

    let pushed = 0, errored = 0;
    for (const { symbol, adapter, token, price1e18 } of pushes) {
        try {
            const hash = await walletClient.writeContract({
                address: adapter,
                abi: ADAPTER_ABI,
                functionName: "setPrice",
                args: [token, price1e18, true],
                maxFeePerGas: gasCeiling.maxFeePerGas,
                maxPriorityFeePerGas: gasCeiling.maxPriorityFeePerGas,
            });
            await publicClient.waitForTransactionReceipt({ hash, timeout: TX_TIMEOUT_MS });
            log(`${symbol}: setPrice ${price1e18} safe=true tx=${hash}`);
            pushed++;
        } catch (err) {
            log(`${symbol}: ERROR ${err?.message || err}`);
            errored++;
        }
    }
    log(`done pushed=${pushed} errored=${errored}`);
    if (errored > 0) process.exit(1);
}

main().catch((err) => { log(`fatal: ${err?.message || err}`); process.exit(1); });
```
Note: `http` is imported for symmetry but the transport is built via `buildTransport(resolveRpcUrls(...))` (fallback-aware). Drop the bare `http` import if your linter flags it as unused.

- [ ] **Step 3: Write the pure-function Node test**

Create `ops/arckeeper/test/push-prices.test.mjs`:
```javascript
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildPushList, PEGS_1E18 } from "../lib.mjs";

test("buildPushList returns one entry per fully-configured token", () => {
    const env = {
        ADAPTER_USDC: "0xaUSDC", TOKEN_USDC: "0xtUSDC",
        ADAPTER_USDT: "0xaUSDT", TOKEN_USDT: "0xtUSDT",
        ADAPTER_EURC: "0xaEURC", TOKEN_EURC: "0xtEURC",
    };
    const out = buildPushList(env);
    assert.equal(out.length, 3);
    const usdc = out.find((p) => p.symbol === "USDC");
    assert.equal(usdc.adapter, "0xaUSDC");
    assert.equal(usdc.token, "0xtUSDC");
    assert.equal(usdc.price1e18, 1_000000000000000000n);
    const eurc = out.find((p) => p.symbol === "EURC");
    assert.equal(eurc.price1e18, 1_150000000000000000n);
});

test("buildPushList skips a token missing its adapter or token address", () => {
    const env = { ADAPTER_USDC: "0xaUSDC" }; // no TOKEN_USDC
    assert.equal(buildPushList(env).length, 0);
});

test("PEGS_1E18 matches the orchestrator _cfg() pegs", () => {
    assert.equal(PEGS_1E18.USDC, 1_000000000000000000n);
    assert.equal(PEGS_1E18.USDT, 1_000000000000000000n);
    assert.equal(PEGS_1E18.EURC, 1_150000000000000000n);
});
```

- [ ] **Step 4: Write the package.json (reuse the keepalive viem dep tree)**

Create `ops/arckeeper/package.json`:
```json
{
    "name": "arcoradex-arc-v2-keeper",
    "private": true,
    "type": "module",
    "scripts": {
        "test": "node --test test/",
        "push": "node push-prices-arc.mjs"
    },
    "dependencies": {
        "viem": "^2.0.0"
    }
}
```
Note: `ops/arckeeper/lib.mjs` imports from `../keepalive/lib.mjs`, which already has `viem` installed under `ops/keepalive/node_modules`. To avoid a second install, either (a) run the keeper from `ops/keepalive/` resolving the relative import, or (b) `npm install` in `ops/arckeeper/` (pin the same `viem` version as `ops/keepalive/package.json`). Confirm the version pin against `ops/keepalive/package.json` when implementing.

- [ ] **Step 5: Run the Node test**

Run:
```bash
cd ops/arckeeper && npm install 2>&1 | tail -3 && node --test test/ 2>&1 | tail -10
```
Expected: `# pass 3`, `# fail 0`. If the `../keepalive/lib.mjs` import fails to resolve, confirm the relative path and that `ops/keepalive/lib.mjs` exports `resolveRpcUrls`/`buildTransport`/`resolveGasCeiling`/`numEnv` (it does).

- [ ] **Step 6: Commit**

Run:
```bash
git add ops/arckeeper/
git commit -m "feat(ops): Arc V2 keeper (push fresh safe prices to mock adapters) + tests

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Deploy runbook

The operator-facing runbook: env, pre-flight, the single `forge script` invocation, ledger capture, keeper start, and the post-deploy governance accepts.

**Files:**
- Create `docs/runbooks/2026-06-11-arc-v2-deploy.md`

- [ ] **Step 1: Write the runbook**

Create `docs/runbooks/2026-06-11-arc-v2-deploy.md`:
```markdown
# Arc Testnet V2 Deploy Runbook (chainId 5042002, MOCK oracles)

Deploys the full ArcoraDEX V2 stack on Arc testnet so the existing V2 UI runs on Arc
identically to Base Sepolia. Arc has NO Pyth and NO real Chainlink, so each token is
priced by a deployable keeper-settable `MockOracleAdapterV2Settable` (seeded SAFE at peg).

## Chain facts
- chainId 5042002 (hex 0x4CEF52); RPC https://rpc.testnet.arc.network; explorer https://testnet.arcscan.app
- Native gas is USDC (18-dec native units). Get testnet USDC from https://faucet.circle.com
  for the DEPLOYER and the KEEPER before running anything.

## Env (FRESH governance via the test mnemonic on testnet)
```
export DEPLOYER_PRIVATE_KEY=0x...          # broadcasts; mints + seeds; holds Arc USDC for gas
export KEEPER_EOA=0x...                     # the price-pusher address (becomes each adapter writer)
export GOV_USE_TEST_MNEMONIC=true           # testnet opt-in (factory's mainnet guard still applies)
export TIMELOCK_MIN_DELAY=172800            # 48h (or 0 for a fast launch, then updateDelay)
export ARC_TESTNET_RPC=https://rpc.testnet.arc.network
```
For a real-owners launch, omit GOV_USE_TEST_MNEMONIC and set GOV_SAFE_OWNERS / GOV_SAFE_THRESHOLD /
PG_SAFE_OWNERS / PG_SAFE_THRESHOLD instead.

## Deploy (single broadcast)
```
cd contracts
forge script script/DeployArcV2.s.sol:DeployArcV2 \
  --rpc-url "$ARC_TESTNET_RPC" --broadcast --slow -vvv
```
The orchestrator deploys governance -> 3 tokens -> 3 mock adapters (seeded SAFE at peg) ->
Registry (3 listed, §7 bands, low caps) -> Pool -> setPool + pause guardian -> bootstrap (all 3
seed; oracles safe by construction) -> handoffs -> invariant asserts -> ADDRESS LEDGER.

## Capture the ledger
Copy the `=== ADDRESS LEDGER ===` block into `ops/arckeeper/.env`:
```
REGISTRY=0x...   POOL=0x...   LP=0x...
GOV_SAFE=0x...   PG_SAFE=0x...   TIMELOCK=0x...
TOKEN_USDC=0x... ADAPTER_USDC=0x...
TOKEN_USDT=0x... ADAPTER_USDT=0x...
TOKEN_EURC=0x... ADAPTER_EURC=0x...
KEEPER_PRIVATE_KEY=0x...   ARC_TESTNET_RPC=https://rpc.testnet.arc.network
```
The SDK Arc config + app chain switcher (NEXT plan) consume the same addresses.

## Start the keeper
Push fresh safe prices so the adapters stay current (and so swaps/deposits never read unsafe):
```
cd ops/arckeeper && npm install && node push-prices-arc.mjs   # one-shot; wire to a systemd timer or /loop
```
Cadence: any interval well under the operator's comfort (e.g. 30 min) is fine — the mock adapter
has no intrinsic staleness, so this is for freshness/parity, not to avoid a revert.

## Post-deploy governance accepts
- Gov Safe (3/5) schedules + executes Timelock ops calling `Registry.acceptOwnership()` and
  `Pool.acceptOwnership()` (incurs TIMELOCK_MIN_DELAY).
- Gov Safe (3/5) calls each `adapter.acceptOwnership()` directly (Ownable2Step admin). The adapter
  `writer` stays the keeper EOA throughout — governance owns only the admin (writer-rotation) role.

## Failure drill (operator)
To simulate an oracle outage on a token: stop the keeper, then (with the keeper key, still the
writer) call `adapter.setSafe(token, false)`. Swaps INTO that token + single-token withdrawals
revert `OracleUnsafe`; `withdrawProportional` still works. Restore with `setPrice(token, peg, true)`.
```

- [ ] **Step 2: Commit**

Run:
```bash
git add docs/runbooks/2026-06-11-arc-v2-deploy.md
git commit -m "docs(v2): Arc testnet V2 deploy runbook (mock oracles, keeper, governance accepts)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Full suite, fmt gate, simulated dry-run, static gotcha scans

**Files:** verification only.

- [ ] **Step 1: `forge fmt --check` (CI gate)**

Run:
```bash
cd contracts && forge fmt --check 2>&1 | tail -5
```
Expected: no diff output (exit 0). If anything prints, run `forge fmt` and amend the relevant commit.

- [ ] **Step 2: Full default-profile suite (288 baseline + new tests, all green)**

Run:
```bash
cd contracts && forge test 2>&1 | tail -3
```
Expected: `<288 + new> tests passed, 0 failed, 3 skipped`. The new tests are `MockOracleAdapterV2Settable.t.sol` (8) + `DeployArcV2.t.sol` (6) = +14 (record the exact total). The 3 pre-existing skips (fork tests without an RPC) remain skipped.

- [ ] **Step 3: Compile the deploy script in isolation**

Run:
```bash
cd contracts && forge build 2>&1 | tail -3
```
Expected: `Compiler run successful` (script + new contract + imports compile).

- [ ] **Step 4: Local simulated dry-run on chainid 5042002 (no broadcast)**

Run (test mnemonic so no real owners needed; `--chain 5042002` makes the chainid guard pass under simulation; NO `--broadcast`; a throwaway keeper address):
```bash
cd contracts && \
  DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  KEEPER_EOA=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
  GOV_USE_TEST_MNEMONIC=true \
  forge script script/DeployArcV2.s.sol:DeployArcV2 --chain 5042002 2>&1 | tail -30
```
Expected: the script SIMULATES through governance + tokens + adapters (seeded SAFE at peg) +
registry + pool + bootstrap (all 3 seed — oracles are safe by construction, NO Pyth pull needed,
unlike the Base Sepolia path) + handoffs + `_summary` invariant asserts, and prints the ADDRESS
LEDGER. Confirm: no revert through `_handoff`/`_summary`; `NAV USD (1e18)` is non-zero (all 3 seeded).
If it reverts in `_buildAdapters` on `setWriter`, confirm the deployer is the constructor writer
before `setWriter(keeper)`.

- [ ] **Step 5: Static gotcha scans (non-ASCII string literals + the Arc chainid guard)**

Run:
```bash
cd contracts && \
  grep -nP '"[^"]*[^\x00-\x7F][^"]*"' script/DeployArcV2.s.sol test/DeployArcV2.t.sol \
    src/v2/testnet/MockOracleAdapterV2Settable.sol test/v2/MockOracleAdapterV2Settable.t.sol \
    | grep -v 'unicode"' || echo "OK: no bare non-ASCII string literals"
cd contracts && grep -n "block.chainid == 5042002\|require(block.chainid" script/DeployArcV2.s.sol
```
Expected: `OK: no bare non-ASCII string literals`; and the chainid guard line prints (5042002 enforced).

- [ ] **Step 6: Final no-op commit (only if fmt/scan fixups were needed)**

Run:
```bash
git add -A && git commit -m "chore(v2): fmt gate + gotcha scans for Arc V2 deploy" || echo "nothing to commit"
```

---

## Self-Review

### Spec coverage (section-by-section)

- **§13 step 1 (deploy + test the complete stack on a testnet)** — `DeployArcV2.s.sol` deploys the COMPLETE V2 stack on Arc (5042002) in one broadcast: 3 fresh test tokens, fresh governance (Gov Safe 3/5 + PG Safe 2/3 + 48h Timelock via `GovernanceFactory`), 3 keeper-settable mock adapters (seeded SAFE at peg), Registry (3 listed, §7 bands), immutable Pool, setPool, pause guardian, bootstrap, handoffs, invariant asserts, ledger emit. Tasks 1-3. The revalidation test drives the orchestrator's OWN code end-to-end. ✓
- **§13 step 5 (low token-level caps)** — every `_cfg()` token has a conservative `depositCapUsd` (10,000e18) far above the seed (~1,000 USD) but bounded for rollout; the drift guard asserts the caps are set + the seed fits under them. ✓
- **§10/§11 (oracle architecture / failure behavior, ADAPTED for Arc)** — Arc has no real feeds, so the §10 dual-source adapter is deliberately replaced by the keeper-settable `MockOracleAdapterV2Settable` (ORACLE-OPTION decision). The Pool's §11 failure path is preserved + tested: `test_drill_oracle_failure` flips a token unsafe -> swaps into it revert `OracleUnsafe`, proportional exit survives. The real dual-source adapter is exercised on Base (other plan). ✓ (adapted, justified)
- **§7 (fee bands + reserve floor)** — identical §7 4-band schedule + per-token min/target/cap as Base; `test_drill_reserve_floor` proves `ReserveFloorBreached` + `maxSwapOut`. ✓
- **§8.3 / §6.2 (proportional exit, pause authority)** — `test_drill_proportional_exit_while_paused` + `test_drill_pause_authority` prove proportional exit works while paused and that the PG Safe can pause but not unpause (owner-only). ✓
- **§9 (UI parity)** — the whole point: `reserveHealth`/`quoteSwapV2`/`maxSwapOut`/`totalReservesUSD` all derive from the Pool, which reads only `(price1e18, safe)` from the adapter. The mock adapter returns safe peg prices, so the §9 UI is identical to Base Sepolia. ✓

### House-pattern fidelity (explicit)

| House pattern (source) | How this plan reuses it |
|---|---|
| Turnkey single-broadcast orchestrator w/ in-process ledger (`DeployBaseSepoliaV2.run` + `Deployed`) | `DeployArcV2.run` + `Deployed`; every address chained, no log scraping. |
| Pure `_cfg()` source of truth + drift guard test | `_cfg()` (3 tokens) + `test_drift_cfg_matches_authoritative_table`. |
| Gap-test INHERITS the script to drive its REAL code | `DeployArcV2Test is DeployArcV2`. |
| `_summary` post-deploy `require` invariant asserts + `_emitLedger` | `_summary` (registry.pool, pauseGuardian, pending owners, adapters, caps, peg-safe) + `_emitLedger`. |
| `GovernanceFactory` fresh Safe 3/5 + PG 2/3 + Timelock; `GOV_USE_TEST_MNEMONIC` opt-in w/ mainnet guard | reused verbatim (chain-agnostic); allowed on 5042002, forbidden on chainid 1. |
| Seed-robust bootstrap (skip-on-unsafe) | `_bootstrap` retains the skip guard (all 3 seed since oracles are safe by construction). |
| Fresh-token deploy (`MintableERC20`) | `_deployTokens` (3 fresh 6-dec stables, mint seed + faucet headroom). |
| Role-separated testnet feed (`src/testnet/MockChainlinkFeedV2`: owner=admin / writer=keeper) | `MockOracleAdapterV2Settable` (same split, `Ownable2Step` admin + keeper writer). |
| Keeper hardening (`ops/keepalive/lib.mjs` gas/nonce/timeout/transport) | `push-prices-arc.mjs` imports `resolveGasCeiling`/`numEnv`/`buildTransport`/`resolveRpcUrls`/`DEFAULT_TX_TIMEOUT_MS`. |

### Decision log (ambiguities resolved, explicit)

1. **Oracle source: Option 2 — deployable keeper-settable `MockOracleAdapterV2Settable`.** Justified above (ORACLE-OPTION DECISION): the real adapter's constructor reverts on zero feeds AND calls `chainlinkFeed.decimals()`, so Option 1 forces a 3-contract/token + 2-leg keeper that must avoid its own divergence/staleness logic; `MockPyth` is test-only and would need promotion. Option 2 is one small auditable contract (mirroring `MockChainlinkFeedV2`'s owner/writer split), keeps the §9 UI identical, and makes the §11 drill a one-liner (`setSafe(false)`).
2. **Tokens: FRESH `MintableERC20` (USDC/USDT/EURC, 6-dec), NOT Arc's canonical USDC.** Justified above (TOKENS DECISION): canonical USDC is the native gas token (mixing pool + gas balance is the Arc footgun) and is not owner-mintable by us (breaks the faucet). Fresh tokens mirror the Base Sepolia deploy exactly. Native USDC is still used for gas.
3. **Governance: FRESH via `GovernanceFactory`, `GOV_USE_TEST_MNEMONIC` opt-in ALLOWED on 5042002.** The factory's mainnet guard (`require(block.chainid != 1)`) is intact and the orchestrator's `require(block.chainid == 5042002)` double-locks it. A real run can pass `GOV_SAFE_OWNERS` for real owners.
4. **Adapter admin -> Gov Safe; writer stays the keeper EOA; Registry/Pool -> Timelock.** The adapter's only governance-owned authority is writer-rotation (admin); the keeper EOA keeps pushing prices without a Safe signature. Registry/Pool (asset + admission authority) go to the 48h Timelock. All as a clean Ownable2Step pending state; accepts documented in `_emitLedger` + the runbook.
5. **Pause guardian = PG Safe; unpause owner-only (Timelock).** `pool.setPauseGuardian(pgSafe)`; the §6.2 authority split is tested by `test_drill_pause_authority`.
6. **Bootstrap needs NO pre-deploy oracle pull (unlike Base/Pyth).** The mock adapters are seeded SAFE at peg INSIDE the broadcast (step 3) before the bootstrap (step 6), so all 3 tokens seed in the single run. The seed-robust skip guard is retained for safety/parity but never trips.
7. **Keeper: standalone Node + viem, NEW `ops/arckeeper/` dir, reusing `ops/keepalive/lib.mjs`.** No collision with `ops/keepalive/` (V1 Arc feeds) or `ops/basekeeper/` (Base Sepolia). The push is a single `setPrice(token, peg, true)` per token; it imports the hardened transport/gas helpers.
8. **Keeper cadence is freshness/parity, not a revert-avoidance requirement.** The mock adapter has no intrinsic staleness, so a stopped keeper does NOT auto-fail a token — which is exactly what makes the §11 drill a deliberate operator action (`setSafe(false)`), documented in the runbook.
9. **No core V2 contract is edited.** PoolV2/RegistryV2/LPV2/FeeBandMathV2 are deployed unchanged. The only new `src/` contract is `MockOracleAdapterV2Settable` (testnet-only, under `src/v2/testnet/`). The only `new`-deployed contracts at runtime are the reused `MintableERC20`, the new mock adapter, `ArcoraDexRegistryV2`, `ArcoraDexPoolV2`, and the `GovernanceFactory` stack.
10. **`readPrice` view-override caveat flagged.** `IOracleAdapterV2.readPrice` is non-view; the mock returns a stored value so a `view` override is natural (view is a strict subset of non-view — allowed). Task 1 Step 3 flags the fallback (drop `view`) if a toolchain rejects it.
11. **SDK + app chain switcher are OUT of scope.** This plan emits the address ledger; the next plan wires `packages/sdk/src/chains/arcTestnet.ts` + `addresses.v2.ts` for Arc and adds the app switcher. The §9 UI works on Arc the moment the SDK points at these addresses.

### Placeholder scan
- No "TBD" / "implement later" in shown Solidity or Node code — every function body is complete and compiles (the new contract, the orchestrator, the revalidation test, the keeper lib + entrypoint, the Node tests).
- The keeper entrypoint's transport is built via the hardened `buildTransport(resolveRpcUrls(...))` (NOT a stub); the only explicit wire-in note is the `viem` version pin for `ops/arckeeper/package.json` against `ops/keepalive/package.json` (Task 4 Step 4).
- The runbook is operator-facing prose + exact commands; the failure-drill section gives the exact `setSafe`/`setPrice` calls.

### Type/name consistency across tasks
- `MockOracleAdapterV2Settable(initialOwner, initialWriter)` + `setPrice(token, price1e18, safe)` + `setSafe` + `setWriter` + `peekPrice`/`readPrice` + `Ownable2Step` (`transferOwnership`/`acceptOwnership`/`pendingOwner`) — the contract (Task 1) and both the orchestrator (Task 2) and the test (Task 3) agree.
- `ArcoraDexPoolV2(registry, protocolFeeShareBps, owner)` + `pool.LP()` + `setPauseGuardian`/`pause`/`unpause`/`paused`/`pendingOwner`/`withdrawProportional`/`maxSwapOut`/`quoteSwapV2`/`totalReservesUSD` + errors `OracleUnsafe`/`ReserveFloorBreached`/`PoolPaused` — all verified against `ArcoraDexPoolV2.sol` + `IArcoraDexPoolV2.sol`.
- `ArcoraDexRegistryV2(initialOwner)` + `listToken(token, TokenConfigV2)` + `setPool` + `pool()` + `tokenConfig` + `isActive` + `pendingOwner` — verified against `IArcoraDexRegistryV2.sol`.
- `IArcoraDexRegistryV2.TokenConfigV2{decimals,isActive,adapter,minimumReserveUsd,targetReserveUsd,depositCapUsd,bands}` + `FeeBandMathV2.Band{upperHealthBps,rateBps}` — field names/types verified.
- `MintableERC20(name,symbol,decimals,owner)` + `mint` — verified against `src/testnet/MintableERC20.sol`.
- `GovernanceFactory.resolveConfig()` + `deploy(cfg, minDelay)` returning `Stack{govSafe,pgSafe,timelock}` + `Config.timelockMinDelay` + the `GOV_USE_TEST_MNEMONIC` opt-in w/ mainnet guard — verified against `script/GovernanceFactory.sol`.
- Keeper `PEGS_1E18` (1e18 pegs) match the orchestrator `_cfg().pegPrice1e18` (USDC/USDT 1e18, EURC 115e16); the Node test asserts the match.
- Arc chain facts (5042002, RPC, native USDC gas) verified against the `circle:use-arc` skill + the existing `ops/keepalive/multi-feed-push.mjs` Arc chain def.
```
