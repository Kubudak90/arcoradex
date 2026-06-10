# Base V2 Real Oracle Adapters (Chainlink + Pyth) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the production `ChainlinkPythAdapterV2` — a per-token implementation of `IOracleAdapterV2` (`readPrice`/`peekPrice` → `(uint256 price1e18, bool safe)`) that reads a Chainlink `token/USD` proxy (8-dec, 24h heartbeat) AND a Pyth `token/USD` price feed, normalizes both to 1e18, and decides safety ALONE per spec §10/§11: a token is `safe` only when BOTH sources are fresh, valid (positive), within Pyth's confidence-ratio bound, and within the cross-source divergence bound. Any stale/invalid/excess-confidence/excess-divergence/single-surviving-source read MUST yield `safe == false` (fail-closed). `peekPrice` and `readPrice` MUST return the same `(price, safe)` for the same block (O6) — the adapter performs NO Pyth pull-update inside `readPrice`; pulls happen only via a separate `updatePyth` keeper path. Ship a vendored minimal Pyth interface, full Foundry tests with mocked Chainlink + mocked Pyth (§14 stale/confidence/divergence/negative/expo-edge cases), a Base-mainnet fork test (skippable without an RPC), and the per-token deploy-config table (mainnet + Sepolia incl. the EURC mock-Chainlink-leg testnet workaround).

**Architecture:** One immutable `ChainlinkPythAdapterV2` instance per token. The constructor takes the token address, the Chainlink proxy (`IChainlinkAggregator`, reused from V1), the Pyth contract + this token's 32-byte Pyth feed ID, and immutable safety params (Chainlink `maxStaleSeconds`, Pyth `maxStaleSeconds`, Pyth `maxConfBps` confidence-ratio cap, cross-source `maxDivergenceBps`). Both legs normalize to a 1e18 USD price: Chainlink via its `decimals()` (8 on Base), Pyth via its signed `expo`. The adapter caches the last computed safe price (`lastSafePrice1e18`) updated lazily inside `readPrice` for §11 display context — but the SAFE decision and the RETURNED price are always recomputed from current feed state, so the cache never authorizes a transfer and never makes `readPrice` diverge from `peekPrice` (the cache write is the only state change and does not alter the returned tuple). Pyth freshness uses `getPriceUnsafe` (no pull, no revert) + an explicit `publishTime` staleness check — NOT `getPriceNoOlderThan` (which reverts and would couple the two functions' control flow). Pull-updates are isolated in `updatePyth(bytes[] calldata)`, callable by anyone (keeper), never reached by `readPrice`/`peekPrice`. The adapter is `Ownable2Step` only to allow governance to retune the runtime safety params (`maxDivergenceBps`, both stale windows, `maxConfBps`); the feeds and IDs are immutable.

**Tech Stack:** Solidity `^0.8.26`, Foundry (`forge build` / `forge test` / `forge fmt`), OpenZeppelin v5 (`Ownable`, `Ownable2Step`), forge-std (`Test`). Chainlink leg reuses the in-repo `IChainlinkAggregator` (`contracts/src/interfaces/IChainlinkAggregator.sol`). Pyth leg uses a **vendored minimal interface** (`contracts/src/v2/interfaces/IPythV2.sol`) — see Task 1 for the decision + justification. No new external dependency. Chain-agnostic contract; all addresses/IDs are deploy-time constructor args (no hardcoding in the contract).

**Out of scope (other plans):**
- Pool/Registry changes — the Pool already consumes `IOracleAdapterV2` and `Registry.setAdapter` already exists (core-contracts plan). This plan only produces the adapter the Registry points at.
- Off-chain monitoring, the third-reference divergence alert, keeper scheduling for `updatePyth` (spec §12).
- Base Sepolia / mainnet deploy ORCHESTRATION (Safe + 48h `TimelockController` wiring, the actual broadcast). This plan delivers the per-token config TABLE and a non-broadcasting config struct; the deploy script that consumes it is a later plan.
- SDK and application work (spec §9 app-side).
- Arc deployment (spec §1, §13).

---

## File Structure

| File | Responsibility (one each) |
|------|---------------------------|
| `contracts/src/v2/interfaces/IPythV2.sol` | Vendored minimal Pyth interface: the `Price` struct (`price`, `conf`, `expo`, `publishTime`) and the 4 methods the adapter needs (`getPriceUnsafe`, `getUpdateFee`, `updatePriceFeeds`, `getValidTimePeriod`). No full SDK import. |
| `contracts/src/v2/ChainlinkPythAdapterV2.sol` | The per-token `IOracleAdapterV2`: dual-source read, 1e18 normalization, per-source staleness, Pyth confidence bound, cross-source divergence, fail-closed `safe`, lazy `lastSafePrice` cache, isolated `updatePyth` pull path, governance param setters. |
| `contracts/test/v2/mocks/MockChainlinkFeed.sol` | Settable Chainlink aggregator mock: settable `answer`, `updatedAt`, `roundId`/`answeredInRound`, `decimals`, plus a `setRevert` toggle to drive the try/catch leg. (Created here if not already present; reused if a V1 equivalent exists — Task 2 checks first.) |
| `contracts/test/v2/mocks/MockPyth.sol` | Settable Pyth mock implementing `IPythV2`: settable per-id `Price{price,conf,expo,publishTime}`, `setRevert`, a no-op `updatePriceFeeds` that bumps `publishTime`, `getUpdateFee`/`getValidTimePeriod`. |
| `contracts/test/v2/ChainlinkPythAdapterV2.t.sol` | Full unit suite: normalization (8-dec CL + Pyth expo), per-source staleness (incl. the 24h heartbeat tolerance), Pyth confidence-ratio bound, cross-source divergence, zero/negative/malformed, single-source ⇒ unsafe, peek==read parity, last-price-retained-while-unsafe, governance setters, `updatePyth` isolation. |
| `contracts/test/v2/ChainlinkPythAdapterV2.fork.t.sol` | Base-mainnet fork test against the REAL verified USDC/EURC/USDT Chainlink proxies + Pyth contract/IDs; `vm.skip(true)` when `BASE_MAINNET_RPC` is unset so default CI stays green. |
| `docs/superpowers/plans/2026-06-10-base-v2-oracle-adapters.md` | This plan (incl. the §6 deploy-config table). |

All new contracts live under `contracts/src/v2/`, all new tests under `contracts/test/v2/`. No V1 file and no existing V2 file is edited (the adapter plugs into the unchanged `IOracleAdapterV2`). The existing V1 + V2 suites must stay green throughout.

---

### Task 0: Branch + baseline + verified-facts pin

**Files:** none modified; verification only.

- [ ] **Step 1: Create the adapters branch**

Run:
```bash
git checkout feat/base-v2-core-contracts && git checkout -b feat/base-v2-oracle-adapters && git log --oneline -1
```
Expected: clean branch at the core-contracts tip (the adapter builds on the merged `IOracleAdapterV2`). If core-contracts is already on `main`, branch from `main` instead and record which.

- [ ] **Step 2: Establish the baseline (must stay green)**

