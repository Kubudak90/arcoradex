# Phase 1 Contract Critical Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four mainnet-blocking smart-contract findings — #A first-depositor inflation attack (CRITICAL), #B JIT/MEV sandwich (HIGH), #C quote↔execute deviation gap (MEDIUM), and #4 single-stale-feed availability lockup (MEDIUM) — and ship as four review-bounded PRs on a single `phase1/contract-fixes` branch, followed by a testnet redeploy.

**Architecture:** All four fixes are confined to `ArcoraDexPool.sol`, `ArcoraDexRegistry.sol`, and their interfaces. #4 changes storage layout on both contracts (forces redeploy of both); #A is pure math (no new storage); #B adds one mapping to Pool; #C refactors the existing price-reader into a `Mut`/`View` split. Implementation order is dictated by storage-layout dependency: #4 ships first so subsequent PRs build on the locked layout. Each PR is TDD-driven: write the exploit PoC test first (fails), implement the fix (passes), update existing tests for new signatures/math, commit.

**Tech Stack:** Solidity 0.8.26, Foundry (forge build / forge test / forge coverage), OpenZeppelin v5 (Ownable2Step, ReentrancyGuard, SafeERC20, ERC20).

**Spec:** `docs/superpowers/specs/2026-05-14-phase1-contract-fixes-design.md`
**Parent roadmap:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §3

---

## File Structure

### Files modified

| File | Changes |
|------|---------|
| `contracts/src/ArcoraDexRegistry.sol` | Extend `TokenInfo` struct with `maxStaleSeconds`; extend `listToken()` signature; add `setMaxStaleSeconds()`; update `tokenInfo`/`isActive` return paths trivially |
| `contracts/src/interfaces/IArcoraDexRegistry.sol` | Mirror struct + signature changes; add `setMaxStaleSeconds` to interface; add `MaxStaleSecondsUpdated` event; add `InvalidStaleSeconds` error |
| `contracts/src/ArcoraDexPool.sol` | Add `VIRTUAL_SHARES`, `VIRTUAL_ASSETS`, `MIN_HOLD_SECONDS` constants; add `lastMintAt`, `lastValidPrice`, `lastValidPriceAt` mappings; split `_readUsdPrice1e18` into `_readUsdPrice1e18Mut`/`_readUsdPrice1e18View`/`_readUsdPrice1e18WithGuard`; rewrite `deposit`/`withdraw`/`swap` math to use virtual offset; add `EarlyWithdraw` and `NoValidPrice` errors |
| `contracts/src/interfaces/IArcoraDexPool.sol` | Add new error types and event signatures; expose new public mappings |
| `contracts/test/ArcoraDexPool.t.sol` | Update existing fixture `listToken()` calls (3); update existing deposit/withdraw expected LP amounts for virtual shares; add `vm.warp` before all post-deposit withdraw paths |
| `contracts/test/ArcoraDexPool.fuzz.t.sol` | Update fixture `listToken()` calls (2); update fuzz invariants if math constants are referenced |
| `contracts/test/ArcoraDexPool.invariant.t.sol` | Update fixture `listToken()` calls (3); confirm invariants hold with virtual shares |
| `contracts/test/ArcoraDexRegistry.t.sol` | Update all `listToken()` callsites (~15) with new `maxStaleSeconds` parameter; add tests for `setMaxStaleSeconds` |
| `contracts/script/DeployArcoraDex.s.sol` | Update `listToken()` call site (1) with `maxStaleSeconds` per token |

### Files created

| File | Purpose |
|------|---------|
| `contracts/test/ArcoraDexPool.security.t.sol` | New file housing the 4 audit-grade PoC tests for findings #A, #B, #C, #4 |
| `contracts/script/DeployArcoraDexV2.s.sol` | Fresh deploy script for the new Pool+Registry on testnet (Task 7) |
| `docs/rollouts/2026-05-XX-phase1-deploy.md` | Rollout doc with new addresses + old-pool-freeze runbook |

### Branch

All work lands on `phase1/contract-fixes`, branched from `main` once the roadmap+spec+plan PR has merged.

---

### Task 1: Branch setup and baseline verification

**Files:** none modified; verification only.

- [ ] **Step 1: Confirm roadmap+spec+plan PR has merged to `main`**

Run:
```bash
git checkout main && git pull --ff-only origin main
git log -1 --format='%h %s'
```
Expected: HEAD commit subject mentions the roadmap PR (e.g. `docs(roadmap): mainnet readiness master roadmap (2026-05-13)` or its merge commit).

- [ ] **Step 2: Create the phase 1 branch**

Run:
```bash
git checkout -b phase1/contract-fixes
git log --oneline -1
```
Expected: clean branch at the same SHA as `main`.

- [ ] **Step 3: Establish forge test baseline**

Run:
```bash
cd contracts && forge build && forge test
```
Expected: `Compiler run successful`, then `Ran N test suites: 77 tests passed, 0 failed, 0 skipped`. If the number is not 77, record the actual count — that becomes the baseline for "no regression" checks in later tasks.

- [ ] **Step 4: Establish coverage baseline**

Run:
```bash
cd contracts && forge coverage --report summary 2>&1 | tail -20
```
Expected: a table summarising line/statement/function/branch coverage. Record the `contracts/src/` aggregate percentage as the pre-P1 baseline.

- [ ] **Step 5: Establish slither baseline (best-effort)**

Run:
```bash
cd contracts && slither . 2>&1 | tail -30 || echo "slither not installed, skip"
```
Expected: either a small set of benign warnings (rounding / calls-loop / reentrancy-benign) or "slither not installed". Record so we can confirm no new findings introduced.

No commit yet — Task 1 is verification only.

---

### Task 2: #4 Per-token staleness + cached fresh-price fallback (1 PR)

This is the biggest task because it changes both Registry storage and Pool storage. It must ship first per spec §5 so subsequent tasks build on the locked storage layout.

**Files:**
- Modify: `contracts/src/interfaces/IArcoraDexRegistry.sol`
- Modify: `contracts/src/ArcoraDexRegistry.sol`
- Modify: `contracts/src/interfaces/IArcoraDexPool.sol`
- Modify: `contracts/src/ArcoraDexPool.sol`
- Create: `contracts/test/ArcoraDexPool.security.t.sol`
- Modify: existing test files (signatures and `vm.warp` updates)
- Modify: `contracts/script/DeployArcoraDex.s.sol`

- [ ] **Step 1: Write the PoC test for #4 (red phase)**

Create `contracts/test/ArcoraDexPool.security.t.sol` with:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ArcoraDexPool }      from "../src/ArcoraDexPool.sol";
import { ArcoraDexRegistry }  from "../src/ArcoraDexRegistry.sol";
import { ArcoraDexLP }        from "../src/ArcoraDexLP.sol";
import { MockChainlinkFeedV2 } from "../src/testnet/MockChainlinkFeedV2.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