Run:
```bash
cd contracts && forge build && forge test 2>&1 | tail -3
```
Expected: `Compiler run successful`, then `<N> tests passed, 0 failed, 0 skipped`. Record `<N>` as the actual baseline (it is V1's 196 plus the V2 core-contracts tests).

- [ ] **Step 3: Pin the verified oracle facts the adapter encodes**

Open `docs/research/2026-06-10-base-oracle-feeds.md` and confirm these are the values used in the deploy table (§6 of this plan) and the fork test:

```text
Base mainnet (8453) Chainlink proxies (8 dec, 86400s heartbeat, 0.3% deviation):
  USDC/USD  0x7e860098F58bBFC8648a4311b374B1D669a2bc6B
  USDT/USD  0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9
  EURC/USD  0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250   (DIRECT — EURC needs no FX leg)

Pyth (Base mainnet) — TARGET THE UPGRADED 2026-07-31 contract:
  current   0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a
  UPGRADED  0xbC16aee60f64864882BC6C4E428e148Fc0E272F5   <-- deploy against this
Pyth (Base Sepolia):
  current   0xA2aa501b19aff244D90cc15a4Cf739D2725B5729
  UPGRADED  0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83    <-- deploy against this
  (post-2026-07-31 Pyth Core requires an API key for Hermes pulls — keeper concern, not on-chain)

Pyth feed IDs (identical mainnet + Sepolia):
  Crypto.USDC/USD  0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a
  Crypto.USDT/USD  0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b
  Crypto.EURC/USD  0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c
  (NOT 0x61162fa2… EURCV — Société Générale's coin. Pin EURC exactly.)

Base Sepolia (84532) Chainlink:
  USDC/USD  0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165  (observed ~8d stale — lenient testnet window)
  USDT/USD  0x3ec8593F930EA45ea58c968260e6e9FF53FC934f  (fresh)
  EURC/USD  DOES NOT EXIST — testnet EURC needs a mock Chainlink leg (MockChainlinkFeed)
```
No code in this step — this is the source of truth for Tasks 5/6. Do not let any of these drift.

- [ ] **Step 4: Create the directories (already exist from core-contracts; idempotent)**

Run:
```bash
mkdir -p contracts/src/v2/interfaces contracts/test/v2/mocks
git status --short
```
Expected: directories exist (empty additions show nothing — fine).

---

### Task 1: Vendored minimal Pyth interface (`IPythV2`)

**Decision (vendor vs dependency) — and its justification:**

We **vendor a minimal interface** (`IPythV2.sol`) rather than add `@pythnetwork/pyth-sdk-solidity` as a Foundry lib. Reasons:
1. The repo already vendors its oracle abstraction (`IChainlinkAggregator` is hand-written, not the brownie `AggregatorV3Interface`), so a hand-written `IPythV2` matches house convention.
2. The Pyth SDK pulls `PythStructs`, `AbstractPyth`, `IPythEvents`, and `MockPyth` — we need exactly four methods and one struct. A minimal interface eliminates an external lib, its solc-version drift risk, and any transitive `@openzeppelin` remap collisions in `lib/`.
3. `pragma ^0.8.26` is enforced repo-wide; pinning our own file guarantees the version matches. A vendored interface is ABI-compatible with the live Pyth contract (same selectors/struct layout), which is all the EVM call needs.
4. The verified-facts note flags a 2026-07-31 Pyth Core upgrade + API-key requirement; pinning our own thin interface insulates us from any SDK packaging change around that upgrade — only the deployed CONTRACT ADDRESS changes (a constructor arg), not our ABI.

**Files:**
- Create `contracts/src/v2/interfaces/IPythV2.sol`

- [ ] **Step 1: Write the vendored interface**

Create `contracts/src/v2/interfaces/IPythV2.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IPythV2
/// @notice Vendored MINIMAL Pyth interface — only the surface ChainlinkPythAdapterV2
/// needs. ABI-compatible (selectors + struct layout) with the live Pyth contract on
/// Base. Vendored, not imported from @pythnetwork/pyth-sdk-solidity, to match the repo's
/// hand-written IChainlinkAggregator convention and avoid an external lib / solc-drift.
/// @dev On Base mainnet target the UPGRADED (2026-07-31) Pyth Core contract
/// 0xbC16aee60f64864882BC6C4E428e148Fc0E272F5; Sepolia 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83.
interface IPythV2 {
    /// @notice Pyth's price record. `price` and `conf` are scaled by 10**expo (expo is
    /// typically negative, e.g. expo = -8 means price/conf are in 1e-8 units).
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    /// @notice Latest price for `id` WITHOUT a freshness revert. The caller checks
    /// `publishTime` staleness itself. This is the read used by readPrice/peekPrice so
    /// that neither function reverts on a stale feed (fail-closed is signalled via `safe`,
    /// not a revert) and so both share identical control flow (O6 peek==read).
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);

    /// @notice Fee (in wei) required to apply `updateData` via updatePriceFeeds.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    /// @notice Apply pulled Hermes update blobs. PAYABLE. Called ONLY from the adapter's
    /// keeper-facing updatePyth path, NEVER from readPrice/peekPrice.
    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    /// @notice Pyth's own notion of a valid staleness window (seconds); used only as a
    /// sanity reference in tests, not as the adapter's authoritative bound.
    function getValidTimePeriod() external view returns (uint256 validTimePeriod);
}
```

- [ ] **Step 2: Compile-check the interface in isolation**

Run:
```bash
cd contracts && forge fmt && forge build 2>&1 | tail -3
```
Expected: `Compiler run successful` (interface-only, no new errors).

- [ ] **Step 3: Commit**

Run:
```bash
git add contracts/src/v2/interfaces/IPythV2.sol
git commit -m "feat(v2): vendored minimal IPythV2 interface (Price struct + 4 methods)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Settable Chainlink + Pyth mocks

These drive every §14 failure mode without live feeds. Both are settable so a single test can flip one leg stale/negative/diverged while the other stays healthy.

**Files:**
- Create `contracts/test/v2/mocks/MockChainlinkFeed.sol` (check for an existing V1 mock first; if `contracts/test/mocks/MockChainlinkFeedV2.sol` already exists and is settable, the adapter test imports it instead — but create a local one to keep V2 tests self-contained and avoid V1 coupling).
- Create `contracts/test/v2/mocks/MockPyth.sol`

- [ ] **Step 1: Check for a reusable Chainlink mock**

Run:
```bash
cd contracts && ls test/mocks 2>/dev/null; grep -rl "IChainlinkAggregator" test/mocks 2>/dev/null || echo "no V1 settable CL mock — create local"
```
Expected: either a path prints (then read it; if it exposes settable `answer`/`updatedAt`/`decimals`/revert, import it and SKIP Step 2) or `no V1 settable CL mock — create local`. To keep the V2 oracle tests decoupled from V1 mocks, this plan creates a local `MockChainlinkFeed` regardless.

- [ ] **Step 2: Write the Chainlink mock**

Create `contracts/test/v2/mocks/MockChainlinkFeed.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IChainlinkAggregator} from "../../../src/interfaces/IChainlinkAggregator.sol";

/// @title MockChainlinkFeed
/// @notice Fully settable Chainlink aggregator for adapter tests. Every staleness /
/// negative / malformed / revert case is reachable by setters. Defaults to a fresh
/// 8-dec $1.00 round.
contract MockChainlinkFeed is IChainlinkAggregator {
    uint8 internal _decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _roundId;
    uint80 internal _answeredInRound;
    bool internal _revert;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId = 1;
        _answeredInRound = 1;
    }

    function setAnswer(int256 a) external {
        _answer = a;
    }

    function setUpdatedAt(uint256 u) external {
        _updatedAt = u;
    }

    function setRound(uint80 roundId_, uint80 answeredInRound_) external {
        _roundId = roundId_;
        _answeredInRound = answeredInRound_;
    }

    function setRevert(bool r) external {
        _revert = r;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        if (_revert) revert("feed down");
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }
}
```

- [ ] **Step 3: Write the Pyth mock**

Create `contracts/test/v2/mocks/MockPyth.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPythV2} from "../../../src/v2/interfaces/IPythV2.sol";

/// @title MockPyth
/// @notice Settable IPythV2 for adapter tests. Per-id Price is fully settable so a test
/// can drive stale publishTime, negative price, blown confidence, and odd expo. `setRevert`
/// makes getPriceUnsafe revert to prove the adapter's try/catch fail-closes.
contract MockPyth is IPythV2 {
    mapping(bytes32 id => Price) internal _prices;
    bool internal _revert;
    uint256 public updateFee;

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        _prices[id] = Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
    }

    function setRevert(bool r) external {
        _revert = r;
    }

    function setUpdateFee(uint256 f) external {
        updateFee = f;
    }

    function getPriceUnsafe(bytes32 id) external view override returns (Price memory) {
        if (_revert) revert("pyth down");
        return _prices[id];
    }

    function getUpdateFee(bytes[] calldata) external view override returns (uint256) {
        return updateFee;
    }

    /// @dev No-op pull: just refreshes publishTime to block.timestamp for the first id
    /// encoded in updateData[0] (test convenience — tests pass the id as 32 bytes).
    function updatePriceFeeds(bytes[] calldata updateData) external payable override {
        if (updateData.length > 0 && updateData[0].length == 32) {
            bytes32 id = abi.decode(updateData[0], (bytes32));
            _prices[id].publishTime = block.timestamp;
        }
    }

    function getValidTimePeriod() external pure override returns (uint256) {
        return 60;
    }
}
```

- [ ] **Step 4: Compile-check the mocks**

Run:
```bash
cd contracts && forge fmt && forge build 2>&1 | tail -3
```
Expected: `Compiler run successful`.

- [ ] **Step 5: Commit**

Run:
```bash
git add contracts/test/v2/mocks/MockChainlinkFeed.sol contracts/test/v2/mocks/MockPyth.sol
git commit -m "test(v2): settable MockChainlinkFeed + MockPyth for adapter tests

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `ChainlinkPythAdapterV2` — the dual-source adapter

This is the core deliverable. It implements `IOracleAdapterV2` for ONE token and decides `safe` alone (§10/§11). Read the design notes before writing.

**Design encoded here (read before writing):**

Constructor (all immutable except the 4 tunable safety params, which are owner-settable):
- `token` — the token this adapter prices (the Pool passes `token` to `readPrice(token)`; the adapter validates it equals its own `TOKEN` and reverts `WrongToken` otherwise, so one adapter can never silently answer for the wrong asset).
- `chainlinkFeed` (`IChainlinkAggregator`), `pyth` (`IPythV2`), `pythPriceId` (`bytes32`).
- `chainlinkMaxStaleSeconds` — must tolerate the verified 24h (86400s) heartbeat on Base stables. Deploy table sets a margin above 86400 (e.g. 90000) so a feed updating exactly at heartbeat isn't flagged.
- `pythMaxStaleSeconds` — tighter (Pyth is push/pull, sub-second capable; deploy table uses 60–120s after a keeper pull).
- `pythMaxConfBps` — confidence-ratio cap: reject when `conf / price > pythMaxConfBps/10000`.
- `maxDivergenceBps` — cross-source divergence cap (measured against the lower of the two 1e18 prices, matching the V1 `OracleAggregator` I-5 convention).