contract ArcoraDexPoolSecurityTest is Test {
    ArcoraDexRegistry reg;
    ArcoraDexPool     pool;
    MockERC20         usdc;
    MockERC20         eurc;
    MockChainlinkFeedV2 fUsdc;
    MockChainlinkFeedV2 fEurc;
    address constant DEPLOYER = address(0xD3);
    address constant ALICE    = address(0xA1);

    function setUp() public {
        vm.startPrank(DEPLOYER);
        reg   = new ArcoraDexRegistry(DEPLOYER);
        usdc  = new MockERC20("USDC", "USDC", 6);
        eurc  = new MockERC20("EURC", "EURC", 6);
        fUsdc = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER);  // $1.00
        fEurc = new MockChainlinkFeedV2(8, 110_000_000, DEPLOYER, DEPLOYER);  // $1.10
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(fUsdc)),  50, 3600);
        reg.listToken(address(eurc), 6, IChainlinkAggregator(address(fEurc)), 150, 14400);
        pool = new ArcoraDexPool(address(reg), 5, 5000, DEPLOYER);
        vm.stopPrank();
    }

    function test_stale_feed_falls_back_to_cache() public {
        // Seed cache via a deposit on USDC and EURC
        usdc.mint(ALICE, 1_000_000_000); // 1000 USDC
        eurc.mint(ALICE, 1_000_000_000); // 1000 EURC
        vm.startPrank(ALICE);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60);
        pool.deposit(address(eurc), 100_000_000, 0, block.timestamp + 60);
        vm.stopPrank();

        // Advance time so EURC oracle (4h budget) becomes stale
        vm.warp(block.timestamp + 5 hours);

        // NAV should still compute using the cached EURC price
        uint256 nav = pool.totalReservesUSD();
        assertGt(nav, 0, "NAV must remain queryable with stale feed");

        // Cached price for EURC should be the seeded $1.10 (1.1e18)
        assertEq(pool.lastValidPrice(address(eurc)), 1.1e18);
    }

    function test_no_valid_price_reverts_when_never_seeded() public {
        // List a third token but never touch its oracle
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockChainlinkFeedV2 fDai = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER);
        vm.prank(DEPLOYER);
        reg.listToken(address(dai), 18, IChainlinkAggregator(address(fDai)), 50, 3600);

        // Make the DAI feed immediately stale
        vm.warp(block.timestamp + 2 hours);

        // Any read on DAI should revert NoValidPrice
        vm.expectRevert();
        pool.totalReservesUSD();
    }
}
```

- [ ] **Step 2: Run the new test to verify it fails to compile**

Run:
```bash
cd contracts && forge build 2>&1 | tail -10
```
Expected: compilation failure mentioning `listToken` signature (5 args used vs 4 expected) and `lastValidPrice` not on `ArcoraDexPool`. This is the red phase.

- [ ] **Step 3: Extend `IArcoraDexRegistry` interface**

Edit `contracts/src/interfaces/IArcoraDexRegistry.sol`. Find the `TokenInfo` struct definition:
```solidity
    struct TokenInfo {
        uint8                decimals;
        bool                 isActive;
        IChainlinkAggregator usdOracle;
        uint16               maxOracleDeviationBps;
    }
```
Replace with:
```solidity
    struct TokenInfo {
        uint8                decimals;
        bool                 isActive;
        IChainlinkAggregator usdOracle;
        uint16               maxOracleDeviationBps;
        uint32               maxStaleSeconds;
    }
```

Find the `listToken` function signature:
```solidity
    function listToken(
        address token,
        uint8 decimals_,
        IChainlinkAggregator oracle,
        uint16 maxDeviationBps
    ) external;
```
Replace with:
```solidity
    function listToken(
        address token,
        uint8 decimals_,
        IChainlinkAggregator oracle,
        uint16 maxDeviationBps,
        uint32 maxStaleSeconds_
    ) external;
```

Find the events block (look for `event TokenListed`). Replace `TokenListed` with:
```solidity
    event TokenListed(
        address indexed token,
        uint8   decimals,
        address indexed oracle,
        uint16  maxOracleDeviationBps,
        uint32  maxStaleSeconds
    );
```

Find the error block (look for `error InvalidDeviation`) and add immediately after:
```solidity
    error InvalidStaleSeconds(uint32 maxStaleSeconds);
```

Add a new mutator and event after `setDeviation`:
```solidity
    function setMaxStaleSeconds(address token, uint32 maxStaleSeconds_) external;
    event MaxStaleSecondsUpdated(address indexed token, uint32 oldVal, uint32 newVal);
```

- [ ] **Step 4: Update `ArcoraDexRegistry.sol` implementation**

Edit `contracts/src/ArcoraDexRegistry.sol`. Find `listToken`:
```solidity
    function listToken(
        address token,
        uint8 decimals_,
        IChainlinkAggregator oracle,
        uint16 maxDeviationBps
    ) external override onlyOwner {
        if (token == address(0) || address(oracle) == address(0)) revert ZeroAddress();
        if (decimals_ == 0 || decimals_ > 18) revert InvalidDecimals(decimals_);
        uint8 actualDecimals = IERC20Metadata(token).decimals();
        if (decimals_ != actualDecimals) revert TokenDecimalMismatch(token, decimals_, actualDecimals);
        if (maxDeviationBps == 0 || maxDeviationBps > 10_000) revert InvalidDeviation(maxDeviationBps);
        if (_info[token].usdOracle != IChainlinkAggregator(address(0))) revert TokenAlreadyListed(token);

        _info[token] = TokenInfo({
            decimals: decimals_,
            isActive: true,
            usdOracle: oracle,
            maxOracleDeviationBps: maxDeviationBps
        });
        tokens.push(token);
        emit TokenListed(token, decimals_, address(oracle), maxDeviationBps);
    }
```
Replace with:
```solidity
    function listToken(
        address token,
        uint8 decimals_,
        IChainlinkAggregator oracle,
        uint16 maxDeviationBps,
        uint32 maxStaleSeconds_
    ) external override onlyOwner {
        if (token == address(0) || address(oracle) == address(0)) revert ZeroAddress();
        if (decimals_ == 0 || decimals_ > 18) revert InvalidDecimals(decimals_);
        uint8 actualDecimals = IERC20Metadata(token).decimals();
        if (decimals_ != actualDecimals) revert TokenDecimalMismatch(token, decimals_, actualDecimals);
        if (maxDeviationBps == 0 || maxDeviationBps > 10_000) revert InvalidDeviation(maxDeviationBps);
        if (maxStaleSeconds_ < 60 || maxStaleSeconds_ > 7 days) revert InvalidStaleSeconds(maxStaleSeconds_);
        if (_info[token].usdOracle != IChainlinkAggregator(address(0))) revert TokenAlreadyListed(token);

        _info[token] = TokenInfo({
            decimals: decimals_,
            isActive: true,
            usdOracle: oracle,
            maxOracleDeviationBps: maxDeviationBps,
            maxStaleSeconds: maxStaleSeconds_
        });
        tokens.push(token);
        emit TokenListed(token, decimals_, address(oracle), maxDeviationBps, maxStaleSeconds_);
    }
```

Add a new mutator immediately after `setDeviation`:
```solidity
    function setMaxStaleSeconds(address token, uint32 maxStaleSeconds_) external override onlyOwner {
        if (maxStaleSeconds_ < 60 || maxStaleSeconds_ > 7 days) revert InvalidStaleSeconds(maxStaleSeconds_);
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        uint32 old = info.maxStaleSeconds;
        info.maxStaleSeconds = maxStaleSeconds_;
        emit MaxStaleSecondsUpdated(token, old, maxStaleSeconds_);
    }
```

- [ ] **Step 5: Extend `IArcoraDexPool` interface with new errors and views**

Edit `contracts/src/interfaces/IArcoraDexPool.sol`. Find the errors block and add:
```solidity
    error NoValidPrice(address token);
    error EarlyWithdraw(uint256 unlockAt, uint256 nowAt);
```

Add views to the interface (locate the existing view section near `lastAcceptedPrice`):
```solidity
    function lastValidPrice(address token)   external view returns (uint256);
    function lastValidPriceAt(address token) external view returns (uint256);
    function lastMintAt(address account)     external view returns (uint256);
```

Note: `lastMintAt` is added in Task 4 — declaring it now keeps the interface stable across the four PRs. The Pool implementation does not need to provide `lastMintAt` storage until Task 4. Some implementations of `forge build` may warn about an unimplemented interface function; in that case temporarily comment out the `lastMintAt` line and uncomment in Task 4 Step 3.

Decision: **comment out `lastMintAt` in Task 2** to keep the interface compilable; Task 4 will uncomment it and add the storage. Update the line to:
```solidity
    // function lastMintAt(address account) external view returns (uint256); // added in Task 4
```

- [ ] **Step 6: Add Pool storage and rewrite the price reader**

Edit `contracts/src/ArcoraDexPool.sol`. After the existing `lastAcceptedPrice` mapping, add:
```solidity
    mapping(address token => uint256) public override lastValidPrice;     // 1e18-scaled USD price (cache)
    mapping(address token => uint256) public override lastValidPriceAt;   // block.timestamp of cache write