Normalization to 1e18 (both legs):
```text
Chainlink: clDec = chainlinkFeed.decimals()  (8 on Base)
           cl1e18 = uint256(answer) * 10**(18 - clDec)        // clDec <= 18 guaranteed at deploy
Pyth:      p = price.price (int64, must be > 0)
           expo = price.expo (int32; e.g. -8)
           if expo <= 0:  py1e18 = uint256(uint64(p)) * 10**(18 + expo)     // 18+expo in [0,18]
           else:          py1e18 = uint256(uint64(p)) * 10**(18 + expo)     // expo>0 extremely rare; still scales up
           confidence is in the same expo units; compare conf*price-ratio in raw units (no 1e18 needed):
           confBps = conf * 10000 / uint64(p)    // ratio in bps; independent of expo
```
Guard the Pyth exponent: reject (unsafe) if `expo < -18` or `expo > 18` (would over/underflow the `10**` scale) — a malformed-expo case (§14 "expo-edge").

Per-leg validity (each leg returns `(ok, price1e18)`; `ok==false` ⇒ that leg failed):
- Chainlink leg `ok` requires (inside try/catch): `answer > 0`, `updatedAt > 0`, `roundId != 0`, `answeredInRound >= roundId`, and `block.timestamp <= updatedAt + chainlinkMaxStaleSeconds`. (Same five checks as V1 `OracleAggregator._tryRead`, reused intentionally.)
- Pyth leg `ok` requires (inside try/catch): `price.price > 0`, `price.publishTime > 0`, `-18 <= expo <= 18`, `block.timestamp <= publishTime + pythMaxStaleSeconds`, and confidence `conf * 10000 <= uint64(price) * pythMaxConfBps` (i.e. `confBps <= pythMaxConfBps`).

Safe decision (§10/§11) in `_compute()` (a `view` internal that BOTH `readPrice` and `peekPrice` call — guaranteeing peek==read, O6):
```text
(clOk, cl1e18) = _readChainlink()
(pyOk, py1e18) = _readPyth()
if (!clOk || !pyOk):           return (displayPrice, false)   // single-source or any bad leg ⇒ UNSAFE
// both legs ok — divergence check against the lower price (V1 I-5 convention)
lo  = min(cl1e18, py1e18)
diff = cl1e18 > py1e18 ? cl1e18 - py1e18 : py1e18 - cl1e18
if (diff * 10000 > lo * maxDivergenceBps):   return (mid, false)   // diverged ⇒ UNSAFE
mid = (cl1e18 + py1e18) / 2
return (mid, true)                                             // SAFE
```
Where `displayPrice` when a leg is bad = whichever leg IS ok (for §11 display context) else `lastSafePrice1e18` (the cache) else 0. Crucially the returned price when `safe==false` is NEVER used by the Pool to authorize a transfer — the Pool gates on `safe`. The mid-price is returned only when safe.

`readPrice` vs `peekPrice` (O6 — peek==read within a block):
- `peekPrice(token)` is `view`: validates `token == TOKEN`, returns `_compute()`.
- `readPrice(token)` is non-view ONLY so it can write the `lastSafePrice1e18` cache for display/alerts. It calls the SAME `_compute()`, and if `safe` it stores `price` into the cache. It returns the SAME tuple `_compute()` produced. Because `_compute()` is a pure function of current feed state (no pull-update, no time-warp), `readPrice` and `peekPrice` return identical `(price, safe)` in the same block. **No Pyth pull happens in `readPrice`** — that is the entire reason the cache write is the only side effect. This is the documented O6 guarantee.

`updatePyth(bytes[] calldata updateData)` (keeper path, NOT reached by read/peek):
- `payable`; computes `fee = pyth.getUpdateFee(updateData)`, requires `msg.value >= fee`, forwards `fee` to `pyth.updatePriceFeeds{value: fee}(updateData)`, refunds the remainder to `msg.sender`. This is the ONLY function that mutates Pyth state. Quotes (`peekPrice`) and execution (`readPrice`) read whatever the last keeper pull left — identical for both within a block.

Governance setters (`Ownable2Step`, owner = Timelock): `setMaxDivergenceBps`, `setChainlinkMaxStaleSeconds`, `setPythMaxStaleSeconds`, `setPythMaxConfBps`, each bounded-validated and event-emitting. Feeds/IDs/token are immutable (no setter).

**Files:**
- Create `contracts/src/v2/ChainlinkPythAdapterV2.sol`

- [ ] **Step 1: Write the adapter**