```

Replace the existing `_readUsdPrice1e18` function (currently at lines 68–90) with two functions — a shared internal reader plus mutating/view wrappers:

```solidity
    /// @dev Shared internal reader. Returns (price1e18, decimals, isFresh).
    ///      Does NOT mutate state. Callers decide what to do when not fresh.
    function _readOracle(address token)
        internal view
        returns (uint256 price1e18, uint8 tokenDecimals, bool isFresh)
    {
        IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        if (!info.isActive) revert TokenNotActive(token);
        tokenDecimals = info.decimals;

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            info.usdOracle.latestRoundData();
        if (roundId == 0 || answeredInRound < roundId) {
            revert InvalidOracleRound(token, roundId, answeredInRound);
        }
        if (updatedAt == 0 || updatedAt > block.timestamp) {
            revert InvalidOracleTimestamp(token, updatedAt);
        }

        isFresh = (
            answer > 0 &&
            (block.timestamp - updatedAt) <= info.maxStaleSeconds
        );
        if (isFresh) {
            uint8 oracleDec = info.usdOracle.decimals();
            if (oracleDec == 18)      price1e18 = uint256(answer);
            else if (oracleDec < 18)  price1e18 = uint256(answer) * (10 ** (18 - oracleDec));
            else                      price1e18 = uint256(answer) / (10 ** (oracleDec - 18));
        }
    }

    /// @dev Stateful wrapper: updates cache on fresh read; falls back to cache on stale.
    function _readUsdPrice1e18Mut(address token)
        internal returns (uint256 price1e18, uint8 tokenDecimals)
    {
        bool isFresh;
        (price1e18, tokenDecimals, isFresh) = _readOracle(token);
        if (isFresh) {
            lastValidPrice[token]   = price1e18;
            lastValidPriceAt[token] = block.timestamp;
            return (price1e18, tokenDecimals);
        }
        // Stale — fall back to cache
        price1e18 = lastValidPrice[token];
        if (price1e18 == 0) revert NoValidPrice(token);
    }

    /// @dev View-only equivalent: returns cached fallback price without updating it.
    function _readUsdPrice1e18View(address token)
        internal view returns (uint256 price1e18, uint8 tokenDecimals)
    {
        bool isFresh;
        (price1e18, tokenDecimals, isFresh) = _readOracle(token);
        if (isFresh) return (price1e18, tokenDecimals);
        price1e18 = lastValidPrice[token];
        if (price1e18 == 0) revert NoValidPrice(token);
    }
```

Find the existing `_readAndGuardPrice` (currently at lines 92–109) and update the first internal call:
```solidity
    function _readAndGuardPrice(address token)
        internal
        returns (uint256 price1e18, uint8 tokenDecimals)
    {
        IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        uint16 maxDevBps;
        (price1e18, tokenDecimals) = _readUsdPrice1e18Mut(token);  // CHANGED from _readUsdPrice1e18
        maxDevBps = info.maxOracleDeviationBps;
        uint256 prev = lastAcceptedPrice[token];
        if (prev != 0) {
            uint256 diff = price1e18 > prev ? price1e18 - prev : prev - price1e18;
            if (diff * BPS > prev * uint256(maxDevBps)) {
                revert PriceDeviation(token, price1e18, prev, maxDevBps);
            }
        }
        lastAcceptedPrice[token] = price1e18;
    }
```

Find `totalReservesUSD` (currently at lines 111–119). It's currently `view`. Two callers need it: `withdraw` (mutating path) and `quoteWithdraw` (view path). Update to a state-mutating implementation backing a view shim:

Replace:
```solidity
    function totalReservesUSD() public view override returns (uint256 navE18) {
        uint256 n = REGISTRY.tokensLength();
        for (uint256 i = 0; i < n; i++) {
            address t = REGISTRY.tokens(i);
            if (!REGISTRY.isActive(t)) continue;
            (uint256 p, uint8 d) = _readUsdPrice1e18(t);
            navE18 += (reserves[t] * p) / (10 ** d);
        }
    }
```
With:
```solidity
    /// @dev Stateful: refreshes cache on every fresh oracle read.
    function _totalReservesUSDMut() internal returns (uint256 navE18) {
        uint256 n = REGISTRY.tokensLength();
        for (uint256 i = 0; i < n; i++) {
            address t = REGISTRY.tokens(i);
            if (!REGISTRY.isActive(t)) continue;
            (uint256 p, uint8 d) = _readUsdPrice1e18Mut(t);
            navE18 += (reserves[t] * p) / (10 ** d);
        }
    }

    /// @dev View shim used by external view functions and external quote*() callers.
    function totalReservesUSD() public view override returns (uint256 navE18) {
        uint256 n = REGISTRY.tokensLength();
        for (uint256 i = 0; i < n; i++) {
            address t = REGISTRY.tokens(i);
            if (!REGISTRY.isActive(t)) continue;
            (uint256 p, uint8 d) = _readUsdPrice1e18View(t);
            navE18 += (reserves[t] * p) / (10 ** d);
        }
    }
```

Find `deposit` (currently around line 122). Inside `deposit`, the line `navBefore = totalReservesUSD();` calls the view shim and is fine for math BUT we want to update the cache during deposit too. Replace that line with:
```solidity
        navBefore = _totalReservesUSDMut();
```

Find `withdraw` (currently around line 155). Same change — `navBefore = totalReservesUSD();` becomes:
```solidity
        navBefore = _totalReservesUSDMut();
```

(The `swap` function does not call `totalReservesUSD` directly, so it doesn't need this change. It already uses `_readAndGuardPrice` which now updates the cache transitively via `_readUsdPrice1e18Mut`.)

Delete the now-dead original `_readUsdPrice1e18` (the old view function from lines 68–90 you replaced in this step). It is no longer referenced.

Also delete the global `MAX_STALE_SECONDS` constant from the constants block (currently around line 25):
```solidity
    uint256 public  constant MAX_STALE_SECONDS             = 1 hours;
```
Staleness is now per-token via `info.maxStaleSeconds`. The constant has no remaining callers.

- [ ] **Step 7: Update existing fixtures to compile**

Edit `contracts/test/ArcoraDexRegistry.t.sol`. Use `replace_all` to update all `listToken` calls from the 4-arg form to the 5-arg form. The trailing `maxStaleSeconds` value should be `3600` (1 hour) for every fixture in this file — these are unit tests where staleness is not the concern.

For each occurrence of `reg.listToken(<args>, 50);`, change to `reg.listToken(<args>, 50, 3600);`. Similarly for `100`, `10_001`, and `0` deviation values: append `, 3600`.

The lines that test `InvalidDeviation` (with `0` or `10_001`) stay unchanged in semantics — only the trailing `maxStaleSeconds` is appended.

Add a new test at the end of `ArcoraDexRegistry.t.sol`, before the closing brace:
```solidity
    function test_RevertsOnInvalidStaleSeconds_zero() public {
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.InvalidStaleSeconds.selector, 0));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 0);
    }

    function test_RevertsOnInvalidStaleSeconds_tooLow() public {
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.InvalidStaleSeconds.selector, 59));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 59);
    }

    function test_RevertsOnInvalidStaleSeconds_tooHigh() public {
        uint32 tooHigh = uint32(7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.InvalidStaleSeconds.selector, tooHigh));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, tooHigh);
    }

    function test_SetMaxStaleSeconds_updatesAndEmits() public {
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);
        vm.expectEmit(true, false, false, true);
        emit IArcoraDexRegistry.MaxStaleSecondsUpdated(address(usdc), 3600, 7200);
        reg.setMaxStaleSeconds(address(usdc), 7200);
        assertEq(reg.tokenInfo(address(usdc)).maxStaleSeconds, 7200);
    }
```

Edit `contracts/test/ArcoraDexPool.t.sol`. Lines 43–45 (three `listToken` calls) need the 5-arg form:
- USDC: append `, 3600`
- EURC: append `, 14400`
- DAI: append `, 3600`

Edit `contracts/test/ArcoraDexPool.fuzz.t.sol`. Lines 34–35 (two `listToken` calls) need:
- USDC: append `, 3600`
- EURC: append `, 14400`

Edit `contracts/test/ArcoraDexPool.invariant.t.sol`. Lines 41–43 (three `listToken` calls) need:
- USDC: append `, 3600`
- EURC: append `, 14400`
- DAI: append `, 3600`

Edit `contracts/script/DeployArcoraDex.s.sol`. Line 48 calls `reg.listToken(...)` inside a loop over `cfg[i]`. Two options: (a) add a fifth field `maxStaleSeconds` to the `cfg` struct and pass it; (b) hard-code 3600 in the call. Pick (a) for correctness — implementer should also update the inline `cfg` array elsewhere in the script to include `maxStaleSeconds: <value>` per token. If the implementer finds the script structure makes (a) onerous, fall back to (b) with a `// TODO: per-token` comment for now (will be cleaned up in Task 7's fresh deploy script).

- [ ] **Step 8: Run the build and tests**

Run:
```bash
cd contracts && forge build 2>&1 | tail -5
```
Expected: `Compiler run successful`.

Run:
```bash
cd contracts && forge test --match-contract ArcoraDexPoolSecurityTest -vv 2>&1 | tail -20
```
Expected: both `test_stale_feed_falls_back_to_cache` and `test_no_valid_price_reverts_when_never_seeded` PASS.