Create `contracts/src/v2/ChainlinkPythAdapterV2.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IOracleAdapterV2} from "./interfaces/IOracleAdapterV2.sol";
import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";
import {IPythV2} from "./interfaces/IPythV2.sol";

/// @title ChainlinkPythAdapterV2
/// @notice Per-token IOracleAdapterV2: dual-source (Chainlink primary + Pyth secondary)
/// token/USD oracle normalized to 1e18. The ADAPTER alone decides `safe` per spec
/// §10/§11 — both legs must be fresh, valid, within Pyth confidence, and within
/// cross-source divergence; a single surviving leg, a stale/invalid/malformed read, or
/// excess divergence ⇒ `safe == false` (fail-closed). `peekPrice` and `readPrice` return
/// the SAME tuple for a given block (O6): both delegate to a pure-of-state `_compute`,
/// and `readPrice`'s only side effect is updating a display cache — it never pulls Pyth.
/// Pyth pull-updates are isolated in `updatePyth` (keeper path), never reached by reads.
contract ChainlinkPythAdapterV2 is IOracleAdapterV2, Ownable2Step {
    uint256 internal constant BPS = 10_000;

    // ── Immutable wiring ────────────────────────────────────────────────
    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    address public immutable TOKEN;
    // slither-disable-next-line naming-convention
    IChainlinkAggregator public immutable CHAINLINK_FEED;
    // slither-disable-next-line naming-convention
    IPythV2 public immutable PYTH;
    // slither-disable-next-line naming-convention
    bytes32 public immutable PYTH_PRICE_ID;
    // slither-disable-next-line naming-convention
    uint8 public immutable CHAINLINK_DECIMALS;

    // ── Tunable safety params (owner = Timelock) ────────────────────────
    uint32 public chainlinkMaxStaleSeconds;
    uint32 public pythMaxStaleSeconds;
    uint16 public pythMaxConfBps;
    uint16 public maxDivergenceBps;

    // ── §11 display cache (NEVER authorizes a transfer) ─────────────────
    uint256 public lastSafePrice1e18;
    uint256 public lastSafeAt;

    // ── Errors ──────────────────────────────────────────────────────────
    error ZeroAddress();
    error WrongToken(address requested, address expected);
    error ChainlinkDecimalsTooLarge(uint8 decimals);
    error InvalidStaleSeconds(uint32 v);
    error InvalidConfBps(uint16 v);
    error InvalidDivergenceBps(uint16 v);
    error InsufficientUpdateFee(uint256 sent, uint256 required);
    error RefundFailed();

    // ── Events ──────────────────────────────────────────────────────────
    event ChainlinkMaxStaleUpdated(uint32 oldValue, uint32 newValue);
    event PythMaxStaleUpdated(uint32 oldValue, uint32 newValue);
    event PythMaxConfBpsUpdated(uint16 oldValue, uint16 newValue);
    event MaxDivergenceBpsUpdated(uint16 oldValue, uint16 newValue);
    event SafePriceCached(uint256 price1e18, uint256 at);
    event PythUpdated(address indexed keeper, uint256 fee);

    constructor(
        address token_,
        IChainlinkAggregator chainlinkFeed_,
        IPythV2 pyth_,
        bytes32 pythPriceId_,
        uint32 chainlinkMaxStaleSeconds_,
        uint32 pythMaxStaleSeconds_,
        uint16 pythMaxConfBps_,
        uint16 maxDivergenceBps_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (token_ == address(0) || address(chainlinkFeed_) == address(0) || address(pyth_) == address(0)) {
            revert ZeroAddress();
        }
        if (chainlinkMaxStaleSeconds_ == 0) revert InvalidStaleSeconds(chainlinkMaxStaleSeconds_);
        if (pythMaxStaleSeconds_ == 0) revert InvalidStaleSeconds(pythMaxStaleSeconds_);
        if (pythMaxConfBps_ == 0 || pythMaxConfBps_ > BPS) revert InvalidConfBps(pythMaxConfBps_);
        if (maxDivergenceBps_ == 0 || maxDivergenceBps_ > BPS) revert InvalidDivergenceBps(maxDivergenceBps_);

        uint8 clDec = chainlinkFeed_.decimals();
        if (clDec > 18) revert ChainlinkDecimalsTooLarge(clDec);

        TOKEN = token_;
        CHAINLINK_FEED = chainlinkFeed_;
        PYTH = pyth_;
        PYTH_PRICE_ID = pythPriceId_;
        CHAINLINK_DECIMALS = clDec;
        chainlinkMaxStaleSeconds = chainlinkMaxStaleSeconds_;
        pythMaxStaleSeconds = pythMaxStaleSeconds_;
        pythMaxConfBps = pythMaxConfBps_;
        maxDivergenceBps = maxDivergenceBps_;
    }

    // ── IOracleAdapterV2 ────────────────────────────────────────────────

    /// @inheritdoc IOracleAdapterV2
    function peekPrice(address token) external view override returns (uint256 price1e18, bool safe) {
        if (token != TOKEN) revert WrongToken(token, TOKEN);
        (price1e18, safe) = _compute();
    }

    /// @inheritdoc IOracleAdapterV2
    /// @dev Non-view ONLY to refresh the §11 display cache. Returns the SAME tuple as
    /// peekPrice in the same block (O6). No Pyth pull occurs here.
    function readPrice(address token) external override returns (uint256 price1e18, bool safe) {
        if (token != TOKEN) revert WrongToken(token, TOKEN);
        (price1e18, safe) = _compute();
        if (safe) {
            lastSafePrice1e18 = price1e18;
            lastSafeAt = block.timestamp;
            emit SafePriceCached(price1e18, block.timestamp);
        }
    }

    /// @notice Keeper-only Pyth pull. ISOLATED from read/peek so quotes==execution within
    /// a block. Forwards the Pyth fee and refunds the remainder.
    function updatePyth(bytes[] calldata updateData) external payable {
        uint256 fee = PYTH.getUpdateFee(updateData);
        if (msg.value < fee) revert InsufficientUpdateFee(msg.value, fee);
        PYTH.updatePriceFeeds{value: fee}(updateData);
        emit PythUpdated(msg.sender, fee);
        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    // ── Internal dual-source compute (shared by read + peek) ────────────

    /// @dev The ONE safety+price computation. Pure function of current feed state; no
    /// side effects. Returns the mid-price + true only when BOTH legs are fresh/valid,
    /// Pyth confidence is within bound, and divergence is within bound. Otherwise returns
    /// a best-effort display price (surviving leg, else cache, else 0) and false.
    function _compute() internal view returns (uint256 price1e18, bool safe) {
        (bool clOk, uint256 cl1e18) = _readChainlink();
        (bool pyOk, uint256 py1e18) = _readPyth();

        if (!clOk || !pyOk) {
            // Single-source / bad leg ⇒ UNSAFE (§10: a single surviving source is insufficient).
            uint256 display = clOk ? cl1e18 : (pyOk ? py1e18 : lastSafePrice1e18);
            return (display, false);
        }

        uint256 lo = cl1e18 < py1e18 ? cl1e18 : py1e18;
        uint256 diff = cl1e18 > py1e18 ? cl1e18 - py1e18 : py1e18 - cl1e18;
        uint256 mid = (cl1e18 + py1e18) / 2;
        if (diff * BPS > lo * maxDivergenceBps) {
            return (mid, false); // diverged ⇒ UNSAFE (display the mid for context)
        }
        return (mid, true);
    }

    /// @dev Chainlink leg → (ok, price1e18). Same five validity checks as V1 OracleAggregator.
    function _readChainlink() internal view returns (bool ok, uint256 price1e18) {
        // Justification [unused-return]: startedAt (3rd field) carries no staleness info.
        // slither-disable-next-line unused-return
        try CHAINLINK_FEED.latestRoundData() returns (uint80 r, int256 a, uint256, uint256 u, uint80 air) {
            if (a > 0 && u > 0 && r != 0 && air >= r && block.timestamp <= u + chainlinkMaxStaleSeconds) {
                // CHAINLINK_DECIMALS <= 18 (constructor-guaranteed) ⇒ scale up to 1e18.
                return (true, uint256(a) * (10 ** (18 - CHAINLINK_DECIMALS)));
            }
            return (false, 0);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Pyth leg → (ok, price1e18). Validates positive price, fresh publishTime,
    /// expo in [-18, 18], and confidence ratio within bound.
    function _readPyth() internal view returns (bool ok, uint256 price1e18) {
        try PYTH.getPriceUnsafe(PYTH_PRICE_ID) returns (IPythV2.Price memory p) {
            if (p.price <= 0 || p.publishTime == 0) return (false, 0);
            if (p.expo < -18 || p.expo > 18) return (false, 0); // malformed-expo (§14 expo-edge)
            if (block.timestamp > p.publishTime + pythMaxStaleSeconds) return (false, 0);
            uint256 rawPrice = uint256(uint64(p.price));
            // Confidence ratio in bps; expo cancels (conf and price share expo).
            if (uint256(p.conf) * BPS > rawPrice * pythMaxConfBps) return (false, 0);
            int256 scaleExp = int256(18) + int256(p.expo); // in [0, 36]
            uint256 scaled = scaleExp >= 0
                ? rawPrice * (10 ** uint256(scaleExp))
                : rawPrice / (10 ** uint256(-scaleExp));
            return (true, scaled);
        } catch {
            return (false, 0);
        }
    }

    // ── Governance setters (owner = Timelock) ───────────────────────────

    function setChainlinkMaxStaleSeconds(uint32 v) external onlyOwner {
        if (v == 0) revert InvalidStaleSeconds(v);
        emit ChainlinkMaxStaleUpdated(chainlinkMaxStaleSeconds, v);
        chainlinkMaxStaleSeconds = v;
    }

    function setPythMaxStaleSeconds(uint32 v) external onlyOwner {
        if (v == 0) revert InvalidStaleSeconds(v);
        emit PythMaxStaleUpdated(pythMaxStaleSeconds, v);
        pythMaxStaleSeconds = v;
    }

    function setPythMaxConfBps(uint16 v) external onlyOwner {
        if (v == 0 || v > BPS) revert InvalidConfBps(v);
        emit PythMaxConfBpsUpdated(pythMaxConfBps, v);
        pythMaxConfBps = v;
    }

    function setMaxDivergenceBps(uint16 v) external onlyOwner {
        if (v == 0 || v > BPS) revert InvalidDivergenceBps(v);
        emit MaxDivergenceBpsUpdated(maxDivergenceBps, v);
        maxDivergenceBps = v;
    }
}
```

Repo-gotcha notes encoded above:
- **Non-ASCII in string literals** — none of this contract's revert strings or comments use a literal `§`/`≈`/`✓` inside a `"..."` string. The NatSpec comments use `§` only in `///` comment lines (not string literals), which `solc`/`forge fmt` accept. Any test or doc that needs `§`/`�≈` INSIDE a Solidity string literal MUST use `unicode"..."` (see Task 4 — the test reuses the `unicode"…(§11)"` convention already in `MockOracleAdapterV2.t.sol`).
- **Stack-too-deep** — `_compute`, `_readChainlink`, `_readPyth` are deliberately split so no single function holds both legs' full locals; this mirrors the V1 `OracleAggregator._combineSources` split. If a future edit inlines them and triggers `Stack too deep`, re-extract the leg readers (the minimal documented split).

- [ ] **Step 2: Compile-check the adapter**

Run:
```bash
cd contracts && forge fmt && forge build 2>&1 | tail -3
```
Expected: `Compiler run successful`. If `Stack too deep` appears, confirm the three internal helpers were not inlined (re-extract them).

- [ ] **Step 3: Commit**

Run:
```bash
git add contracts/src/v2/ChainlinkPythAdapterV2.sol
git commit -m "feat(v2): ChainlinkPythAdapterV2 — dual-source fail-closed IOracleAdapterV2

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Adapter unit tests (§14 oracle cases)

Covers §14's "oracle stale, confidence, divergence, revert, and malformed-data cases" and "fail-closed behavior when only one oracle source survives" for the REAL adapter, plus normalization and O6 peek==read parity.

**Files:**
- Create `contracts/test/v2/ChainlinkPythAdapterV2.t.sol`

- [ ] **Step 1: Write the failing test suite**

Create `contracts/test/v2/ChainlinkPythAdapterV2.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPythAdapterV2} from "../../src/v2/ChainlinkPythAdapterV2.sol";
import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";
import {IPythV2} from "../../src/v2/interfaces/IPythV2.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract ChainlinkPythAdapterV2Test is Test {
    ChainlinkPythAdapterV2 adapter;
    MockChainlinkFeed cl;
    MockPyth pyth;

    address token = makeAddr("USDC");
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    bytes32 constant PID = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    uint32 constant CL_STALE = 90_000; // > 86400 heartbeat (verified mainnet)
    uint32 constant PY_STALE = 120;
    uint16 constant CONF_BPS = 50; // 0.50% confidence cap
    uint16 constant DIV_BPS = 50; // 0.50% divergence cap

    function setUp() public {
        cl = new MockChainlinkFeed(8, 1e8); // $1.00 at 8 dec
        pyth = new MockPyth();
        pyth.setPrice(PID, 100_000_000, 100_000, -8, block.timestamp); // $1.00, conf 0.001, expo -8
        adapter = new ChainlinkPythAdapterV2(
            token, IChainlinkAggregator(address(cl)), IPythV2(address(pyth)), PID, CL_STALE, PY_STALE, CONF_BPS, DIV_BPS, owner
        );
    }

    // ── Happy path + normalization ──────────────────────────────────────
    function test_both_fresh_safe_and_normalized_1e18() public {
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertTrue(safe, "both fresh => safe");
        // CL $1.00 (1e18) and Pyth $1.00 (1e18) => mid 1e18.
        assertEq(p, 1e18, "normalized to 1e18");
    }

    function test_wrongToken_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPythAdapterV2.WrongToken.selector, makeAddr("other"), token)
        );
        adapter.peekPrice(makeAddr("other"));
    }

    // ── O6: peek == read within a block ─────────────────────────────────
    function test_peek_equals_read_same_block() public {
        (uint256 rp, bool rs) = adapter.readPrice(token);
        (uint256 pp, bool ps) = adapter.peekPrice(token);
        assertEq(rp, pp, "price parity");
        assertEq(rs, ps, "safe parity");
        // read cached the safe price for display (§11), but returned the same tuple.
        assertEq(adapter.lastSafePrice1e18(), rp, unicode"§11 display cache set on safe read");
    }

    // ── Per-source staleness ────────────────────────────────────────────
    function test_chainlink_stale_is_unsafe() public {
        cl.setUpdatedAt(block.timestamp - CL_STALE - 1);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "CL beyond stale window => unsafe");
    }

    function test_chainlink_tolerates_24h_heartbeat() public {
        // A feed updated exactly 86400s ago is still fresh (window 90000).
        cl.setUpdatedAt(block.timestamp - 86_400);
        (, bool safe) = adapter.peekPrice(token);
        assertTrue(safe, unicode"must tolerate the verified 24h heartbeat");
    }

    function test_pyth_stale_is_unsafe() public {
        pyth.setPrice(PID, 100_000_000, 100_000, -8, block.timestamp - PY_STALE - 1);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "Pyth beyond stale window => unsafe");
    }

    // ── Pyth confidence-ratio bound ─────────────────────────────────────
    function test_pyth_confidence_over_bound_is_unsafe() public {
        // conf 0.6% of price > 0.50% cap.
        pyth.setPrice(PID, 100_000_000, 600_000, -8, block.timestamp);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "blown confidence => unsafe");
    }

    function test_pyth_confidence_at_bound_is_safe() public {
        // conf exactly 0.50% (== cap, not over).
        pyth.setPrice(PID, 100_000_000, 500_000, -8, block.timestamp);
        (, bool safe) = adapter.peekPrice(token);
        assertTrue(safe, "confidence at cap is allowed");
    }

    // ── Cross-source divergence ─────────────────────────────────────────
    function test_divergence_over_bound_is_unsafe() public {
        // CL $1.00, Pyth $1.006 => 0.6% > 0.50% cap.
        pyth.setPrice(PID, 100_600_000, 100_000, -8, block.timestamp);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "diverged sources => unsafe");
    }

    function test_divergence_within_bound_is_safe() public {
        // Pyth $1.004 => 0.4% < 0.50% cap.
        pyth.setPrice(PID, 100_400_000, 100_000, -8, block.timestamp);
        (, bool safe) = adapter.peekPrice(token);
        assertTrue(safe, "within divergence => safe");
    }

    // ── Zero / negative / malformed ─────────────────────────────────────
    function test_chainlink_negative_is_unsafe() public {
        cl.setAnswer(-1);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
    }

    function test_chainlink_zero_is_unsafe() public {
        cl.setAnswer(0);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
    }

    function test_pyth_negative_is_unsafe() public {
        pyth.setPrice(PID, -100_000_000, 100_000, -8, block.timestamp);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
    }

    function test_pyth_malformed_expo_is_unsafe() public {
        pyth.setPrice(PID, 100_000_000, 100_000, -19, block.timestamp); // expo < -18
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "out-of-range expo => unsafe");
    }

    function test_pyth_positive_expo_normalizes() public {
        // price 1 with expo +0 (==$1) just to exercise the expo>=0 branch; keep CL at $1.
        pyth.setPrice(PID, 1, 0, 0, block.timestamp); // conf 0 ok; price 1 * 10**18 = 1e18
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertTrue(safe);
        assertEq(p, 1e18);
    }

    // ── Reverting legs fail closed ──────────────────────────────────────
    function test_chainlink_revert_is_unsafe() public {
        cl.setRevert(true);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "CL revert caught => unsafe");
    }

    function test_pyth_revert_is_unsafe() public {
        pyth.setRevert(true);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "Pyth revert caught => unsafe");
    }

    // ── Single-source ⇒ unsafe (both directions) ────────────────────────
    function test_only_chainlink_alive_is_unsafe() public {
        pyth.setRevert(true);
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "single surviving source insufficient (§10)");
        assertEq(p, 1e18, "surviving CL price shown for display only");
    }

    function test_only_pyth_alive_is_unsafe() public {
        cl.setRevert(true);
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
        assertEq(p, 1e18, "surviving Pyth price shown for display only");
    }

    // ── §11: last price retained while unsafe, never re-flagged safe ─────
    function test_last_price_retained_while_unsafe() public {
        adapter.readPrice(token); // cache 1e18 while safe
        cl.setRevert(true); // now unsafe
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
        // display falls back to surviving Pyth leg here; cache still queryable.
        assertEq(adapter.lastSafePrice1e18(), 1e18, unicode"last safe price retained (§11)");
        assertEq(p, 1e18);
    }

    // ── Roundness checks (incomplete round) ─────────────────────────────
    function test_chainlink_incomplete_round_is_unsafe() public {
        cl.setRound(5, 4); // answeredInRound < roundId
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
    }

    // ── updatePyth isolation + fee/refund ───────────────────────────────
    function test_updatePyth_forwards_fee_and_refunds() public {
        pyth.setUpdateFee(0.001 ether);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(PID);
        vm.deal(keeper, 1 ether);
        uint256 before = keeper.balance;
        vm.prank(keeper);
        adapter.updatePyth{value: 0.01 ether}(data);
        // Spent exactly the fee; remainder refunded.
        assertEq(before - keeper.balance, 0.001 ether, "only the fee is spent");
    }

    function test_updatePyth_insufficient_fee_reverts() public {
        pyth.setUpdateFee(0.01 ether);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(PID);
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPythAdapterV2.InsufficientUpdateFee.selector, 0.001 ether, 0.01 ether)
        );
        adapter.updatePyth{value: 0.001 ether}(data);
    }

    function test_updatePyth_does_not_affect_read_in_same_block() public {
        // Drive Pyth stale, then a pull refreshes publishTime; peek BEFORE pull is unsafe,
        // AFTER pull is safe — but read/peek themselves never pull (O6).
        pyth.setPrice(PID, 100_000_000, 100_000, -8, block.timestamp - PY_STALE - 1);
        (, bool beforePull) = adapter.peekPrice(token);
        assertFalse(beforePull, "stale Pyth, no pull in peek");
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(PID);
        adapter.updatePyth(data); // keeper pull bumps publishTime
        (uint256 rp, bool rs) = adapter.readPrice(token);
        (uint256 pp, bool ps) = adapter.peekPrice(token);
        assertEq(rp, pp);
        assertEq(rs, ps, "peek==read still holds after an external pull");
        assertTrue(rs, "fresh after the keeper pull");
    }

    // ── Governance setters ──────────────────────────────────────────────
    function test_setters_onlyOwner() public {
        vm.expectRevert();
        adapter.setMaxDivergenceBps(100);
        vm.prank(owner);
        adapter.setMaxDivergenceBps(100);
        assertEq(adapter.maxDivergenceBps(), 100);
    }

    function test_constructor_rejects_bad_params() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPythAdapterV2.InvalidConfBps.selector, uint16(0)));
        new ChainlinkPythAdapterV2(
            token, IChainlinkAggregator(address(cl)), IPythV2(address(pyth)), PID, CL_STALE, PY_STALE, 0, DIV_BPS, owner
        );
    }
}
```

- [ ] **Step 2: Run it (expect green — adapter + mocks already written)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ChainlinkPythAdapterV2.t.sol" 2>&1 | tail -10
```
Expected: all tests pass (≈24 cases, `0 failed`). If `test_pyth_confidence_at_bound_is_safe` fails, the bound comparison is off-by-one — confirm the rule is `conf*BPS <= price*confBps` (at-cap allowed), not `<`. If `test_divergence_within_bound_is_safe` flips, confirm the divergence rule is `diff*BPS > lo*divBps` ⇒ unsafe (strict greater-than).

- [ ] **Step 3: Commit**