Run:
```bash
cd contracts && forge test 2>&1 | tail -10
```
Expected: total test count now ≥ baseline + 6 (two new security tests + four new registry tests). No regressions (no previously-passing test now failing).

If existing Pool tests fail with NAV-math mismatches, investigate: any test that assumed `totalReservesUSD` returned a specific number may need to be reviewed. The Task 2 changes only affect _which_ price source is used (oracle vs cache); the math is identical when oracle is fresh, so first-pass tests should still pass.

- [ ] **Step 9: Commit**

Run:
```bash
git add contracts/src/interfaces/IArcoraDexRegistry.sol \
        contracts/src/ArcoraDexRegistry.sol \
        contracts/src/interfaces/IArcoraDexPool.sol \
        contracts/src/ArcoraDexPool.sol \
        contracts/test/ArcoraDexPool.security.t.sol \
        contracts/test/ArcoraDexRegistry.t.sol \
        contracts/test/ArcoraDexPool.t.sol \
        contracts/test/ArcoraDexPool.fuzz.t.sol \
        contracts/test/ArcoraDexPool.invariant.t.sol \
        contracts/script/DeployArcoraDex.s.sol
git commit -m "$(cat <<'EOF'
feat(contracts): per-token staleness + cached price fallback (#4)

Closes audit finding #4: a single stale active feed currently reverts
totalReservesUSD() and therefore reverts every deposit/withdraw.

Changes:
- Registry: add `maxStaleSeconds` to TokenInfo (uint32, range [60, 7d]);
  extend listToken() signature; add setMaxStaleSeconds() mutator with
  matching event; new error InvalidStaleSeconds.
- Pool: add lastValidPrice / lastValidPriceAt cache mappings; split
  _readUsdPrice1e18 into an internal _readOracle reader plus mutating
  (_readUsdPrice1e18Mut, updates cache on fresh reads) and view
  (_readUsdPrice1e18View, reads cache without updating) wrappers;
  totalReservesUSD() now has a view shim and a mutating internal helper
  _totalReservesUSDMut used by deposit/withdraw; _readAndGuardPrice
  routes through the mutating variant; new error NoValidPrice when a
  feed is stale AND its cache is empty (i.e. never seeded).
- Tests: 4 new Registry tests for InvalidStaleSeconds + setMaxStaleSeconds;
  2 new security PoC tests covering cache fallback and unseeded revert.
- All existing fixtures updated to the 5-arg listToken signature with
  conservative defaults (3600s stables, 14400s EUR, 3600s test fixtures).

Spec: docs/superpowers/specs/2026-05-14-phase1-contract-fixes-design.md §3.4

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: #A First-depositor inflation attack — virtual shares (1 PR)

**Files:**
- Modify: `contracts/src/ArcoraDexPool.sol`
- Modify: `contracts/test/ArcoraDexPool.security.t.sol` (add inflation PoC)
- Modify: `contracts/test/ArcoraDexPool.t.sol` (existing deposit/withdraw tests' expected LP amounts shift)
- Modify: `contracts/test/ArcoraDexPool.fuzz.t.sol`, `ArcoraDexPool.invariant.t.sol` (invariants for new math)

- [ ] **Step 1: Add the inflation-attack PoC test (red phase)**

Append to `contracts/test/ArcoraDexPool.security.t.sol`, inside the contract:

```solidity
    function test_inflation_attack_fails_after_fix() public {
        address attacker = address(0xBADC0FFEE);
        address victim   = address(0xBE);

        usdc.mint(attacker, 100_000_000_000); // 100,000 USDC
        usdc.mint(victim,   1_000_000_000);   // 1,000 USDC

        // Attacker: smallest possible first deposit (~$0.001 of USDC = 1000 units)
        vm.startPrank(attacker);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 1001, 0, block.timestamp + 60); // 1001 USDC units = $0.001001
        uint256 attackerLpBefore = pool.LP().balanceOf(attacker);

        // Attacker direct-transfers a huge inflation amount
        usdc.transfer(address(pool), 10_000_000_000); // 10,000 USDC donation
        vm.stopPrank();

        // Victim deposits $100 of USDC
        vm.startPrank(victim);
        usdc.approve(address(pool), type(uint256).max);
        uint256 victimUsdcInBalance = usdc.balanceOf(victim);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60); // 100 USDC
        uint256 victimLp = pool.LP().balanceOf(victim);
        vm.stopPrank();

        // Victim must receive non-trivial LP
        assertGt(victimLp, 0, "victim should not be diluted to zero LP");

        // Victim withdraws all their LP immediately
        vm.warp(block.timestamp + 2 hours); // bypass MIN_HOLD_SECONDS (Task 4 adds it)
        vm.prank(victim);
        pool.withdraw(address(usdc), victimLp, 0, block.timestamp + 60);
        uint256 victimUsdcOut = usdc.balanceOf(victim);

        // Victim should recover ≥99% of deposit (allowing for swap fee on withdraw, ~5 bps)
        uint256 victimDeposited = 100_000_000;
        uint256 deltaIn = victimUsdcInBalance - 0; // victim started with this amount
        assertGe(victimUsdcOut, (victimDeposited * 99) / 100, "victim must recover ≥99% of deposit");

        // Attacker withdraw — should be unable to recover the 10k donation
        vm.warp(block.timestamp + 2 hours);
        vm.prank(attacker);
        pool.withdraw(address(usdc), attackerLpBefore, 0, block.timestamp + 60);
        uint256 attackerUsdcOut = usdc.balanceOf(attacker);
        // Attacker started with 100k USDC, deposited 1001 wei + donated 10,000 USDC = 10,000,001,001 USDC effectively committed
        // Attacker's LP claim should be << donation, demonstrating the attack lost money
        assertLt(attackerUsdcOut, 95_000_000_000, "attacker should lose substantial value to the pool");
    }
```

- [ ] **Step 2: Verify test fails (no fix yet)**

Run:
```bash
cd contracts && forge test --match-test test_inflation_attack_fails_after_fix -vv 2>&1 | tail -30
```
Expected: test FAILS. The victim's withdrawal returns near zero (rounded-down LP minted on deposit). This is the red baseline.

- [ ] **Step 3: Add virtual-shares constants to Pool**

Edit `contracts/src/ArcoraDexPool.sol`. Find the existing constants block (currently around lines 22–27):
```solidity
    uint16  public  constant MAX_SWAP_FEE_BPS              = 100;
    uint16  public  constant MAX_PROTOCOL_FEE_SHARE_BPS    = 2500;
    uint256 public  constant MINIMUM_LIQUIDITY             = 1000;
    uint256 public  constant MAX_STALE_SECONDS             = 1 hours;
    uint256 internal constant BPS                          = 10_000;
    address public  constant DEAD_ADDRESS                  = address(0xdead);
```

Replace with (note: `MAX_STALE_SECONDS` removed because Task 2 made staleness per-token; if it was somehow left in Task 2's diff for safety, remove it now):
```solidity
    uint16  public  constant MAX_SWAP_FEE_BPS              = 100;
    uint16  public  constant MAX_PROTOCOL_FEE_SHARE_BPS    = 2500;
    uint256 public  constant MINIMUM_LIQUIDITY             = 1000;
    uint256 internal constant BPS                          = 10_000;
    address public  constant DEAD_ADDRESS                  = address(0xdead);

    /// @dev Virtual-shares offset (ERC4626-style) to defeat the first-depositor
    /// inflation attack. Math always uses (supply + VIRTUAL_SHARES) and
    /// (NAV + VIRTUAL_ASSETS) so the attacker cannot disproportionately
    /// benefit from direct transfers to the pool.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
```

If Task 2 left `MAX_STALE_SECONDS` in place by accident, also remove it here.

- [ ] **Step 4: Rewrite deposit's LP math with virtual offset**

In `contracts/src/ArcoraDexPool.sol`, find the deposit function block (around lines 127–141):
```solidity
        uint256 supply  = LP.totalSupply();
        uint256 navBefore;
        if (supply == 0) {
            if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
            lpMinted  = usdIn - MINIMUM_LIQUIDITY;
            navBefore = 0;
        } else {
            navBefore = _totalReservesUSDMut();
            lpMinted  = (usdIn * supply) / navBefore;
        }
        if (lpMinted < minLpOut) revert InsufficientLpOut(lpMinted, minLpOut);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        reserves[token] += amount;

        if (supply == 0) {
            LP.mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
        }
        LP.mint(msg.sender, lpMinted);