Run:
```bash
git add contracts/test/v2/ChainlinkPythAdapterV2.t.sol
git commit -m "test(v2): ChainlinkPythAdapterV2 unit suite (§14 stale/conf/divergence/expo/single-source/O6)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Base-mainnet fork test (skippable without RPC)

Validates the adapter against the REAL verified mainnet Chainlink proxies + the real Pyth contract/IDs. Skips cleanly when no RPC is configured so default CI stays green.

**Files:**
- Create `contracts/test/v2/ChainlinkPythAdapterV2.fork.t.sol`
- Edit `contracts/foundry.toml` to add a `base_mainnet` rpc endpoint (env-driven, like the existing `arc_testnet`).

- [ ] **Step 1: Add the rpc endpoint mapping**

Edit `contracts/foundry.toml` — under `[rpc_endpoints]`, add a line so `vm.rpcUrl("base_mainnet")` resolves from env (mirrors the existing `arc_testnet` pattern):
```toml
[rpc_endpoints]
arc_testnet = "${ARC_TESTNET_RPC}"
base_mainnet = "${BASE_MAINNET_RPC}"
```
(No other foundry.toml change. The fork test reads `BASE_MAINNET_RPC` directly via `vm.envOr` and skips if empty, so a missing endpoint never breaks `forge test`.)

- [ ] **Step 2: Write the fork test**

Create `contracts/test/v2/ChainlinkPythAdapterV2.fork.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPythAdapterV2} from "../../src/v2/ChainlinkPythAdapterV2.sol";
import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";
import {IPythV2} from "../../src/v2/interfaces/IPythV2.sol";