```

Replace with:
```solidity
        uint256 supply  = LP.totalSupply();
        uint256 navBefore;
        if (supply == 0) {
            if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
            // Unified formula: with supply=0 and nav=0, becomes (usdIn * VIRTUAL_SHARES) / VIRTUAL_ASSETS = usdIn * 1e6
            lpMinted  = (usdIn * (0 + VIRTUAL_SHARES)) / (0 + VIRTUAL_ASSETS);
            navBefore = 0;
        } else {
            navBefore = _totalReservesUSDMut();
            lpMinted  = (usdIn * (supply + VIRTUAL_SHARES)) / (navBefore + VIRTUAL_ASSETS);
        }
        if (lpMinted < minLpOut) revert InsufficientLpOut(lpMinted, minLpOut);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        reserves[token] += amount;

        if (supply == 0) {
            LP.mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
        }
        LP.mint(msg.sender, lpMinted);
```

- [ ] **Step 5: Rewrite withdraw's redemption math with virtual offset**

Find the withdraw function block (around lines 161–179):
```solidity
        uint256 navBefore = _totalReservesUSDMut();
        uint256 usdRedeemed = (lpAmount * navBefore) / LP.totalSupply();
```

Replace with:
```solidity
        uint256 navBefore = _totalReservesUSDMut();
        uint256 usdRedeemed = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (LP.totalSupply() + VIRTUAL_SHARES);
```

- [ ] **Step 6: Rewrite quoteDeposit and quoteWithdraw to mirror**

Find `quoteDeposit` (around lines 260–274). Replace:
```solidity
        uint256 supply = LP.totalSupply();
        if (supply == 0) {
            if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
            lpOut = usdIn - MINIMUM_LIQUIDITY;
        } else {
            uint256 nav = totalReservesUSD();
            lpOut = (usdIn * supply) / nav;
        }
```
With:
```solidity
        uint256 supply = LP.totalSupply();
        if (supply == 0) {
            if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
            lpOut = (usdIn * (0 + VIRTUAL_SHARES)) / (0 + VIRTUAL_ASSETS);
        } else {
            uint256 nav = totalReservesUSD();
            lpOut = (usdIn * (supply + VIRTUAL_SHARES)) / (nav + VIRTUAL_ASSETS);
        }
```

Find `quoteWithdraw` (around lines 276–292). Replace:
```solidity
            uint256 supply      = LP.totalSupply();
            uint256 navBefore   = totalReservesUSD();
            uint256 usdRedeemed = (lpAmount * navBefore) / supply;
```
With:
```solidity
            uint256 supply      = LP.totalSupply();
            uint256 navBefore   = totalReservesUSD();
            uint256 usdRedeemed = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (supply + VIRTUAL_SHARES);
```

- [ ] **Step 7: Recompile and run the inflation PoC**

Run:
```bash
cd contracts && forge build 2>&1 | tail -3
```
Expected: clean build.

Run:
```bash
cd contracts && forge test --match-test test_inflation_attack_fails_after_fix -vv 2>&1 | tail -10
```
Expected: PASS.

- [ ] **Step 8: Update existing tests whose math expectations changed**

Run the full suite to identify failures:
```bash
cd contracts && forge test 2>&1 | tail -25
```
Expected: most tests pass; any failures will involve hard-coded `lpMinted` or `lpAmount` expectations that no longer match.

For each failing test, update the expected LP amount: under virtual shares with `VIRTUAL_SHARES = 1e6`, the first depositor receives `usdIn * 1e6` LP instead of `usdIn - MINIMUM_LIQUIDITY` LP. Subsequent depositors receive proportionally larger amounts because the supply baseline is now 1e6× higher.

If a test asserts `lp1 == 999000` (legacy: 1e6 - 1000 = 999_000), update to `lp1 == 1_000_000_000_000` (1e18 × 1e6 / 1 = 1e24, but as LP units rounded → expect `usdIn * 1e6` where usdIn is in 1e18 USD-wei).

The implementer should run each failing test with `-vvv` to see the exact computed vs expected value, then update the assertion. **Do not loosen assertions** (e.g. don't change `assertEq` to `assertApproxEqAbs` without justification); compute the new exact value.

- [ ] **Step 9: Run full test suite, confirm green**

Run:
```bash
cd contracts && forge test 2>&1 | tail -5
```
Expected: all tests pass; total count ≥ baseline + 7 (Task 2's six new + this task's one new).

- [ ] **Step 10: Commit**

Run:
```bash
git add contracts/src/ArcoraDexPool.sol \
        contracts/test/ArcoraDexPool.security.t.sol \
        contracts/test/ArcoraDexPool.t.sol \
        contracts/test/ArcoraDexPool.fuzz.t.sol \
        contracts/test/ArcoraDexPool.invariant.t.sol
git commit -m "$(cat <<'EOF'
feat(contracts): virtual shares against first-depositor inflation (#A)

Closes audit finding #A (CRITICAL): the pre-fix pool was vulnerable to
the Uniswap V2 inflation attack — an attacker depositing the smallest
possible amount first, then donating tokens directly to the pool,
caused subsequent small deposits to round down to zero LP minted.

Fix: adopt the OpenZeppelin ERC4626 virtual-offset pattern. All
LP-shares conversions use (supply + VIRTUAL_SHARES) and
(NAV + VIRTUAL_ASSETS) with VIRTUAL_SHARES = 1e6 and VIRTUAL_ASSETS = 1.
MINIMUM_LIQUIDITY = 1000 and the DEAD-address mint are kept for
defense-in-depth; the virtual offset alone closes the attack but the
existing semantics avoid disrupting audit baselines.

Affected math: deposit(), withdraw(), quoteDeposit(), quoteWithdraw().
Storage: unchanged (constants only).

PoC test demonstrates: post-fix a victim depositing 1% of an attacker's
inflation amount recovers ≥99% of deposit; attacker's withdrawal loses
substantial value to the pool.

Spec: docs/superpowers/specs/2026-05-14-phase1-contract-fixes-design.md §3.1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: #B JIT/MEV sandwich — 1-hour LP min-hold (1 PR)

**Files:**
- Modify: `contracts/src/interfaces/IArcoraDexPool.sol` (uncomment the `lastMintAt` view from Task 2)
- Modify: `contracts/src/ArcoraDexPool.sol`
- Modify: `contracts/test/ArcoraDexPool.security.t.sol` (add MEV PoC)
- Modify: existing test files (add `vm.warp` before all withdraw calls)

- [ ] **Step 1: Write the MEV PoC test (red phase)**

Append to `contracts/test/ArcoraDexPool.security.t.sol`:

```solidity
    function test_jit_mev_blocked_by_min_hold() public {
        address bot = address(0xB07);
        usdc.mint(bot, 1_000_000_000); // 1000 USDC

        vm.startPrank(bot);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60); // 100 USDC
        uint256 botLp = pool.LP().balanceOf(bot);

        // Simulate keeper oracle update (price up)
        vm.stopPrank();
        vm.prank(DEPLOYER);
        fUsdc.setAnswer(100_500_000); // 0.5% up
        vm.startPrank(bot);

        // Immediate withdraw must revert (1h min-hold)
        vm.expectRevert(); // EarlyWithdraw selector
        pool.withdraw(address(usdc), botLp, 0, block.timestamp + 60);

        // After 59m 59s — still blocked
        vm.warp(block.timestamp + 1 hours - 1);
        vm.expectRevert();
        pool.withdraw(address(usdc), botLp, 0, block.timestamp + 60);

        // After exactly 1h from mint — allowed
        vm.warp(block.timestamp + 1);
        pool.withdraw(address(usdc), botLp, 0, block.timestamp + 60);
        vm.stopPrank();

        assertGt(usdc.balanceOf(bot), 0, "withdraw should succeed after 1h");
    }
```

- [ ] **Step 2: Verify test fails (no fix yet)**

Run:
```bash
cd contracts && forge test --match-test test_jit_mev_blocked_by_min_hold -vv 2>&1 | tail -15
```
Expected: FAILS at the first `vm.expectRevert` (withdraw currently succeeds immediately).

- [ ] **Step 3: Uncomment `lastMintAt` view in interface**

Edit `contracts/src/interfaces/IArcoraDexPool.sol`. Find the previously commented line:
```solidity
    // function lastMintAt(address account) external view returns (uint256); // added in Task 4
```
Replace with:
```solidity
    function lastMintAt(address account) external view returns (uint256);
```

- [ ] **Step 4: Add `lastMintAt` storage + `MIN_HOLD_SECONDS` constant to Pool**

Edit `contracts/src/ArcoraDexPool.sol`. In the storage section (after the `lastValidPriceAt` mapping added in Task 2), add:
```solidity
    mapping(address account => uint256) public override lastMintAt;
```

In the constants section (after `VIRTUAL_ASSETS` from Task 3), add:
```solidity
    /// @dev LP token min-hold period to defeat JIT/MEV sandwich attacks
    /// that try to capture oracle-update NAV deltas via atomic deposit-then-withdraw.
    /// Keeper cadence is 30 min; 1 hour guarantees at least one oracle cycle elapsed.
    uint256 public constant MIN_HOLD_SECONDS = 1 hours;
```

- [ ] **Step 5: Update `deposit()` to set `lastMintAt`**

In `deposit()`, after the `LP.mint(msg.sender, lpMinted);` line (and before the `emit Deposited` line), add:
```solidity
        lastMintAt[msg.sender] = block.timestamp;
```

- [ ] **Step 6: Update `withdraw()` to enforce min-hold**

In `withdraw()`, find the existing `if (lpAmount == 0) revert ZeroAmount();` and immediately after it add:
```solidity
        uint256 unlockAt = lastMintAt[msg.sender] + MIN_HOLD_SECONDS;
        if (block.timestamp < unlockAt) revert EarlyWithdraw(unlockAt, block.timestamp);
```

- [ ] **Step 7: Recompile and run MEV PoC**

Run:
```bash
cd contracts && forge build 2>&1 | tail -3
```
Expected: clean build.

Run:
```bash
cd contracts && forge test --match-test test_jit_mev_blocked_by_min_hold -vv 2>&1 | tail -10
```
Expected: PASS.

- [ ] **Step 8: Update existing tests to bypass min-hold via `vm.warp`**

Run the full suite to identify failures:
```bash
cd contracts && forge test 2>&1 | tail -25
```
Expected: tests that deposit-then-withdraw in the same block now revert with `EarlyWithdraw`.

For each affected test:
- Insert `vm.warp(block.timestamp + 1 hours + 1);` between the last deposit and the first withdraw of each test
- The inflation-attack PoC test (Task 3 Step 1) already has `vm.warp(block.timestamp + 2 hours)` before withdraws — leave as-is

If a test depends on doing withdrawals in sequence (deposit, withdraw, deposit, withdraw), each subsequent deposit resets `lastMintAt`, so add `vm.warp` again before the second withdraw.

- [ ] **Step 9: Run full test suite, confirm green**

Run:
```bash
cd contracts && forge test 2>&1 | tail -5
```
Expected: all tests pass; total count ≥ baseline + 8.

- [ ] **Step 10: Commit**

Run:
```bash
git add contracts/src/interfaces/IArcoraDexPool.sol \
        contracts/src/ArcoraDexPool.sol \
        contracts/test/ArcoraDexPool.security.t.sol \
        contracts/test/ArcoraDexPool.t.sol \
        contracts/test/ArcoraDexPool.fuzz.t.sol \
        contracts/test/ArcoraDexPool.invariant.t.sol
git commit -m "$(cat <<'EOF'
feat(contracts): 1-hour LP min-hold against JIT/MEV sandwich (#B)

Closes audit finding #B (HIGH): an MEV bot could deposit, wait for a
keeper oracle update in the same MEV bundle (~1 block), and withdraw —
capturing the NAV delta on capital it never actually exposed to risk.

Fix: add `lastMintAt[address]` storage updated on every deposit, and a
`MIN_HOLD_SECONDS = 1 hours` constant. withdraw() reverts EarlyWithdraw
if block.timestamp < lastMintAt + MIN_HOLD_SECONDS. The 1-hour value
is chosen to guarantee at least one full keeper cycle (30 min cadence)
elapses between mint and burn — making profitable JIT bundling
infeasible.

LP tokens remain freely transferable; the hold tracks the depositor's
address, not the LP itself. An LP that holds >1h on one wallet then
transfers to a fresh wallet can withdraw immediately — this is the
intended behavior (no longer the bot scenario).

Existing tests updated with vm.warp inserts between deposit and
withdraw operations.

Spec: docs/superpowers/specs/2026-05-14-phase1-contract-fixes-design.md §3.2

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: #C Quote↔execute gap — quote() applies ratchet check (1 PR)

**Files:**
- Modify: `contracts/src/ArcoraDexPool.sol` (add `_readUsdPrice1e18WithGuard`; route quote functions through it)
- Modify: `contracts/test/ArcoraDexPool.security.t.sol` (add quote-gap PoC)

- [ ] **Step 1: Write the quote-gap PoC test (red phase)**

Append to `contracts/test/ArcoraDexPool.security.t.sol`:

```solidity
    function test_quote_reverts_when_swap_would_revert() public {
        // Seed pool liquidity
        usdc.mint(ALICE, 1_000_000_000);
        eurc.mint(ALICE, 1_000_000_000);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60);
        pool.deposit(address(eurc), 100_000_000, 0, block.timestamp + 60);
        vm.stopPrank();

        // Walk EURC's ratchet to a frozen baseline by a swap that established lastAcceptedPrice
        // (Done implicitly by the deposit above; lastAcceptedPrice[eurc] = 1.1e18 now)

        // Move oracle 5% up — far beyond EURC's 150 bps cap
        vm.prank(DEPLOYER);
        fEurc.setAnswer(115_500_000); // $1.155

        // quote() should revert PriceDeviation (matches what swap() would do)
        vm.expectRevert();
        pool.quote(address(usdc), address(eurc), 10_000_000);

        // swap() must revert with the same reason
        usdc.mint(address(this), 10_000_000);
        usdc.approve(address(pool), 10_000_000);
        vm.expectRevert();
        pool.swap(address(usdc), address(eurc), 10_000_000, 0, block.timestamp + 60, address(this));

        // After syncAcceptedPrice, both succeed
        vm.prank(DEPLOYER);
        pool.syncAcceptedPrice(address(eurc));

        uint256 q = pool.quote(address(usdc), address(eurc), 10_000_000);
        assertGt(q, 0, "quote should return a value after sync");
    }
```

- [ ] **Step 2: Verify test fails on the first `vm.expectRevert(pool.quote(...))`**

Run:
```bash
cd contracts && forge test --match-test test_quote_reverts_when_swap_would_revert -vv 2>&1 | tail -20
```
Expected: FAILS — `quote()` returns a value (no revert) where the test expects revert.

- [ ] **Step 3: Add `_readUsdPrice1e18WithGuard` to Pool**

Edit `contracts/src/ArcoraDexPool.sol`. Immediately after the `_readUsdPrice1e18View` function (added in Task 2), add:

```solidity
    /// @dev View equivalent of _readAndGuardPrice's ratchet check.
    /// Returns price1e18 if a hypothetical swap would pass the deviation guard;
    /// reverts with PriceDeviation if it would fail. Does NOT mutate state.
    /// Used by quote*() so consumers see the same revert conditions as swap().
    function _readUsdPrice1e18WithGuard(address token)
        internal view returns (uint256 price1e18, uint8 tokenDecimals)
    {
        (price1e18, tokenDecimals) = _readUsdPrice1e18View(token);
        IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        uint256 prev = lastAcceptedPrice[token];
        if (prev != 0) {
            uint256 diff = price1e18 > prev ? price1e18 - prev : prev - price1e18;
            if (diff * BPS > prev * uint256(info.maxOracleDeviationBps)) {
                revert PriceDeviation(token, price1e18, prev, info.maxOracleDeviationBps);
            }
        }
    }
```

- [ ] **Step 4: Route `quote()` through the guard**

Find the existing `quote()` function (around lines 249–258):
```solidity
    function quote(address tokenIn, address tokenOut, uint256 amountIn)
        external view override returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut) revert SameToken(tokenIn);
        if (amountIn == 0)       revert ZeroAmount();
        (uint256 pIn,  uint8 dIn ) = _readUsdPrice1e18(tokenIn);
        (uint256 pOut, uint8 dOut) = _readUsdPrice1e18(tokenOut);
        uint256 gross = _grossOut(amountIn, pIn, pOut, dIn, dOut);
        amountOut     = gross - (gross * swapFeeBps) / BPS;
    }