/// @notice Base-MAINNET fork test against the verified (2026-06-10) feeds. Skips when
/// BASE_MAINNET_RPC is unset so default CI never needs an RPC. Run with:
///   BASE_MAINNET_RPC=<url> forge test --match-path "test/v2/ChainlinkPythAdapterV2.fork.t.sol"
contract ChainlinkPythAdapterV2ForkTest is Test {
    // Verified Base mainnet (8453) Chainlink proxies (8 dec, 86400s heartbeat).
    address constant CL_USDC = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant CL_EURC = 0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250;
    address constant CL_USDT = 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9;
    // Pyth UPGRADED Core (2026-07-31) contract on Base mainnet.
    address constant PYTH = 0xbC16aee60f64864882BC6C4E428e148Fc0E272F5;
    // Verified Pyth feed IDs.
    bytes32 constant PID_USDC = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PID_EURC = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;
    bytes32 constant PID_USDT = 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b;

    address owner = makeAddr("owner");
    address token = makeAddr("token"); // arbitrary — fork test only exercises the read path

    function _maybeFork() internal returns (bool) {
        string memory url = vm.envOr("BASE_MAINNET_RPC", string(""));
        if (bytes(url).length == 0) {
            emit log("BASE_MAINNET_RPC unset — skipping fork test");
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(url);
        return true;
    }

    function _deploy(address clFeed, bytes32 pid) internal returns (ChainlinkPythAdapterV2) {
        // Wide windows so a live-but-slow feed still reads safe at fork time. Pyth on a
        // bare fork has NO recent pull (publishTime old) → expect Pyth-stale ⇒ unsafe is
        // acceptable; we assert the CHAINLINK leg and normalization, and that read==peek.
        return new ChainlinkPythAdapterV2(
            token,
            IChainlinkAggregator(clFeed),
            IPythV2(PYTH),
            pid,
            90_000, // CL stale window > 24h heartbeat
            type(uint32).max, // Pyth window wide so a stale-on-fork pull doesn't dominate the assertion
            500, // 5% conf cap (loose for fork)
            500, // 5% divergence cap (loose for fork)
            owner
        );
    }

    function _assertLiveStable(address clFeed, bytes32 pid) internal {
        ChainlinkPythAdapterV2 a = _deploy(clFeed, pid);
        (uint256 rp, bool rs) = a.readPrice(token);
        (uint256 pp, bool ps) = a.peekPrice(token);
        assertEq(rp, pp, "O6 peek==read on fork");
        assertEq(rs, ps, "O6 safe parity on fork");
        // Whatever the safe verdict, the returned price must be a plausible ~$1 (or ~$1.15
        // for EURC) 1e18 value when at least one leg answered.
        if (rp > 0) {
            assertGt(rp, 0.5e18, "price sane lower bound");
            assertLt(rp, 2e18, "price sane upper bound");
        }
        emit log_named_uint("price1e18", rp);
        emit log_named_uint("safe", rs ? 1 : 0);
    }

    function test_fork_usdc() public {
        if (!_maybeFork()) return;
        _assertLiveStable(CL_USDC, PID_USDC);
    }

    function test_fork_eurc() public {
        if (!_maybeFork()) return;
        _assertLiveStable(CL_EURC, PID_EURC);
    }

    function test_fork_usdt() public {
        if (!_maybeFork()) return;
        _assertLiveStable(CL_USDT, PID_USDT);
    }
}
```
Note: on a bare fork, Pyth's last on-chain `publishTime` may be older than a tight window, so a strict `safe==true` is NOT asserted — the fork test proves (a) the Chainlink leg reads + normalizes against the REAL proxy, (b) O6 peek==read holds on real bytecode, and (c) the price is in a sane band. A keeper-pull-on-fork variant (calling `updatePyth` with a Hermes blob via FFI) is left for the deploy/monitoring plan.

- [ ] **Step 3: Run it skipped (default — no RPC)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ChainlinkPythAdapterV2.fork.t.sol" 2>&1 | tail -8
```
Expected: 3 tests, all SKIPPED (`[SKIP]`), `0 failed`. The `vm.skip(true)` after the env check makes each a clean skip.

- [ ] **Step 4: (Optional, manual) Run it forked**

If a Base archive/full RPC is available:
```bash
cd contracts && BASE_MAINNET_RPC=<url> forge test --match-path "test/v2/ChainlinkPythAdapterV2.fork.t.sol" -vv 2>&1 | tail -20
```
Expected: 3 tests pass; logs print each `price1e18` (USDC≈1.0e18, EURC≈1.15e18, USDT≈1.0e18) and `safe` (1 if the live Pyth publishTime is within the wide window, else 0 — both acceptable per the note).

- [ ] **Step 5: Commit**

Run:
```bash
git add contracts/foundry.toml contracts/test/v2/ChainlinkPythAdapterV2.fork.t.sol
git commit -m "test(v2): Base-mainnet fork test for ChainlinkPythAdapterV2 (skippable w/o RPC)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Per-token deploy-config table (mainnet + Sepolia incl. EURC mock leg)

The deploy-config table is a DOCUMENT deliverable (the deploy script is a later plan). It pins exact constructor args per token per network so the future `DeployOracleAdaptersV2.s.sol` is a transcription, not a research, task.

**Files:**
- Edit this plan file (append the table below as a permanent section). No contract change.

- [ ] **Step 1: Record the table in this plan (already inlined — verify it matches `docs/research/2026-06-10-base-oracle-feeds.md`)**

#### Base mainnet (chainId 8453) — production

| Token | `token` | `chainlinkFeed` | `pyth` | `pythPriceId` | `chainlinkMaxStaleSeconds` | `pythMaxStaleSeconds` | `pythMaxConfBps` | `maxDivergenceBps` |
|---|---|---|---|---|---|---|---|---|
| USDC | (prod USDC) | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | `0xbC16aee60f64864882BC6C4E428e148Fc0E272F5` | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` | `90000` | `60` | `30` | `50` |
| EURC | (prod EURC) | `0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250` | `0xbC16aee60f64864882BC6C4E428e148Fc0E272F5` | `0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c` | `90000` | `60` | `40` | `60` |
| USDT | (prod USDT) | `0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9` | `0xbC16aee60f64864882BC6C4E428e148Fc0E272F5` | `0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b` | `90000` | `60` | `30` | `50` |

Rationale for the params:
- `chainlinkMaxStaleSeconds = 90000` (> the verified 86400s heartbeat, with ~3600s margin) for all three.
- `pythMaxStaleSeconds = 60` assumes a keeper calls `updatePyth` at least each minute before quotes/execution; loosen to 120 if the keeper cadence is slower (a monitoring-plan knob).
- `pythMaxConfBps`: USDC/USDT 30 (0.30%), EURC 40 (0.40%) — EURC's live conf (±0.001545 on ~1.155 ≈ 13bps) and stables (~7bps) sit well under these; the cap catches a confidence blow-out, not normal noise.
- `maxDivergenceBps`: 50 (0.50%) stables, 60 (0.60%) EURC — comfortably above the verified CL-vs-Pyth gap (sub-1bp at check time) while still tripping on a real depeg/disagreement.
- All four are owner-settable post-deploy via Timelock, so these are launch defaults, not frozen forever.

#### Base Sepolia (chainId 84532) — testnet

| Token | `chainlinkFeed` | `pyth` | `pythPriceId` | `chainlinkMaxStaleSeconds` | `pythMaxStaleSeconds` | Notes |
|---|---|---|---|---|---|---|
| USDC | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` | `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83` | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` | `2592000` (30d) | `86400` | USDC feed observed ~8d stale → **very lenient** window or use a MockChainlinkFeed leg |
| USDT | `0x3ec8593F930EA45ea58c968260e6e9FF53FC934f` | `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83` | `0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b` | `604800` (7d) | `86400` | fresh feed; still wide for testnet |
| EURC | **`MockChainlinkFeed` (deploy a stub)** | `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83` | `0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c` | `604800` (7d) | `86400` | **No Chainlink EURC on Sepolia** → deploy a `MockChainlinkFeed(8, 1.15e8)` (or a keeper-set stub) as the Chainlink leg so the adapter still has TWO sources; THIS IS A TESTNET-ONLY WORKAROUND, never on mainnet. Mainnet EURC uses the real direct CL proxy above. |

Testnet EURC mock-leg procedure (record in the deploy plan):
1. Deploy `MockChainlinkFeed(8, 115000000)` (= $1.15, 8 dec) on Sepolia, owned by the test operator.
2. Construct the EURC adapter with that mock address as `chainlinkFeed`.
3. A simple keeper/script periodically calls `setAnswer` / `setUpdatedAt` to keep the mock leg fresh and roughly tracking the real EUR/USD (or just hold ~1.15 for functional testing).
4. Document explicitly in the deploy runbook that the Sepolia EURC adapter is dual-source ONLY via this mock — it does NOT satisfy the §15 "two verified independent direct sources" acceptance gate, which applies to MAINNET. Testnet is for flow/drill validation, not the production admission proof.

- [ ] **Step 2: Cross-check the table against the research note (no drift)**

Run:
```bash
cd /Users/huseyinarslan/Desktop/arcoradex/arcoradex && grep -o "0x7e860098F58bBFC8648a4311b374B1D669a2bc6B\|0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250\|0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9\|0xbC16aee60f64864882BC6C4E428e148Fc0E272F5\|0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c" docs/research/2026-06-10-base-oracle-feeds.md | sort -u | wc -l
```
Expected: `5` (all five mainnet anchor addresses/IDs appear verbatim in the research note). If fewer, an address drifted — fix the table to match the research note.

- [ ] **Step 3: Commit the plan/table update**

Run:
```bash
git add docs/superpowers/plans/2026-06-10-base-v2-oracle-adapters.md contracts/foundry.toml
git commit -m "docs(v2): per-token oracle-adapter deploy-config table (mainnet + Sepolia EURC mock leg)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
(If `foundry.toml` was already committed in Task 5, this commit is plan-only — fine.)

---

### Task 7: Full suite, fmt gate, placeholder scan

**Files:** none modified; verification only.

- [ ] **Step 1: `forge fmt --check` (CI gate)**

Run:
```bash
cd contracts && forge fmt --check 2>&1 | tail -5
```
Expected: no diff output (exit 0). If anything prints, run `forge fmt` and amend the relevant commit.

- [ ] **Step 2: Full default-profile suite**

Run:
```bash
cd contracts && forge test 2>&1 | tail -3
```
Expected: `<baseline + new adapter tests> passed, 0 failed`, with the 3 fork tests SKIPPED. Record the new count.

- [ ] **Step 3: Confirm the adapter never pulls Pyth inside read/peek (O6 invariant, static check)**

Run:
```bash
cd contracts && grep -n "updatePriceFeeds\|getPriceNoOlderThan\|updatePyth" src/v2/ChainlinkPythAdapterV2.sol
```
Expected: `updatePriceFeeds` and `updatePyth` appear ONLY inside the `updatePyth` function body; `getPriceNoOlderThan` appears NOWHERE (we use `getPriceUnsafe`). `_readPyth`, `_compute`, `peekPrice`, `readPrice` must show NO `updatePriceFeeds` call. If a pull leaks into `_readPyth`/`readPrice`, O6 is broken — remove it.

- [ ] **Step 4: Confirm no non-ASCII inside Solidity string literals (unicode gotcha)**

Run:
```bash
cd contracts && grep -nP '"[^"]*[^\x00-\x7F][^"]*"' src/v2/ChainlinkPythAdapterV2.sol src/v2/interfaces/IPythV2.sol test/v2/ChainlinkPythAdapterV2.t.sol test/v2/ChainlinkPythAdapterV2.fork.t.sol | grep -v 'unicode"' || echo "OK: no bare non-ASCII string literals"
```
Expected: `OK: no bare non-ASCII string literals` (every `§`/`≈` inside a Solidity string uses the `unicode"..."` prefix; `§` in `///` NatSpec comments is fine).

- [ ] **Step 5: Commit any fmt fixups**

Run:
```bash
git add -A && git commit -m "style(v2): forge fmt gate (oracle adapters)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" || echo "nothing to commit"
```

---

## Self-Review

### Spec coverage (section-by-section)

- **§10 Oracle architecture** — `ChainlinkPythAdapterV2` reads two INDEPENDENT, DIRECT token/USD sources (Chainlink primary `IChainlinkAggregator`, Pyth secondary `IPythV2`), normalizes each to 1e18, and decides `safe` alone. A single surviving source ⇒ `safe == false` (`_compute` returns false on `!clOk || !pyOk`). EURC uses the verified DIRECT Chainlink + DIRECT Pyth `Crypto.EURC/USD` IDs — no FX leg, matching the research-note verdict that EURC needs no TRYC/BRLC-style deferral. Tasks 1, 3, 4, 6. ✓
- **§11 Oracle failure behavior** — every failure mode (either source stale/invalid/reverting, Pyth confidence over bound, divergence over bound) yields `safe == false`; the Pool then stops swaps/deposits/single-withdraws into it and any NAV op needing the unsafe price (Pool-side, unchanged). Last valid price is retained in `lastSafePrice1e18` for display/alerts but NEVER returned as `safe` and never authorizes a transfer (the Pool gates on the `safe` flag, and `_compute` only returns `true` on a live, agreeing, in-bound dual read). Tasks 3, 4. ✓
- **§12 Monitoring (adapter-side hooks only)** — the adapter exposes `lastSafePrice1e18`/`lastSafeAt` and emits `SafePriceCached`/`PythUpdated`/param-update events for off-chain freshness/confidence/divergence alerting. The third external reference, keeper scheduling, and alert delivery are explicitly OUT (monitoring plan). Task 3. ✓ (scoped)
- **§14 Testing — oracle cases** — stale (both legs, incl. the 24h heartbeat tolerance), confidence (over/at-bound), divergence (over/within), revert (both legs caught ⇒ unsafe), malformed/negative/zero/expo-edge, single-source-fail-closed (both directions), O6 peek==read parity, `updatePyth` fee/refund/isolation, governance setters. Task 4. Fork test adds real-feed normalization + O6 on live bytecode (Task 5). ✓
- **§15 Acceptance (adapter contribution)** — mainnet USDC/EURC/USDT each get two verified independent DIRECT sources (the deploy table, Task 6, cross-checked against the research note in Step 2). The Sepolia EURC mock-leg is flagged as NOT satisfying the mainnet two-direct-sources gate. ✓ (the adapter is one input to §15; security review/Safe/Timelock/pause-drill are other plans.)

### Punch-list constraint O6 (peek==read within a block)

| Requirement | How the plan satisfies it | Test |
|---|---|---|
| `peekPrice` (view) and `readPrice` (mut) return identical `(price, safe)` in a block | Both delegate to `_compute()`, a pure-of-state function of current feed state; `readPrice`'s only side effect is writing the display cache, which does NOT alter the returned tuple. | `test_peek_equals_read_same_block`, `test_updatePyth_does_not_affect_read_in_same_block`, fork `_assertLiveStable` |
| No state-dependent price mutation on read | `readPrice` does NOT pull Pyth; it uses `getPriceUnsafe` (view) just like `peekPrice`. | Task 7 Step 3 static grep |
| Pyth pull-updates isolated to a keeper path | `updatePyth(bytes[])` is the ONLY function calling `updatePriceFeeds`; never reached by read/peek. | `test_updatePyth_*`, Task 7 Step 3 |

The bound is therefore **exact** (peek==read, zero divergence), not merely "documented" — the stronger of the two O6 options.

### Decision log (ambiguities resolved, explicit)

1. **Pyth dependency: vendored minimal interface** (`IPythV2`) over `@pythnetwork/pyth-sdk-solidity`. Justified in Task 1 (matches the repo's hand-written `IChainlinkAggregator`; avoids an external lib + solc-drift + the 2026-07-31 SDK-packaging churn; only the contract ADDRESS changes at the upgrade, not our ABI).
2. **Pyth read method: `getPriceUnsafe` + explicit staleness**, NOT `getPriceNoOlderThan`. The latter reverts on stale, which would (a) make fail-closed a revert instead of a `safe==false` flag and (b) couple `readPrice`/`peekPrice` control flow to a revert path. `getPriceUnsafe` lets both functions share one branchless `_compute`, preserving O6.
3. **Pyth pull isolation: separate `updatePyth` keeper path** (the "no pull inside readPrice" O6 option) rather than documenting a bound on an in-read pull. Strongest O6 guarantee.
4. **`safe` when sources diverge OR a leg is bad: always `false`** (fail-closed), and the RETURNED price is best-effort display only (surviving leg → cache → 0), never authoritative. The Pool ignores the price when `safe==false`.
5. **Divergence convention: against the LOWER price** (`diff*BPS > lo*divBps`), matching V1 `OracleAggregator` I-5 (intentional, slightly-wider asymmetric tolerance; negligible at 50–60bps caps). Reuses the audited V1 convention rather than inventing a new mid-based one.
6. **Confidence rule: ratio in bps, expo-independent** (`conf*BPS <= price*confBps`, at-cap allowed). conf and price share the same expo so the ratio needs no 1e18 scaling — avoids an extra rounding step.
7. **One adapter PER token, with a `WrongToken` guard.** The interface passes `token` to every call; rather than ignore it, the adapter asserts it equals its immutable `TOKEN` so a Registry misconfiguration (wrong adapter for a token) fails loudly instead of silently pricing the wrong asset.
8. **`Ownable2Step`, params tunable, feeds/IDs immutable.** Governance (Timelock) can retune the four safety bounds (heartbeat margins, confidence, divergence) without redeploying, but cannot swap the feed/ID — swapping a source is a Registry `setAdapter` to a freshly-deployed adapter, preserving "changing oracle sources" as a Timelock-gated redeploy, not a hot setter.
9. **Chainlink stale window ≥ 90000s** to tolerate the verified 86400s heartbeat with margin (the research note's caveat 3). Testnet windows are deliberately huge (7–30d) given the ~8-day-stale Sepolia USDC feed (caveat 2).
10. **Sepolia EURC: MockChainlinkFeed leg** (caveat 1) — testnet-only, explicitly NOT a §15 production source. Mainnet EURC uses the real direct CL proxy.
11. **Pyth contract target: the UPGRADED 2026-07-31 addresses** on both networks (research note's TARGET instruction); the post-upgrade Hermes API-key requirement is a keeper/monitoring concern (off-chain), not an on-chain ABI change, so it does not affect this contract.

### Placeholder scan
- No "TBD", "implement later", or undefined-symbol references in any shown code. Every function body is complete and compiles.
- The deploy table's `(prod USDC/EURC/USDT)` token-address cells are intentional placeholders for the token contract addresses, which are fixed at the Base deploy plan (the canonical Circle/Tether token addresses on Base) — the ORACLE wiring (feeds, IDs, params) is fully pinned. Flagged, not a code stub.
- The fork test's keeper-pull-on-fork (Hermes blob via FFI) is explicitly deferred to the deploy/monitoring plan, not left as a stub here.

### Type/name consistency across tasks
- `IOracleAdapterV2.readPrice/peekPrice → (uint256 price1e18, bool safe)` — implemented with exactly these return types/names in `ChainlinkPythAdapterV2` (matches the unchanged interface the Pool consumes).
- `IPythV2.Price{int64 price, uint64 conf, int32 expo, uint256 publishTime}` — identical in the interface, `MockPyth`, and the adapter's `_readPyth`.
- `MockChainlinkFeed` implements `IChainlinkAggregator` (`latestRoundData` 5-tuple + `decimals`) — the same interface V1 `OracleAggregator` and this adapter consume.
- Adapter constructor arg order `(token, chainlinkFeed, pyth, pythPriceId, chainlinkMaxStaleSeconds, pythMaxStaleSeconds, pythMaxConfBps, maxDivergenceBps, initialOwner)` — identical in the unit test, the fork test, and the deploy table column order.
- Errors used in tests (`WrongToken`, `InvalidConfBps`, `InsufficientUpdateFee`) all exist on `ChainlinkPythAdapterV2`.

### Carried-forward V1 audited patterns (explicit)
- Chainlink `_tryRead` five-check validity (positive answer, positive timestamp, `roundId != 0`, `answeredInRound >= roundId`, per-source staleness) — reused verbatim in `_readChainlink` (from `OracleAggregator._tryRead`).
- Divergence-against-`min` (I-5) convention — reused in `_compute`.
- `Ownable2Step` governance + UPPER_CASE-immutable slither justifications — reused.
- try/catch fail-closed on a reverting feed — reused for BOTH legs.
- Env-driven RPC endpoint + `vm.envOr`-skip fork pattern — reused from the existing `arc_testnet` endpoint / `DeployPublicTestnetTokenParam.t.sol` skip style.

---

## Per-Token Deploy Config (§6 deliverable — permanent reference)

> Recorded by Task 6 (2026-06-10). This is the PERMANENT deliverable the future
> `DeployOracleAdaptersV2.s.sol` transcribes verbatim — constructor args per token per
> network for `ChainlinkPythAdapterV2(token, chainlinkFeed, pyth, pythPriceId,
> chainlinkMaxStaleSeconds, pythMaxStaleSeconds, pythMaxConfBps, maxDivergenceBps, initialOwner)`.
> Cross-checked against `docs/research/2026-06-10-base-oracle-feeds.md` (all five mainnet
> anchor addresses/IDs appear verbatim — Task 6 Step 2).

### Base mainnet (chainId 8453) — production

| Token | `token` | `chainlinkFeed` | `pyth` | `pythPriceId` | `chainlinkMaxStaleSeconds` | `pythMaxStaleSeconds` | `pythMaxConfBps` | `maxDivergenceBps` |
|---|---|---|---|---|---|---|---|---|
| USDC | (prod USDC) | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | `0xbC16aee60f64864882BC6C4E428e148Fc0E272F5` | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` | `90000` | `60` | `30` | `50` |
| EURC | (prod EURC) | `0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250` | `0xbC16aee60f64864882BC6C4E428e148Fc0E272F5` | `0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c` | `90000` | `60` | `40` | `60` |
| USDT | (prod USDT) | `0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9` | `0xbC16aee60f64864882BC6C4E428e148Fc0E272F5` | `0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b` | `90000` | `60` | `30` | `50` |

Rationale for the params:
- `chainlinkMaxStaleSeconds = 90000` (> the verified 86400s heartbeat, with ~3600s margin) for all three.
- `pythMaxStaleSeconds = 60` assumes a keeper calls `updatePyth` at least each minute before quotes/execution; loosen to 120 if the keeper cadence is slower (a monitoring-plan knob).
- `pythMaxConfBps`: USDC/USDT 30 (0.30%), EURC 40 (0.40%) — EURC's live conf (±0.001545 on ~1.155 ≈ 13bps) and stables (~7bps) sit well under these; the cap catches a confidence blow-out, not normal noise.
- `maxDivergenceBps`: 50 (0.50%) stables, 60 (0.60%) EURC — comfortably above the verified CL-vs-Pyth gap (sub-1bp at check time) while still tripping on a real depeg/disagreement.
- All four are owner-settable post-deploy via Timelock, so these are launch defaults, not frozen forever.
- The `(prod USDC/EURC/USDT)` token cells are the canonical Circle/Tether token addresses on Base, pinned at the deploy plan — the ORACLE wiring (feeds, IDs, params) is fully pinned here.

### Base Sepolia (chainId 84532) — testnet

| Token | `chainlinkFeed` | `pyth` | `pythPriceId` | `chainlinkMaxStaleSeconds` | `pythMaxStaleSeconds` | Notes |
|---|---|---|---|---|---|---|
| USDC | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` | `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83` | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` | `2592000` (30d) | `86400` | USDC feed observed ~8d stale → **very lenient** window or use a MockChainlinkFeed leg |
| USDT | `0x3ec8593F930EA45ea58c968260e6e9FF53FC934f` | `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83` | `0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b` | `604800` (7d) | `86400` | fresh feed; still wide for testnet |
| EURC | **`MockChainlinkFeed` (deploy a stub)** | `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83` | `0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c` | `604800` (7d) | `86400` | **No Chainlink EURC on Sepolia** → deploy a `MockChainlinkFeed(8, 1.15e8)` (or a keeper-set stub) as the Chainlink leg so the adapter still has TWO sources; THIS IS A TESTNET-ONLY WORKAROUND, never on mainnet. Mainnet EURC uses the real direct CL proxy above. |

Testnet EURC mock-leg procedure (record in the deploy plan):
1. Deploy `MockChainlinkFeed(8, 115000000)` (= $1.15, 8 dec) on Sepolia, owned by the test operator.
2. Construct the EURC adapter with that mock address as `chainlinkFeed`.
3. A simple keeper/script periodically calls `setAnswer` / `setUpdatedAt` to keep the mock leg fresh and roughly tracking the real EUR/USD (or just hold ~1.15 for functional testing).
4. Document explicitly in the deploy runbook that the Sepolia EURC adapter is dual-source ONLY via this mock — it does NOT satisfy the §15 "two verified independent direct sources" acceptance gate, which applies to MAINNET. Testnet is for flow/drill validation, not the production admission proof.