```
Note: the old `_readUsdPrice1e18` no longer exists (deleted in Task 2). The implementer working through Tasks 2–4 may have left these calls pointing to `_readUsdPrice1e18View` — that's fine; replace with the guard variant:
```solidity
    function quote(address tokenIn, address tokenOut, uint256 amountIn)
        external view override returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut) revert SameToken(tokenIn);
        if (amountIn == 0)       revert ZeroAmount();
        (uint256 pIn,  uint8 dIn ) = _readUsdPrice1e18WithGuard(tokenIn);
        (uint256 pOut, uint8 dOut) = _readUsdPrice1e18WithGuard(tokenOut);
        uint256 gross = _grossOut(amountIn, pIn, pOut, dIn, dOut);
        amountOut     = gross - (gross * swapFeeBps) / BPS;
    }
```

- [ ] **Step 5: Route `quoteDeposit()` and `quoteWithdraw()` through the guard**

Find `quoteDeposit` and the `_readUsdPrice1e18View` call inside; replace with `_readUsdPrice1e18WithGuard`.

Find `quoteWithdraw` and replace its `_readUsdPrice1e18View` call with `_readUsdPrice1e18WithGuard`.

Note: `totalReservesUSD()` (view shim, used internally by these quote functions) keeps using `_readUsdPrice1e18View` — NAV computation should reflect oracle reality without the ratchet check, otherwise NAV becomes artificially stale.

- [ ] **Step 6: Recompile and run quote-gap PoC**

Run:
```bash
cd contracts && forge build 2>&1 | tail -3
```
Expected: clean build.

Run:
```bash
cd contracts && forge test --match-test test_quote_reverts_when_swap_would_revert -vv 2>&1 | tail -10
```
Expected: PASS.

- [ ] **Step 7: Run full test suite**

Run:
```bash
cd contracts && forge test 2>&1 | tail -5
```
Expected: all tests pass; total count ≥ baseline + 9.

If any pre-existing quote tests now fail because they expected a successful quote under stale ratchet conditions, update those tests to first call `syncAcceptedPrice` (as owner) or to assert the revert is expected.

- [ ] **Step 8: Commit**

Run:
```bash
git add contracts/src/ArcoraDexPool.sol \
        contracts/test/ArcoraDexPool.security.t.sol \
        contracts/test/ArcoraDexPool.t.sol
git commit -m "$(cat <<'EOF'
feat(contracts): quote() applies ratchet check, matches swap() (#C)

Closes audit finding #C (MEDIUM): pre-fix, quote() used the raw oracle
price while swap() applied the lastAcceptedPrice deviation ratchet.
Consumers (SDK / frontend) could display a successful quote that
reverted at swap time once the ratchet caught up — a broken UX promise
and a foot-gun for integrators.

Fix: new internal _readUsdPrice1e18WithGuard performs the same
deviation check as _readAndGuardPrice but without mutating state.
quote(), quoteDeposit(), and quoteWithdraw() all route through it. If
the swap would revert PriceDeviation, the quote now reverts identically.

totalReservesUSD() continues to use _readUsdPrice1e18View (no guard) so
NAV computation always reflects current oracle reality, independent of
whether a swap could currently execute. This is intentional: NAV is
not an "executable" quantity.

Breaking change for SDK / frontend consumers: quote() may now revert
where it previously returned an optimistic value. P5 SDK update covers
this.

Spec: docs/superpowers/specs/2026-05-14-phase1-contract-fixes-design.md §3.3

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Final acceptance — coverage, slither, fuzz, invariants

**Files:** none modified; verification only.

- [ ] **Step 1: Full forge test pass**

Run:
```bash
cd contracts && forge test 2>&1 | tail -5
```
Expected: total tests ≥ baseline + 9 (four PoCs + four registry tests + one auxiliary); zero failures.

- [ ] **Step 2: Coverage check**

Run:
```bash
cd contracts && forge coverage --report summary 2>&1 | grep -E "src/(ArcoraDex|interfaces|testnet)" | head -20
```
Expected: `contracts/src/ArcoraDexPool.sol` line coverage ≥85%, `ArcoraDexRegistry.sol` line coverage ≥85%, `MockChainlinkFeedV2.sol` ≥80%.

If coverage falls below threshold for either main contract, the implementer adds targeted tests for uncovered branches. Common gaps after this work:
- `setMaxStaleSeconds` happy path beyond the one added test (e.g. governance vs non-owner caller)
- `NoValidPrice` revert path on the view shim
- `_readUsdPrice1e18Mut` cache-write path under different oracle decimals

- [ ] **Step 3: Slither clean state**

Run:
```bash
cd contracts && slither . 2>&1 | tail -30 || echo "slither not available"
```
Expected: same set of warnings as baseline (rounding / calls-loop / reentrancy-benign), no new HIGH/MEDIUM findings. If slither flags the new `_readUsdPrice1e18Mut` cache-write inside a state-change-then-call sequence as reentrancy-benign or similar, suppress with an inline disable comment:
```solidity
// slither-disable-next-line reentrancy-benign
lastValidPrice[token] = price1e18;
```

- [ ] **Step 4: Fuzz invariants**

Run:
```bash
cd contracts && forge test --match-contract ArcoraDexPoolInvariant -vv 2>&1 | tail -10
```
Expected: all invariants pass. The pre-existing NAV-monotonicity invariant should hold under virtual shares; the cache-fallback path doesn't alter the invariant.

If an invariant now fails, the most likely cause is the cache returning a price that diverges from the live oracle during a fuzz handler run. Investigate; if the divergence is by design (fallback), update the invariant to use `lastValidPrice` instead of the oracle directly.

- [ ] **Step 5: Confirm no untouched concerns**

Manual diff review (cumulative diff against `main`):
```bash
git diff main --stat
```
Expected: four logical commits, only files listed in the File Structure section above.

Run:
```bash
grep -rn "MAX_STALE_SECONDS" contracts/src contracts/test 2>/dev/null
```
Expected: zero matches (the old global constant has been replaced with per-token `maxStaleSeconds` in Registry).

Run:
```bash
grep -rn "_readUsdPrice1e18(" contracts/src 2>/dev/null
```
Expected: only matches inside `_readUsdPrice1e18Mut`, `_readUsdPrice1e18View`, and `_readUsdPrice1e18WithGuard` (the old name is gone; the new names are explicit).

No commit — Task 6 is verification only.

---

### Task 7: Testnet redeploy + rollout doc (1 PR)

**Files:**
- Create: `contracts/script/DeployArcoraDexV2.s.sol`
- Create: `docs/rollouts/2026-05-14-phase1-deploy.md`

This task does the on-chain redeploy of the new Pool+Registry on Arc testnet and documents the new addresses, then freezes the old pool. The new pool is a fresh deployment — no liquidity migration script is written; founding LPs re-bootstrap via the faucet.

- [ ] **Step 1: Create the V2 deploy script**

Create `contracts/script/DeployArcoraDexV2.s.sol`. The script must:
1. Deploy a new `ArcoraDexRegistry` with the deployer as initial owner.
2. List all 7 stables on the new Registry with the same token addresses + existing V2 feed addresses + new `maxStaleSeconds` per token:
   - USDC, USDT, PYUSD, DAI: deviationBps = 50, maxStaleSeconds = 3600 (1h)
   - EURC: deviationBps = 150, maxStaleSeconds = 14400 (4h)
   - TRYC, BRLC: deviationBps = 5000, maxStaleSeconds = 86400 (24h). (P3 will tighten these.)
3. Deploy a new `ArcoraDexPool` against the new Registry with `initialSwapFeeBps = 5`, `initialProtocolFeeShareBps = 5000`, `initialOwner = deployer`.
4. Log all new addresses to a console output.

The token addresses and feed addresses to reuse (already verified on the VPS `.env`):
```
USDC token  0x3BFa09fF6467639f0981948385bA1018Ac07d22C  feed 0x2E6B862E1Ac74328238494B22317262004534B39
USDT token  0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B  feed 0x741af784a1d4C69843A1764099433160088a1c70
PYUSD token 0xfdB2c86d010698401f0b969348DC58b6659B96a3  feed 0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896
DAI token   0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE  feed 0xAAC5a5855deF9414f7330f350c2E00119C2097c8
EURC token  0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD  feed 0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170
TRYC token  0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61  feed 0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C
BRLC token  0xa13c0935A98e2c175b31A4054f698819271a8FfC  feed 0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d
```

Implementer drafts the script following the pattern of the existing `DeployArcoraDex.s.sol`, then dry-runs locally:
```bash
cd contracts && forge script script/DeployArcoraDexV2.s.sol --rpc-url https://rpc.testnet.arc.network 2>&1 | tail -20
```
Expected: simulation success; printed addresses for new Registry + new Pool + new LP.

- [ ] **Step 2: Broadcast the deploy**

Run:
```bash
cd contracts && forge script script/DeployArcoraDexV2.s.sol --rpc-url https://rpc.testnet.arc.network --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast 2>&1 | tail -30
```
Expected: all tx hashes printed; final summary lists new Registry / Pool / LP addresses.

Capture: `NEW_REGISTRY`, `NEW_POOL`, `NEW_LP`.

- [ ] **Step 3: Bootstrap initial liquidity**

The new pool starts with zero reserves. Bootstrap with a small founding deposit so swap math has something to work against. From the deployer (laptop):

Run (sample USDC bootstrap of $100 — adjust amounts as appropriate):
```bash
RPC=https://rpc.testnet.arc.network
DEADLINE=$(($(date +%s) + 300))
cast send 0x3BFa09fF6467639f0981948385bA1018Ac07d22C 'approve(address,uint256)(bool)' $NEW_POOL 100000000 --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url $RPC
cast send $NEW_POOL 'deposit(address,uint256,uint256,uint256)(uint256)' 0x3BFa09fF6467639f0981948385bA1018Ac07d22C 100000000 0 $DEADLINE --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url $RPC
```

Repeat for each of the 7 tokens. Confirm `totalReservesUSD()` returns the expected NAV.

- [ ] **Step 4: Freeze the old pool**

Old pool: `0x3051d24D771bAF44031571544a9159578035D0c5`.

Run:
```bash
cast send 0x3051d24D771bAF44031571544a9159578035D0c5 'pause()' --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url $RPC
cast call 0x3051d24D771bAF44031571544a9159578035D0c5 'paused()(bool)' --rpc-url $RPC
```
Expected: `paused() = true`.

- [ ] **Step 5: Write the rollout doc**

Create `docs/rollouts/2026-05-14-phase1-deploy.md` with sections:

```markdown
# Phase 1 Contract Fixes — Testnet Redeploy

**Date:** 2026-05-14
**Branch:** phase1/contract-fixes (merged to main)
**Spec:** docs/superpowers/specs/2026-05-14-phase1-contract-fixes-design.md

## Why redeploy

Both ArcoraDexRegistry and ArcoraDexPool gained storage extensions
(maxStaleSeconds on Registry, lastValidPrice/lastValidPriceAt/lastMintAt
on Pool). The contracts are not proxy-upgradable, so the new layout
ships as a fresh deploy. The old pool is paused and abandoned; the
mock $69k of NAV has no economic value.

## Old (frozen) addresses

- ArcoraDexRegistry  0x920E3E59DD37Be3D9D3750D7B912A9dd08db0D29  (paused, deprecated)
- ArcoraDexPool      0x3051d24D771bAF44031571544a9159578035D0c5  (paused, deprecated)
- ArcoraDexLP        0x7CEAbF411806A29ffaEbCAB2BF3Dc8a9ECBD110C  (orphaned)

## New addresses

- ArcoraDexRegistry  <NEW_REGISTRY>
- ArcoraDexPool      <NEW_POOL>
- ArcoraDexLP        <NEW_LP>
- Feeds (reused)     same as 2026-05-10 cutover (see arcoradex_role_eoas memory)

## Token listings (new pool)

| Symbol | Token | Feed | Deviation bps | maxStaleSeconds |
|--------|-------|------|---------------|-----------------|
| USDC   | 0x3BFa...d22C | 0x2E6B...4B39 | 50  | 3600 |
| USDT   | 0x342B...844B | 0x741a...1c70 | 50  | 3600 |
| PYUSD  | 0xfdB2...96a3 | 0x2285...1896 | 50  | 3600 |
| DAI    | 0xFf7d...afFE | 0xAAC5...97c8 | 50  | 3600 |
| EURC   | 0xe08E...73BD | 0x0656...A170 | 150 | 14400 |
| TRYC   | 0xD564...0e61 | 0xB49B...Df9C | 5000 | 86400 |
| BRLC   | 0xa13c...8FfC | 0x8Ee5...612d | 5000 | 86400 |

P3 will recalibrate TRYC/BRLC deviation and stale budgets based on
Chainlink heartbeat survey.

## Founding liquidity

| Token | Amount | Tx |
|-------|--------|----|
| USDC | 100 | <tx hash> |
| ...  | ... | ... |

## Downstream tasks

- [ ] Update SDK to point at NEW_POOL / NEW_REGISTRY / NEW_LP
- [ ] Update Vercel app env (NEXT_PUBLIC_POOL_ADDR, etc.)
- [ ] Update keeper `.env.example` if any addresses changed (feeds reused so likely no change)
- [ ] Update auto-memory `arcoradex_role_eoas.md` with new pool/registry addresses
- [ ] Announce in #ops channel (or wherever the team coordinates)

## Rollback

The old pool remains on-chain (paused). To re-enable:
1. Unpause the old pool via `cast send <old> 'unpause()'`
2. Update SDK addresses back
3. (Note: the old pool retains its $69k mock NAV; users with old LP can still withdraw post-unpause.)

No data migration was performed; rollback is purely a pointer swap.
```

Implementer fills in the actual addresses and tx hashes after Steps 2 & 3.

- [ ] **Step 6: Commit the deploy script + rollout doc**

Run:
```bash
git add contracts/script/DeployArcoraDexV2.s.sol \
        docs/rollouts/2026-05-14-phase1-deploy.md
git commit -m "$(cat <<'EOF'
chore(deploy): phase 1 testnet redeploy script + rollout doc

Fresh deploy script for the new Pool+Registry after the storage
extensions in P1. Existing tokens and V2 feeds reused; bootstrap
liquidity must be re-seeded since the old pool is frozen (paused, no
migration).

The rollout doc records:
- old (frozen) addresses
- new addresses
- per-token (deviation, maxStaleSeconds) settings
- founding-liquidity amounts and tx hashes
- downstream SDK/app/memory update checklist
- rollback procedure (unpause old pool, swap addresses)

Spec: docs/superpowers/specs/2026-05-14-phase1-contract-fixes-design.md §4

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Final pre-merge checks

**Files:** none modified.

- [ ] **Step 1: Summary diff against main**

Run:
```bash
git log --oneline main..HEAD
```
Expected: five commits on branch:
```
<sha> chore(deploy): phase 1 testnet redeploy script + rollout doc
<sha> feat(contracts): quote() applies ratchet check, matches swap() (#C)
<sha> feat(contracts): 1-hour LP min-hold against JIT/MEV sandwich (#B)
<sha> feat(contracts): virtual shares against first-depositor inflation (#A)
<sha> feat(contracts): per-token staleness + cached price fallback (#4)
```

Run:
```bash
git diff main --stat
```
Expected: only files listed in the File Structure section.

- [ ] **Step 2: Run forge test + slither + coverage one last time**

Run:
```bash
cd contracts && forge build && forge test
```
Expected: ≥86 tests passing (77 baseline + ≥9 new).

Run:
```bash
cd contracts && slither . 2>&1 | tail -20
```
Expected: same warnings as baseline; no new HIGH/MEDIUM.

Run:
```bash
cd contracts && forge coverage --report summary 2>&1 | tail -10
```
Expected: ≥85% line coverage on `contracts/src/`.

- [ ] **Step 3: Update auto-memory**

Update `~/.claude/projects/-Users-huseyinarslan-Desktop-arcora-v0-7-shared-vault-pool/memory/arcoradex_role_eoas.md` to record the new Pool/Registry addresses from Task 7. (No git commit — memory is outside repo.)

- [ ] **Step 4: STOP. Hand back to operator for PR creation and review.**

The plan does not open the PR. The operator opens it after reviewing the local branch.

---

## Rollback

Each finding ships as its own commit on the same branch; reverting any one is `git revert <sha>` followed by re-running `forge test`. Order-dependence means reverting Task 2 (#4) requires also reverting Tasks 3–5 in reverse order because the storage and reader split they build on would no longer compile.

On-chain rollback (after Task 7 deploy): unpause the old pool, swap SDK/app pointers back, leave new pool paused. No on-chain state migration was performed in either direction.
