# Phase 3 — Oracle Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close audit finding #1 (TRYC/BRLC writer-compromise drain) and the P1/P2 oracle-layer residuals (reverting-oracle availability gap, redundant double oracle read, on-chain rolling deviation observability) via three coordinated changes: Pool fixes (Task A), 2-source `OracleAggregator` deployed per token (Task B), and event-only `CumulativeDeviationGuard` (Task C). Migration goes through the P2 governance stack via `Timelock.scheduleBatch` + 48 h delay.

**Architecture:** Pool changes are minimal: `_readOracle` gets a try/catch so reverting oracles fall through to the cache fallback, and `_readUsdPrice1e18WithGuard` is refactored to a single internal read. The aggregator is a thin `IChainlinkAggregator` wrapper around two MockChainlinkFeedV2 instances that returns the 2-source average if they agree within a configurable divergence cap and reverts otherwise. The guard tracks a tumbling 24 h window per token and emits structured events for off-chain monitoring (no on-chain auto-pause in P3).

**Tech Stack:** Solidity 0.8.26, Foundry, OpenZeppelin v5 (`Ownable2Step`, `TimelockController.scheduleBatch`), existing P2 Safe v1.4.1 governance.

**Spec:** `docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md`
**Parent roadmap:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §5

---

## File Structure

### Files modified
| File | Changes |
|------|---------|
| `contracts/src/ArcoraDexPool.sol` | Wrap `latestRoundData()` + `decimals()` in `_readOracle` in try/catch (Task A1); refactor `_readUsdPrice1e18WithGuard` to a single oracle read (Task A2) |
| `contracts/test/ArcoraDexPool.t.sol` | Add `test_pool_handles_reverting_oracle` + a soft gas-snapshot assertion |

### Files created
| File | Purpose |
|------|---------|
| `contracts/src/oracle/OracleAggregator.sol` | 2-source `IChainlinkAggregator` wrapper with divergence guard |
| `contracts/src/oracle/CumulativeDeviationGuard.sol` | 24 h tumbling-window deviation tracker, event-only |
| `contracts/test/oracle/P3Aggregator.t.sol` | 5 aggregator tests + 1 governance-integration test |
| `contracts/test/oracle/P3CircuitBreaker.t.sol` | 4 guard tests |
| `contracts/test/oracle/RevertingMockFeed.sol` | tiny helper contract: always reverts on `latestRoundData()`, used by aggregator + Pool tests |
| `contracts/script/DeployOraclesP3.s.sol` | Deploys 7 secondary feeds + 7 aggregators + 1 guard, transfers ownership to Governance Safe |
| `docs/rollouts/2026-05-14-phase3-oracle.md` | Live addresses, schedule/execute runbook, downstream checklist |

### Branches
- `phase3/oracle-hardening` (already exists with the spec)
- After this PR (planning) merges, implementation proceeds on `phase3/oracle-rollout`

---

### Task 1: Branch setup and baseline verification

**Files:** none modified.

- [ ] **Step 1: Confirm planning PR has merged to main**

Run:
```bash
git checkout main && git pull --ff-only origin main
git log -1 --format='%h %s'
```
Expected: HEAD subject mentions the P3 planning merge (e.g. `docs(spec): phase 3 oracle hardening design (2026-05-14)` or its merge commit).

- [ ] **Step 2: Create the implementation branch**

```bash
git checkout -b phase3/oracle-rollout
```

- [ ] **Step 3: Establish forge test baseline**

```bash
cd contracts && forge build && forge test 2>&1 | tail -3
```
Expected: `101 tests passed, 0 failed, 0 skipped` (post-P2 baseline).

- [ ] **Step 4: Confirm deployer ARC balance**

```bash
cast balance 0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b --rpc-url https://rpc.testnet.arc.network --ether
```
Expected: ≥ 1.0 ARC (P3 deploy is smaller than P2; estimate ~0.3 ARC gas + Safe ops). Top up if below.

- [ ] **Step 5: Confirm Governance Safe exists**

```bash
cast call 0x715f669D79Cc72d6685F8724c0B86f7B53d7e624 'getThreshold()(uint256)' --rpc-url https://rpc.testnet.arc.network
```
Expected: `3`. If different, P2 governance state needs investigation before proceeding.

No commit — Task 1 is verification only.

---

### Task 2: Pool try/catch on `_readOracle` (A1)

**Files:**
- Modify: `contracts/src/ArcoraDexPool.sol`
- Create: `contracts/test/oracle/RevertingMockFeed.sol`
- Modify: `contracts/test/ArcoraDexPool.t.sol`

- [ ] **Step 1: Create the reverting mock feed helper**

Create `contracts/test/oracle/RevertingMockFeed.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IChainlinkAggregator } from "../../src/interfaces/IChainlinkAggregator.sol";

/// @notice Test helper: a Chainlink-shape feed whose `latestRoundData()` always reverts.
/// Used to verify the Pool's try/catch handles reverting oracles by falling back to cache.
contract RevertingMockFeed is IChainlinkAggregator {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        pure
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert("oracle unavailable");
    }
}
```

- [ ] **Step 2: Write the failing test in `ArcoraDexPool.t.sol`**

Find the test contract and append:

```solidity
    // ── P3 Task 2: reverting oracle falls back to cache (A1) ──
    function test_pool_handles_reverting_oracle() public {
        // Setup: seed USDC cache via a successful deposit using the existing feed
        usdc.mint(address(this), 100_000_000);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60);
        uint256 cachedPrice = pool.lastValidPrice(address(usdc));
        assertGt(cachedPrice, 0, "cache should be seeded by deposit");

        // Swap the USDC oracle for a reverting feed via the registry (test contract is registry owner)
        RevertingMockFeed bad = new RevertingMockFeed(8);
        reg.setOracle(address(usdc), IChainlinkAggregator(address(bad)));

        // totalReservesUSD() should now use the cached USDC price, not revert
        uint256 nav = pool.totalReservesUSD();
        assertGt(nav, 0, "NAV must remain queryable via cache when oracle reverts");

        // A subsequent deposit must also succeed by reading the cache
        usdc.mint(address(this), 50_000_000);
        pool.deposit(address(usdc), 50_000_000, 0, block.timestamp + 60);
    }
```

Add this import at the top of the file if missing:
```solidity
import { RevertingMockFeed } from "./oracle/RevertingMockFeed.sol";
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd contracts && forge test --match-test test_pool_handles_reverting_oracle -vv 2>&1 | tail -10
```
Expected: FAIL — the call to `pool.totalReservesUSD()` or `pool.deposit(...)` reverts with `"oracle unavailable"` because `_readOracle` does not currently catch reverts.

- [ ] **Step 4: Wrap `latestRoundData()` in try/catch**

Edit `contracts/src/ArcoraDexPool.sol`. Find the `_readOracle` function (added in P1 Task 2). Currently:

```solidity
    function _readOracle(address token)
        internal view
        returns (uint256 price1e18, uint8 tokenDecimals, bool isFresh)
    {
        IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        if (!info.isActive) revert TokenNotActive(token);
        tokenDecimals = info.decimals;

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            info.usdOracle.latestRoundData();

        bool roundOk     = (roundId != 0 && answeredInRound >= roundId);
        bool timestampOk = (updatedAt != 0 && updatedAt <= block.timestamp);
        bool ageOk       = timestampOk && (block.timestamp - updatedAt) <= info.maxStaleSeconds;
        bool answerOk    = (answer > 0);

        isFresh = roundOk && timestampOk && ageOk && answerOk;
        if (isFresh) {
            uint8 oracleDec = info.usdOracle.decimals();
            if (oracleDec == 18)      price1e18 = uint256(answer);
            else if (oracleDec < 18)  price1e18 = uint256(answer) * (10 ** (18 - oracleDec));
            else                      price1e18 = uint256(answer) / (10 ** (oracleDec - 18));
        }
    }
```

Replace with:

```solidity
    function _readOracle(address token)
        internal view
        returns (uint256 price1e18, uint8 tokenDecimals, bool isFresh)
    {
        IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        if (!info.isActive) revert TokenNotActive(token);
        tokenDecimals = info.decimals;

        try info.usdOracle.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            bool roundOk     = (roundId != 0 && answeredInRound >= roundId);
            bool timestampOk = (updatedAt != 0 && updatedAt <= block.timestamp);
            bool ageOk       = timestampOk && (block.timestamp - updatedAt) <= info.maxStaleSeconds;
            bool answerOk    = (answer > 0);

            isFresh = roundOk && timestampOk && ageOk && answerOk;
            if (isFresh) {
                try info.usdOracle.decimals() returns (uint8 oracleDec) {
                    if (oracleDec == 18)      price1e18 = uint256(answer);
                    else if (oracleDec < 18)  price1e18 = uint256(answer) * (10 ** (18 - oracleDec));
                    else                      price1e18 = uint256(answer) / (10 ** (oracleDec - 18));
                } catch {
                    // decimals() reverted — treat the full read as failed
                    isFresh = false;
                    price1e18 = 0;
                }
            }
        } catch {
            // latestRoundData() reverted — fall through to cache (callers handle via isFresh=false)
            isFresh = false;
        }
    }
```

- [ ] **Step 5: Run the new test to verify it passes**

```bash
cd contracts && forge test --match-test test_pool_handles_reverting_oracle -vv 2>&1 | tail -10
```
Expected: PASS.

- [ ] **Step 6: Run the full suite**

```bash
cd contracts && forge test 2>&1 | tail -3
```
Expected: 101 baseline + 1 new = 102 tests passing. No regressions.

- [ ] **Step 7: Commit**

```bash
git add contracts/src/ArcoraDexPool.sol \
        contracts/test/oracle/RevertingMockFeed.sol \
        contracts/test/ArcoraDexPool.t.sol
git commit -m "$(cat <<'EOF'
feat(contracts): try/catch on _readOracle for revert resilience (A1)

Closes the P1 final-review Important #1: when an oracle contract
reverts on latestRoundData() or decimals() (e.g., deactivated
AccessControlled Chainlink feed, malicious aggregator), the call
previously bubbled up through totalReservesUSD and reverted every
deposit and withdraw globally. Same availability class as #4 but
triggered by revert rather than staleness.

Fix: wrap both external oracle calls in try/catch. On revert, set
isFresh=false and let the existing cache-fallback path in
_readUsdPrice1e18Mut/View handle the response.

New test contract RevertingMockFeed always reverts on
latestRoundData(); test_pool_handles_reverting_oracle verifies the
pool keeps operating via the cache when this feed is swapped in via
Registry.setOracle.

Spec: docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md §5

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Refactor `_readUsdPrice1e18WithGuard` to single read (A2)

**Files:**
- Modify: `contracts/src/ArcoraDexPool.sol`

- [ ] **Step 1: Capture pre-refactor gas baseline**

```bash
cd contracts && forge snapshot --match-test "test_quote_" --snap .gas-baseline-pre-a2 2>&1 | tail -5
```
Expected: snapshot file written. Note the gas numbers (will compare after the refactor).

- [ ] **Step 2: Find and refactor `_readUsdPrice1e18WithGuard`**

Edit `contracts/src/ArcoraDexPool.sol`. Find the function (currently makes two oracle reads — one via `_readOracle`, one via `_readUsdPrice1e18View`):

```solidity
    function _readUsdPrice1e18WithGuard(address token)
        internal view returns (uint256 price1e18, uint8 tokenDecimals)
    {
        IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        uint256 prev = lastAcceptedPrice[token];

        // First oracle read
        uint256 rawPrice1e18;
        bool isFresh;
        (rawPrice1e18, tokenDecimals, isFresh) = _readOracle(token);

        if (isFresh && prev != 0) {
            uint256 diff = rawPrice1e18 > prev ? rawPrice1e18 - prev : prev - rawPrice1e18;
            if (diff * BPS > prev * uint256(info.maxOracleDeviationBps)) {
                revert PriceDeviation(token, rawPrice1e18, prev, info.maxOracleDeviationBps);
            }
        }

        // Second oracle read (redundant!) for canonical return value
        (price1e18, tokenDecimals) = _readUsdPrice1e18View(token);

        if (!isFresh && prev != 0) {
            uint256 diff = price1e18 > prev ? price1e18 - prev : prev - price1e18;
            if (diff * BPS > prev * uint256(info.maxOracleDeviationBps)) {
                revert PriceDeviation(token, price1e18, prev, info.maxOracleDeviationBps);
            }
        }
    }
```

Replace with the single-read version:

```solidity
    function _readUsdPrice1e18WithGuard(address token)
        internal view returns (uint256 price1e18, uint8 tokenDecimals)
    {
        IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        uint256 prev = lastAcceptedPrice[token];

        // Single oracle read; resolve fresh-vs-cache locally.
        bool isFresh;
        uint256 rawPrice1e18;
        (rawPrice1e18, tokenDecimals, isFresh) = _readOracle(token);

        // If fresh, apply the same cache-deviation guard as _readUsdPrice1e18View
        // would have. Otherwise fall back to the cached price.
        if (isFresh) {
            uint256 cached = lastValidPrice[token];
            if (cached != 0) {
                uint256 d = rawPrice1e18 > cached ? rawPrice1e18 - cached : cached - rawPrice1e18;
                if (d * BPS > cached * uint256(info.maxOracleDeviationBps)) {
                    isFresh = false;
                }
            }
        }

        price1e18 = isFresh ? rawPrice1e18 : lastValidPrice[token];
        if (price1e18 == 0) revert NoValidPrice(token);

        // Apply the lastAcceptedPrice ratchet check (same semantics as before).
        if (prev != 0) {
            uint256 diff = price1e18 > prev ? price1e18 - prev : prev - price1e18;
            if (diff * BPS > prev * uint256(info.maxOracleDeviationBps)) {
                revert PriceDeviation(token, price1e18, prev, info.maxOracleDeviationBps);
            }
        }
    }
```

- [ ] **Step 3: Run quote-related tests**

```bash
cd contracts && forge test --match-test "test_quote_|test_pool_handles_reverting_oracle" -vv 2>&1 | tail -15
```
Expected: all pass — behaviour is equivalent (the old version effectively did the cache-deviation check via `_readUsdPrice1e18View`, then re-applied a ratchet check; the new version inlines the cache-deviation check and applies a single ratchet check).

If any test fails, debug — most likely cause is a subtle difference in the ratchet check order. The semantic invariant is: if both rawPrice and cached are within their respective caps of `prev`, return the same `price1e18` as before.

- [ ] **Step 4: Run full suite + gas comparison**

```bash
cd contracts && forge test 2>&1 | tail -3
cd contracts && forge snapshot --match-test "test_quote_" --diff .gas-baseline-pre-a2 2>&1 | tail -10
```
Expected: 102 tests passing (no test count change). Gas snapshot diff shows quote-related tests use LESS gas (typical reduction: ~10–15 % per quote call).

- [ ] **Step 5: Delete the pre-refactor snapshot file**

```bash
rm contracts/.gas-baseline-pre-a2
```

- [ ] **Step 6: Commit**

```bash
git add contracts/src/ArcoraDexPool.sol
git commit -m "$(cat <<'EOF'
perf(contracts): single-read refactor of _readUsdPrice1e18WithGuard (A2)

Closes the P1 final-review Minor #1: _readUsdPrice1e18WithGuard
previously made two _readOracle calls per token per quote leg, paying
~4 external calls (latestRoundData + decimals × 2) per quote. Off-chain
consumers paid the cost.

Refactored to a single _readOracle call. Cache-deviation guard
(introduced in P1 Task 2) is now inlined directly rather than
delegated to _readUsdPrice1e18View. The lastAcceptedPrice ratchet
check runs once on the resolved price1e18 instead of being duplicated
across the fresh/stale branches.

Behaviour is unchanged: existing 41 quote-related tests pass without
modification. Gas snapshot shows ~10-15% reduction per quote.

Spec: docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md §5

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: OracleAggregator contract (B1)

**Files:**
- Create: `contracts/src/oracle/OracleAggregator.sol`
- Create: `contracts/test/oracle/P3Aggregator.t.sol`

- [ ] **Step 1: Write the 5 aggregator tests (red phase)**

Create `contracts/test/oracle/P3Aggregator.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IChainlinkAggregator } from "../../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeedV2 } from "../../src/testnet/MockChainlinkFeedV2.sol";
import { OracleAggregator } from "../../src/oracle/OracleAggregator.sol";
import { RevertingMockFeed } from "./RevertingMockFeed.sol";

contract P3AggregatorTest is Test {
    address constant OWNER = address(0x0a);
    MockChainlinkFeedV2 primary;
    MockChainlinkFeedV2 secondary;

    function setUp() public {
        primary   = new MockChainlinkFeedV2(8, 100_000_000, OWNER, OWNER); // $1.00
        secondary = new MockChainlinkFeedV2(8, 100_000_000, OWNER, OWNER); // $1.00
    }

    function test_aggregator_returns_average_within_divergence_cap() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200, // 2% divergence cap
            OWNER
        );
        // primary $1.00, secondary $1.01 → avg $1.005, within 200 bps
        vm.prank(OWNER);
        secondary.setAnswer(101_000_000);

        (, int256 ans, , , ) = agg.latestRoundData();
        assertEq(ans, int256(100_500_000), "avg of 1.00 and 1.01 = 1.005");
    }

    function test_aggregator_reverts_on_sources_diverge() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200, // 2% cap
            OWNER
        );
        // primary $1.00, secondary $1.05 → 5% divergence, exceeds 200 bps
        vm.prank(OWNER);
        secondary.setAnswer(105_000_000);

        vm.expectRevert(abi.encodeWithSelector(
            OracleAggregator.SourcesDiverge.selector,
            uint256(100_000_000), uint256(105_000_000), uint16(200)
        ));
        agg.latestRoundData();
    }

    function test_aggregator_returns_primary_when_secondary_reverts() public {
        RevertingMockFeed bad = new RevertingMockFeed(8);
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(bad)),
            200,
            OWNER
        );
        (, int256 ans, , , ) = agg.latestRoundData();
        assertEq(ans, int256(100_000_000), "should return primary when secondary reverts");
    }

    function test_aggregator_reverts_when_both_sources_revert() public {
        RevertingMockFeed bad1 = new RevertingMockFeed(8);
        RevertingMockFeed bad2 = new RevertingMockFeed(8);
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(bad1)),
            IChainlinkAggregator(address(bad2)),
            200,
            OWNER
        );
        vm.expectRevert(abi.encodeWithSelector(OracleAggregator.AllSourcesUnavailable.selector));
        agg.latestRoundData();
    }

    function test_setMaxDivergenceBps_onlyOwner() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,
            OWNER
        );

        // Non-owner reverts
        vm.expectRevert();
        agg.setMaxDivergenceBps(500);

        // Owner succeeds
        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit OracleAggregator.MaxDivergenceUpdated(200, 500);
        agg.setMaxDivergenceBps(500);
        assertEq(agg.maxDivergenceBps(), 500);
    }

    function test_constructor_reverts_on_decimals_mismatch() public {
        MockChainlinkFeedV2 sec6 = new MockChainlinkFeedV2(6, 1_000_000, OWNER, OWNER);
        vm.expectRevert(abi.encodeWithSelector(
            OracleAggregator.DecimalsMismatch.selector, uint8(8), uint8(6)
        ));
        new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(sec6)),
            200,
            OWNER
        );
    }
}
```

- [ ] **Step 2: Verify the tests fail to compile**

```bash
cd contracts && forge build 2>&1 | tail -10
```
Expected: failure citing missing `OracleAggregator` contract.

- [ ] **Step 3: Implement the OracleAggregator contract**

Create `contracts/src/oracle/OracleAggregator.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable }       from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }  from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IChainlinkAggregator } from "../interfaces/IChainlinkAggregator.sol";

/// @title OracleAggregator
/// @notice 2-source `IChainlinkAggregator` wrapper. Returns the average of the
/// two sources when they agree within `maxDivergenceBps`; reverts if they
/// diverge beyond that; falls back to a single source when the other reverts.
contract OracleAggregator is IChainlinkAggregator, Ownable2Step {
    IChainlinkAggregator public immutable PRIMARY;
    IChainlinkAggregator public immutable SECONDARY;
    uint8                public immutable DECIMALS_;
    uint16               public maxDivergenceBps;

    error SourcesDiverge(uint256 primary, uint256 secondary, uint16 capBps);
    error AllSourcesUnavailable();
    error DecimalsMismatch(uint8 primaryDec, uint8 secondaryDec);
    error InvalidDivergenceBps(uint16 bps);

    event MaxDivergenceUpdated(uint16 oldValue, uint16 newValue);

    constructor(
        IChainlinkAggregator primary_,
        IChainlinkAggregator secondary_,
        uint16 initialMaxDivergenceBps,
        address initialOwner
    ) Ownable(initialOwner) {
        if (initialMaxDivergenceBps == 0 || initialMaxDivergenceBps > 10_000) {
            revert InvalidDivergenceBps(initialMaxDivergenceBps);
        }
        uint8 pDec = primary_.decimals();
        uint8 sDec = secondary_.decimals();
        if (pDec != sDec) revert DecimalsMismatch(pDec, sDec);
        PRIMARY = primary_;
        SECONDARY = secondary_;
        DECIMALS_ = pDec;
        maxDivergenceBps = initialMaxDivergenceBps;
    }

    function decimals() external view override returns (uint8) {
        return DECIMALS_;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (bool pOk, int256 pAns, uint256 pAt) = _tryRead(PRIMARY);
        (bool sOk, int256 sAns, uint256 sAt) = _tryRead(SECONDARY);

        if (!pOk && !sOk) revert AllSourcesUnavailable();

        if (pOk && !sOk) return (1, pAns, pAt, pAt, 1);
        if (sOk && !pOk) return (1, sAns, sAt, sAt, 1);

        // Both succeeded — divergence check.
        uint256 absDiff = pAns > sAns ? uint256(pAns - sAns) : uint256(sAns - pAns);
        uint256 minAns  = pAns < sAns ? uint256(pAns) : uint256(sAns);
        if (absDiff * 10_000 > minAns * uint256(maxDivergenceBps)) {
            revert SourcesDiverge(uint256(pAns), uint256(sAns), maxDivergenceBps);
        }

        int256  mid    = (pAns + sAns) / 2;
        uint256 latest = pAt > sAt ? pAt : sAt;
        return (1, mid, latest, latest, 1);
    }

    function setMaxDivergenceBps(uint16 newBps) external onlyOwner {
        if (newBps == 0 || newBps > 10_000) revert InvalidDivergenceBps(newBps);
        emit MaxDivergenceUpdated(maxDivergenceBps, newBps);
        maxDivergenceBps = newBps;
    }

    /// @dev Returns (success, answer, updatedAt). Catches revert from source.
    /// Treats answer <= 0 as failure (Chainlink convention).
    function _tryRead(IChainlinkAggregator src)
        private
        view
        returns (bool ok, int256 answer, uint256 updatedAt)
    {
        try src.latestRoundData() returns (uint80, int256 a, uint256, uint256 u, uint80) {
            if (a > 0 && u > 0) {
                return (true, a, u);
            }
            return (false, 0, 0);
        } catch {
            return (false, 0, 0);
        }
    }
}
```

- [ ] **Step 4: Run the new tests**

```bash
cd contracts && forge build 2>&1 | tail -3
cd contracts && forge test --match-contract P3AggregatorTest -vv 2>&1 | tail -20
```
Expected: all 6 tests PASS (5 listed in the plan + the constructor decimals-mismatch test added during implementation).

- [ ] **Step 5: Run full suite**

```bash
cd contracts && forge test 2>&1 | tail -3
```
Expected: 102 (post-Task-3 baseline) + 6 = 108 tests passing.

- [ ] **Step 6: Commit**

```bash
git add contracts/src/oracle/OracleAggregator.sol \
        contracts/test/oracle/P3Aggregator.t.sol
git commit -m "$(cat <<'EOF'
feat(contracts): OracleAggregator — 2-source IChainlinkAggregator wrapper (B1)

Closes audit finding #1 in conjunction with Task D (tightening
TRYC/BRLC deviation caps): introduces source diversity at the oracle
layer so a single compromised keeper can no longer drive on-chain
prices unilaterally.

Algorithm:
- Both sources fresh + within maxDivergenceBps → return average
- Both diverge beyond cap → revert SourcesDiverge
- One source reverts/stale → return the surviving source (degraded mode)
- Both fail → revert AllSourcesUnavailable; Pool's _readOracle catch
  branch handles via cache fallback

Implements IChainlinkAggregator so the Pool reads it via existing
`info.usdOracle.latestRoundData()` with NO Pool contract change.
Governance migrates each token via Registry.setOracle(token,
aggregator) through the 48h Timelock.

6 tests cover: average within cap, divergence revert, single-source
fallback (primary alone when secondary reverts), all-sources revert,
owner-only setter, decimals-mismatch constructor revert.

Spec: docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md §4

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: CumulativeDeviationGuard contract (C)

**Files:**
- Create: `contracts/src/oracle/CumulativeDeviationGuard.sol`
- Create: `contracts/test/oracle/P3CircuitBreaker.t.sol`

- [ ] **Step 1: Write the 4 guard tests (red phase)**

Create `contracts/test/oracle/P3CircuitBreaker.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { CumulativeDeviationGuard } from "../../src/oracle/CumulativeDeviationGuard.sol";

contract P3CircuitBreakerTest is Test {
    address constant OWNER = address(0x0a);
    address constant TOKEN = address(0x100);
    CumulativeDeviationGuard guard;

    function setUp() public {
        vm.warp(1_000_000); // avoid Foundry's default block.timestamp=1
        guard = new CumulativeDeviationGuard(OWNER);
        vm.prank(OWNER);
        guard.setConfig(TOKEN, 500, 86_400); // 5% cap, 24h window
    }

    function test_guard_emits_PriceObserved_on_first_record() public {
        vm.expectEmit(true, false, false, true);
        emit CumulativeDeviationGuard.PriceObserved(TOKEN, 1e18, block.timestamp);
        guard.record(TOKEN, 1e18);

        (uint256 startPrice, uint256 startTime) = guard.windows(TOKEN);
        assertEq(startPrice, 1e18);
        assertEq(startTime, block.timestamp);
    }

    function test_guard_emits_Trip_when_deviation_exceeds_cap() public {
        guard.record(TOKEN, 1e18);
        // Move price 6% within window → exceeds 5% cap
        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(true, false, false, true);
        emit CumulativeDeviationGuard.PriceObserved(TOKEN, 1.06e18, block.timestamp);
        vm.expectEmit(true, false, false, true);
        emit CumulativeDeviationGuard.CircuitBreakerTripped(TOKEN, 600, block.timestamp);
        guard.record(TOKEN, 1.06e18);
    }

    function test_guard_resets_window_after_expiry() public {
        guard.record(TOKEN, 1e18);
        // Warp past the 24h window
        vm.warp(block.timestamp + 25 hours);
        guard.record(TOKEN, 1.1e18);

        (uint256 startPrice, uint256 startTime) = guard.windows(TOKEN);
        assertEq(startPrice, 1.1e18, "new window starts at the new observation");
        assertEq(startTime, block.timestamp);
    }

    function test_setConfig_onlyOwner() public {
        vm.expectRevert();
        guard.setConfig(TOKEN, 1000, 3600);

        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit CumulativeDeviationGuard.ConfigUpdated(TOKEN, 1000, 3600);
        guard.setConfig(TOKEN, 1000, 3600);

        (uint32 cap, uint32 window) = guard.configs(TOKEN);
        assertEq(cap, 1000);
        assertEq(window, 3600);
    }
}
```

- [ ] **Step 2: Verify the tests fail to compile**

```bash
cd contracts && forge build 2>&1 | tail -10
```
Expected: failure citing missing `CumulativeDeviationGuard`.

- [ ] **Step 3: Implement the guard contract**

Create `contracts/src/oracle/CumulativeDeviationGuard.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable }       from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }  from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CumulativeDeviationGuard
/// @notice Tracks a 24 h tumbling-window price deviation per token. Permissionless
/// `record` updates the window and emits structured events. Off-chain monitoring
/// consumes `PriceObserved` / `CircuitBreakerTripped` and decides whether to
/// trigger the Pause Guardian Safe. No on-chain auto-pause in P3.
contract CumulativeDeviationGuard is Ownable2Step {
    struct WindowState {
        uint256 startPrice1e18;
        uint256 startTimestamp;
    }
    struct Config {
        uint32 maxCumulativeBps;
        uint32 windowSeconds;
    }

    mapping(address token => WindowState) public windows;
    mapping(address token => Config)      public configs;

    event PriceObserved(address indexed token, uint256 price1e18, uint256 timestamp);
    event CircuitBreakerTripped(address indexed token, uint256 deviationBps, uint256 timestamp);
    event ConfigUpdated(address indexed token, uint32 maxCumulativeBps, uint32 windowSeconds);

    error InvalidConfig(uint32 maxCumulativeBps, uint32 windowSeconds);
    error PriceMustBePositive();

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setConfig(address token, uint32 maxCumulativeBps_, uint32 windowSeconds_)
        external
        onlyOwner
    {
        if (
            maxCumulativeBps_ == 0 || maxCumulativeBps_ > 10_000 ||
            windowSeconds_   < 60  || windowSeconds_  > 30 days
        ) {
            revert InvalidConfig(maxCumulativeBps_, windowSeconds_);
        }
        configs[token] = Config(maxCumulativeBps_, windowSeconds_);
        emit ConfigUpdated(token, maxCumulativeBps_, windowSeconds_);
    }

    function record(address token, uint256 price1e18) external {
        if (price1e18 == 0) revert PriceMustBePositive();

        Config memory cfg = configs[token];
        if (cfg.windowSeconds == 0) {
            // Token not tracked — emit observation and return without trip evaluation.
            emit PriceObserved(token, price1e18, block.timestamp);
            return;
        }

        WindowState memory win = windows[token];
        if (win.startTimestamp == 0 || block.timestamp - win.startTimestamp > cfg.windowSeconds) {
            // First observation or window expired — reset.
            windows[token] = WindowState(price1e18, block.timestamp);
            emit PriceObserved(token, price1e18, block.timestamp);
            return;
        }

        emit PriceObserved(token, price1e18, block.timestamp);

        uint256 diff = price1e18 > win.startPrice1e18
            ? price1e18 - win.startPrice1e18
            : win.startPrice1e18 - price1e18;
        uint256 deviationBps = (diff * 10_000) / win.startPrice1e18;
        if (deviationBps > cfg.maxCumulativeBps) {
            emit CircuitBreakerTripped(token, deviationBps, block.timestamp);
        }
    }
}
```

- [ ] **Step 4: Run the new tests**

```bash
cd contracts && forge build 2>&1 | tail -3
cd contracts && forge test --match-contract P3CircuitBreakerTest -vv 2>&1 | tail -15
```
Expected: all 4 tests PASS.

- [ ] **Step 5: Run full suite**

```bash
cd contracts && forge test 2>&1 | tail -3
```
Expected: 108 (post-Task-4 baseline) + 4 = 112 tests passing.

- [ ] **Step 6: Commit**

```bash
git add contracts/src/oracle/CumulativeDeviationGuard.sol \
        contracts/test/oracle/P3CircuitBreaker.t.sol
git commit -m "$(cat <<'EOF'
feat(contracts): CumulativeDeviationGuard — event-only circuit breaker (C)

Adds on-chain rolling deviation observability for off-chain monitoring.
Tumbling 24 h window per token (cheaper than a true rolling window;
acceptable for testnet rehearsal MVP).

Behavior:
- record(token, price) is permissionless — off-chain monitor calls
  every minute with the aggregated price from the per-token aggregator
- First observation or expired window → window resets, PriceObserved
  emitted, no trip evaluation
- Subsequent observation within window → PriceObserved emitted;
  if |price - startPrice| / startPrice exceeds maxCumulativeBps, also
  emit CircuitBreakerTripped
- No on-chain auto-pause (deferred to P5 once we have operational data
  on false-positive rates)

4 tests cover: first-record initialisation, trip event emission,
window-reset after expiry, owner-only setConfig.

Owner = Governance Safe (no Timelock — operational tuning).

Spec: docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md §6

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Governance integration test (B2)

**Files:**
- Modify: `contracts/test/oracle/P3Aggregator.t.sol`

This test exercises the full governance migration (Timelock schedule → warp 48h → execute → verify Registry points at aggregator → verify a swap goes through the aggregator path). It reuses the P2 governance setup pattern from `P2Governance.t.sol`.

- [ ] **Step 1: Add the governance integration test**

Append to `contracts/test/oracle/P3Aggregator.t.sol`. First add imports at the top:

```solidity
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { SafeProxyFactory } from "@safe-global/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import { ArcoraDexRegistry } from "../../src/ArcoraDexRegistry.sol";
import { SafeSigHelpers } from "../governance/SafeSigHelpers.sol";
```

Then add a new test contract in the same file:

```solidity
contract P3AggregatorGovernanceTest is Test {
    using SafeSigHelpers for Safe;

    string constant MNEMONIC =
        "test test test test test test test test test test test junk";
    uint256 constant TIMELOCK_DELAY = 48 hours;

    address constant DEPLOYER = address(0xD3);

    Safe                governanceSafe;
    TimelockController  timelock;
    ArcoraDexRegistry   reg;
    MockChainlinkFeedV2 primary;
    MockChainlinkFeedV2 secondary;
    OracleAggregator    aggregator;

    uint256[5] govKeys;
    address    usdc;

    function setUp() public {
        vm.warp(1_000_000);

        // Derive 5 gov signers
        address[] memory govOwners = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i] = vm.deriveKey(MNEMONIC, uint32(i));
            govOwners[i] = vm.addr(govKeys[i]);
        }

        // Deploy Safe + Timelock with minDelay = 0 setup, then lockdown
        Safe singleton = new Safe();
        SafeProxyFactory factory = new SafeProxyFactory();
        bytes memory setup = abi.encodeCall(
            Safe.setup,
            (govOwners, 3, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        governanceSafe = Safe(payable(address(factory.createProxyWithNonce(address(singleton), setup, 1))));

        address[] memory proposers = new address[](1); proposers[0] = address(governanceSafe);
        address[] memory executors = new address[](1); executors[0] = address(0);
        timelock = new TimelockController(0, proposers, executors, address(0));

        // Deploy Registry, primary feed, USDC mock (via MockERC20 helper)
        vm.startPrank(DEPLOYER);
        reg = new ArcoraDexRegistry(DEPLOYER);
        primary   = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER);
        secondary = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER);
        usdc = address(_deployMockToken("USDC", "USDC", 6));
        reg.listToken(usdc, 6, IChainlinkAggregator(address(primary)), 50, 3600);
        reg.transferOwnership(address(timelock));
        vm.stopPrank();

        // Timelock accepts Registry ownership at minDelay=0
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(reg), 0, abi.encodeCall(reg.acceptOwnership, ()), bytes32(0), bytes32(0), 0)));
        _govExec(address(timelock), abi.encodeCall(TimelockController.execute,
            (address(reg), 0, abi.encodeCall(reg.acceptOwnership, ()), bytes32(0), bytes32(0))));

        // Lockdown to 48h
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(timelock), 0, abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY)), bytes32(0), bytes32(0), 0)));
        _govExec(address(timelock), abi.encodeCall(TimelockController.execute,
            (address(timelock), 0, abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY)), bytes32(0), bytes32(0))));

        // Deploy aggregator and put under Governance Safe ownership
        aggregator = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,
            address(governanceSafe)
        );
    }

    function test_governance_migrates_registry_to_aggregator() public {
        // Step 1: schedule via Timelock
        bytes memory call = abi.encodeCall(reg.setOracle, (usdc, IChainlinkAggregator(address(aggregator))));
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(reg), 0, call, bytes32(0), bytes32(0), TIMELOCK_DELAY)));

        // Cannot execute early
        vm.expectRevert();
        timelock.execute(address(reg), 0, call, bytes32(0), bytes32(0));

        // Warp 48h + 1 second
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        timelock.execute(address(reg), 0, call, bytes32(0), bytes32(0));

        // Verify
        assertEq(address(reg.tokenInfo(usdc).usdOracle), address(aggregator));

        // Aggregator returns the expected price
        (, int256 ans, , , ) = aggregator.latestRoundData();
        assertEq(ans, int256(100_000_000), "aggregator returns avg of two $1.00 sources");
    }

    function _govExec(address to, bytes memory data) internal {
        uint256[] memory keys = new uint256[](3);
        keys[0] = govKeys[0]; keys[1] = govKeys[1]; keys[2] = govKeys[2];
        require(governanceSafe.execCall(to, data, keys), "gov exec failed");
    }

    function _deployMockToken(string memory n, string memory s, uint8 d) internal returns (address) {
        // Inline minimal ERC20 to avoid pulling MockERC20 import; only needs the .decimals() check
        // that Registry.listToken performs.
        return address(new MockERC20Wrapper(n, s, d));
    }
}

// Minimal wrapper to satisfy Registry's `IERC20Metadata(token).decimals()` check.
contract MockERC20Wrapper {
    string private _n;
    string private _s;
    uint8  private _d;
    constructor(string memory n, string memory s, uint8 d) { _n = n; _s = s; _d = d; }
    function name()     external view returns (string memory) { return _n; }
    function symbol()   external view returns (string memory) { return _s; }
    function decimals() external view returns (uint8)         { return _d; }
}
```

- [ ] **Step 2: Run the integration test**

```bash
cd contracts && forge build 2>&1 | tail -3
cd contracts && forge test --match-test test_governance_migrates_registry_to_aggregator -vv 2>&1 | tail -20
```
Expected: PASS.

- [ ] **Step 3: Run full suite**

```bash
cd contracts && forge test 2>&1 | tail -3
```
Expected: 112 (post-Task-5 baseline) + 1 = 113 tests passing.

- [ ] **Step 4: Commit**

```bash
git add contracts/test/oracle/P3Aggregator.t.sol
git commit -m "$(cat <<'EOF'
test(governance): P3 aggregator migration via Timelock + 48h delay (B2)

Adds the governance-integration end-to-end test for P3: deploys a
fresh governance stack (mimicking P2 setup pattern), deploys an
OracleAggregator over two MockChainlinkFeedV2 sources, then drives
the Registry.setOracle migration through the full Timelock cycle:
schedule → cannot-execute-before-delay → warp 48h → execute → verify
Registry now points at the aggregator and the aggregator returns the
expected aggregated price.

This proves the operational migration sequence works without needing
to wait 48h real-time during testnet broadcast (Task 8/9).

Spec: docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md §10

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: DeployOraclesP3.s.sol script

**Files:**
- Create: `contracts/script/DeployOraclesP3.s.sol`

This script deploys 7 secondary feeds + 7 aggregators + 1 guard, then transfers ownership of all 8 owned contracts to the Governance Safe. It does NOT schedule the Timelock migration — that's a separate Safe transaction in Task 8.

- [ ] **Step 1: Create the script**

Create `contracts/script/DeployOraclesP3.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeedV2 }  from "../src/testnet/MockChainlinkFeedV2.sol";
import { OracleAggregator }     from "../src/oracle/OracleAggregator.sol";
import { CumulativeDeviationGuard } from "../src/oracle/CumulativeDeviationGuard.sol";

contract DeployOraclesP3 is Script {
    address constant GOVERNANCE_SAFE = 0x715f669D79Cc72d6685F8724c0B86f7B53d7e624;

    struct TokenSpec {
        string  symbol;
        address token;
        address primaryFeed;
        int256  initialPrice;
        uint8   feedDecimals;
        uint16  divergenceBps;
        uint32  cumulativeBps;   // for guard config
    }

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        TokenSpec[7] memory cfg = [
            TokenSpec("USDC",  0x3BFa09fF6467639f0981948385bA1018Ac07d22C, 0x2E6B862E1Ac74328238494B22317262004534B39,  100_000_000, 8,  50, 200),
            TokenSpec("USDT",  0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B, 0x741af784a1d4C69843A1764099433160088a1c70,  100_000_000, 8,  50, 200),
            TokenSpec("PYUSD", 0xfdB2c86d010698401f0b969348DC58b6659B96a3, 0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896,  100_000_000, 8,  50, 200),
            TokenSpec("DAI",   0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE, 0xAAC5a5855deF9414f7330f350c2E00119C2097c8,  100_000_000, 8,  50, 200),
            TokenSpec("EURC",  0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD, 0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170,  108_000_000, 8, 100, 300),
            TokenSpec("TRYC",  0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61, 0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C,    2_900_000, 8, 200, 500),
            TokenSpec("BRLC",  0xa13c0935A98e2c175b31A4054f698819271a8FfC, 0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d,   20_000_000, 8, 200, 500)
        ];

        vm.startBroadcast(deployerKey);

        console2.log("=== Deploying P3 oracle layer ===");
        console2.log("Deployer:", deployer);
        console2.log("Governance Safe:", GOVERNANCE_SAFE);
        console2.log("");

        // 1. Deploy CumulativeDeviationGuard (initial owner = deployer, transferred below)
        CumulativeDeviationGuard guard = new CumulativeDeviationGuard(deployer);
        console2.log("Guard:", address(guard));

        // 2. Per-token: deploy secondary feed, deploy aggregator, configure guard
        for (uint256 i = 0; i < cfg.length; i++) {
            MockChainlinkFeedV2 secondary = new MockChainlinkFeedV2(
                cfg[i].feedDecimals,
                cfg[i].initialPrice,
                deployer,
                deployer
            );

            OracleAggregator agg = new OracleAggregator(
                IChainlinkAggregator(cfg[i].primaryFeed),
                IChainlinkAggregator(address(secondary)),
                cfg[i].divergenceBps,
                deployer
            );

            guard.setConfig(cfg[i].token, cfg[i].cumulativeBps, 86_400);

            console2.log(string.concat("  ", cfg[i].symbol, " secondary:"), address(secondary));
            console2.log(string.concat("  ", cfg[i].symbol, " aggregator:"), address(agg));

            // Transfer aggregator ownership to Governance Safe (Ownable2Step)
            agg.transferOwnership(GOVERNANCE_SAFE);
            // Same for secondary feed
            secondary.transferOwnership(GOVERNANCE_SAFE);
        }

        // 3. Transfer guard ownership
        guard.transferOwnership(GOVERNANCE_SAFE);

        console2.log("");
        console2.log("Ownership of guard + 7 aggregators + 7 secondaries transferred (pending acceptance by Governance Safe).");

        vm.stopBroadcast();
    }
}
```

- [ ] **Step 2: Verify the script compiles**

```bash
cd contracts && forge build 2>&1 | tail -3
```
Expected: clean.

- [ ] **Step 3: Local dry-run**

```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool && set -a; source contracts/.env; set +a; cd contracts && forge script script/DeployOraclesP3.s.sol --rpc-url https://rpc.testnet.arc.network 2>&1 | tail -25
```
Expected: simulation complete; logs show 1 guard + 7 secondary + 7 aggregator addresses; estimated gas ≈ 8–10 M (~0.3 ARC at 40 gwei).

- [ ] **Step 4: Commit (broadcast in Task 8)**

```bash
git add contracts/script/DeployOraclesP3.s.sol
git commit -m "$(cat <<'EOF'
chore(deploy): DeployOraclesP3.s.sol — aggregators + guard rollout (B/C)

Forge script that deploys the P3 oracle layer:
- 1 CumulativeDeviationGuard (with per-token config for all 7 stables)
- 7 secondary MockChainlinkFeedV2 feeds (initial answer matches primary)
- 7 OracleAggregator instances (primary = existing feed from 2026-05-10
  cutover; secondary = newly-deployed feed; per-token divergence cap)

All 15 owned contracts have their ownership transferred to the
Governance Safe (Ownable2Step pending-accept). Governance Safe must
call acceptOwnership on each contract (operator-driven, Task 8).

The script does NOT migrate Registry.setOracle — that's a separate
Timelock-routed governance proposal (Task 8 schedule, Task 9 execute
after 48h).

Spec: docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md §8

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Broadcast deploy + Safe acceptOwnership + scheduleBatch (live testnet)

**Files:** none modified.

This task does live testnet broadcasts. It happens in three phases:

1. Run `DeployOraclesP3.s.sol` to deploy contracts.
2. Governance Safe calls `acceptOwnership()` on each of the 15 contracts (15 separate Safe transactions, or 1 batched Safe transaction).
3. Governance Safe calls `Timelock.scheduleBatch(...)` with 9 operations (7 setOracle + 2 setDeviation).

Steps 2 and 3 require Safe sig construction off-chain (with the test mnemonic). Easiest path: write a one-off script that derives the gov keys, builds the Safe transactions, and submits them via `SafeSigHelpers.execCall`.

- [ ] **Step 1: Dry-run the deploy script one more time**

```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool && set -a; source contracts/.env; set +a; cd contracts && forge script script/DeployOraclesP3.s.sol --rpc-url https://rpc.testnet.arc.network 2>&1 | tail -10
```
Expected: simulation succeeds; estimated gas ≈ 0.3 ARC.

- [ ] **Step 2: Broadcast the deploy**

```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool && set -a; source contracts/.env; set +a; cd contracts && forge script script/DeployOraclesP3.s.sol --rpc-url https://rpc.testnet.arc.network --broadcast --slow --gas-estimate-multiplier 150 2>&1 | tail -10
```
Expected: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL` (typically 5–15 minutes for 15+ tx receipts).

If the broadcast hangs (similar to the Task 8 P2 incident), check that nonces progress via `cast nonce 0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b --rpc-url ... --block pending` and that the script's queued txs match. Retry with `--slow` and a higher gas multiplier (200) if needed.

- [ ] **Step 3: Capture new addresses from the broadcast file**

```bash
python3 -c "
import json
with open('contracts/broadcast/DeployOraclesP3.s.sol/5042002/run-latest.json') as f:
    d = json.load(f)
print(f'txs: {len(d[\"transactions\"])}, receipts: {len(d[\"receipts\"])}')
for tx in d['transactions']:
    if tx['transactionType'] == 'CREATE':
        print(f\"  CREATE {tx['contractName']:30s} {tx['contractAddress']}\")
"
```
Capture: `GUARD_ADDR`, 7 `SECONDARY_<SYM>` addresses, 7 `AGGREGATOR_<SYM>` addresses.

Save them in a temporary file for Task 8 Step 4 (or paste into the rollout doc skeleton).

- [ ] **Step 4: Verify ownership pending state**

```bash
RPC=https://rpc.testnet.arc.network
echo "Guard pending owner: $(cast call $GUARD_ADDR 'pendingOwner()(address)' --rpc-url $RPC)"
# For each aggregator:
echo "Aggregator USDC pending owner: $(cast call $AGGREGATOR_USDC 'pendingOwner()(address)' --rpc-url $RPC)"
# ... etc for all 7 aggregators + 7 secondaries
```
Expected: each `pendingOwner` == Governance Safe `0x715f669D79Cc72d6685F8724c0B86f7B53d7e624`.

- [ ] **Step 5: Write a one-off Safe-driven script to accept ownership + schedule the batch**

Create a temporary script `contracts/script/P3GovernanceActions.s.sol` (this file is committed but can be deleted later if desired — it's reference operational code):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { OracleAggregator }     from "../src/oracle/OracleAggregator.sol";
import { CumulativeDeviationGuard } from "../src/oracle/CumulativeDeviationGuard.sol";
import { ArcoraDexRegistry }    from "../src/ArcoraDexRegistry.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { SafeSigHelpers } from "../test/governance/SafeSigHelpers.sol";

contract P3GovernanceActions is Script {
    using SafeSigHelpers for Safe;

    string constant MNEMONIC =
        "test test test test test test test test test test test junk";

    // P2 addresses (fixed)
    Safe   constant GOV_SAFE = Safe(payable(0x715f669D79Cc72d6685F8724c0B86f7B53d7e624));
    TimelockController constant TIMELOCK = TimelockController(payable(0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83));
    ArcoraDexRegistry  constant REGISTRY = ArcoraDexRegistry(0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB);

    // Token addresses (fixed from 2026-05-06 deploy)
    address[7] TOKENS = [
        0x3BFa09fF6467639f0981948385bA1018Ac07d22C,  // USDC
        0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B,  // USDT
        0xfdB2c86d010698401f0b969348DC58b6659B96a3,  // PYUSD
        0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE,  // DAI
        0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD,  // EURC
        0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61,  // TRYC
        0xa13c0935A98e2c175b31A4054f698819271a8FfC   // BRLC
    ];

    uint16[7] NEW_CAPS = [uint16(50), 50, 50, 50, 150, 200, 200]; // unchanged for first 5; TRYC/BRLC 5000→200

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // P3 contracts deployed in Task 7 (fill these in after Task 7 Step 3 captures them)
        address GUARD       = vm.envAddress("P3_GUARD");
        address[7] memory SECONDARIES = [
            vm.envAddress("P3_SECONDARY_USDC"),
            vm.envAddress("P3_SECONDARY_USDT"),
            vm.envAddress("P3_SECONDARY_PYUSD"),
            vm.envAddress("P3_SECONDARY_DAI"),
            vm.envAddress("P3_SECONDARY_EURC"),
            vm.envAddress("P3_SECONDARY_TRYC"),
            vm.envAddress("P3_SECONDARY_BRLC")
        ];
        address[7] memory AGGREGATORS = [
            vm.envAddress("P3_AGG_USDC"),
            vm.envAddress("P3_AGG_USDT"),
            vm.envAddress("P3_AGG_PYUSD"),
            vm.envAddress("P3_AGG_DAI"),
            vm.envAddress("P3_AGG_EURC"),
            vm.envAddress("P3_AGG_TRYC"),
            vm.envAddress("P3_AGG_BRLC")
        ];

        uint256[5] memory govKeys;
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i] = vm.deriveKey(MNEMONIC, uint32(i));
        }

        vm.startBroadcast(deployerKey);

        // Phase A: Governance Safe accepts ownership of guard + 7 aggregators + 7 secondaries (15 calls)
        _accept(GUARD, govKeys);
        for (uint256 i = 0; i < 7; i++) {
            _accept(AGGREGATORS[i], govKeys);
            _accept(SECONDARIES[i], govKeys);
        }
        console2.log("Phase A: Governance Safe accepted ownership of 15 contracts");

        // Phase B: Governance Safe schedules the 9-operation batch through Timelock
        address[] memory targets = new address[](9);
        uint256[] memory values  = new uint256[](9);
        bytes[]   memory calls   = new bytes[](9);

        // 7 setOracle calls
        for (uint256 i = 0; i < 7; i++) {
            targets[i] = address(REGISTRY);
            values[i]  = 0;
            calls[i]   = abi.encodeCall(REGISTRY.setOracle, (TOKENS[i], IChainlinkAggregator(AGGREGATORS[i])));
        }
        // 2 setDeviation calls (TRYC, BRLC)
        targets[7] = address(REGISTRY); values[7] = 0;
        calls[7]   = abi.encodeCall(REGISTRY.setDeviation, (TOKENS[5], NEW_CAPS[5])); // TRYC -> 200
        targets[8] = address(REGISTRY); values[8] = 0;
        calls[8]   = abi.encodeCall(REGISTRY.setDeviation, (TOKENS[6], NEW_CAPS[6])); // BRLC -> 200

        bytes memory schedBatchCall = abi.encodeCall(
            TimelockController.scheduleBatch,
            (targets, values, calls, bytes32(0), bytes32(0), 48 hours)
        );

        uint256[] memory keys3 = new uint256[](3);
        keys3[0] = govKeys[0]; keys3[1] = govKeys[1]; keys3[2] = govKeys[2];
        require(GOV_SAFE.execCall(address(TIMELOCK), schedBatchCall, keys3), "scheduleBatch failed");
        console2.log("Phase B: scheduled 9-operation batch through Timelock (48h delay)");

        // Capture the batch id (off-chain operator uses this to executeBatch after 48h)
        bytes32 id = TIMELOCK.hashOperationBatch(targets, values, calls, bytes32(0), bytes32(0));
        console2.log("Batch id (executable after 48h):");
        console2.logBytes32(id);

        vm.stopBroadcast();
    }

    function _accept(address target, uint256[5] memory govKeys) internal {
        uint256[] memory keys3 = new uint256[](3);
        keys3[0] = govKeys[0]; keys3[1] = govKeys[1]; keys3[2] = govKeys[2];
        require(
            GOV_SAFE.execCall(target, abi.encodeWithSignature("acceptOwnership()"), keys3),
            "acceptOwnership failed"
        );
    }
}
```

- [ ] **Step 6: Set env vars and run Phase A+B**

```bash
export P3_GUARD=<from Task 7 Step 3>
export P3_SECONDARY_USDC=<...>
# ... all 14 secondary + aggregator addresses ...

cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool && set -a; source contracts/.env; set +a
cd contracts && forge script script/P3GovernanceActions.s.sol --rpc-url https://rpc.testnet.arc.network --broadcast --slow --gas-estimate-multiplier 150 2>&1 | tail -15
```
Expected: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`. Logs include the batch id for use in Task 9.

- [ ] **Step 7: Verify on-chain state post-acceptance**

```bash
RPC=https://rpc.testnet.arc.network
echo "Guard owner: $(cast call $P3_GUARD 'owner()(address)' --rpc-url $RPC)"
for AGG in $P3_AGG_USDC $P3_AGG_USDT $P3_AGG_PYUSD $P3_AGG_DAI $P3_AGG_EURC $P3_AGG_TRYC $P3_AGG_BRLC; do
  echo "Aggregator $AGG owner: $(cast call $AGG 'owner()(address)' --rpc-url $RPC)"
done
```
Expected: all 8 owners == Governance Safe.

- [ ] **Step 8: Commit the operational script**

```bash
git add contracts/script/P3GovernanceActions.s.sol
git commit -m "$(cat <<'EOF'
chore(deploy): P3GovernanceActions — Safe accept + Timelock scheduleBatch

Operational script bundling Phase A (Governance Safe acceptOwnership
on guard + 7 aggregators + 7 secondaries) and Phase B (Timelock
scheduleBatch of 7 Registry.setOracle + 2 Registry.setDeviation calls
with 48h delay).

Reads P3 contract addresses from env vars set by the operator after
the DeployOraclesP3.s.sol broadcast.

Includes a chain-id guard (Arc testnet only) and final require
assertions implicit via SafeSigHelpers.execCall return checks.

After this script broadcasts, the Timelock batch is queued. Task 9
(operator-driven, 48h later) executes the batch via
TimelockController.executeBatch.

Spec: docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md §10

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Wait 48 h and execute the Timelock batch (operator-driven, NOT in this PR)

**Files:** none modified.

This task is operator follow-up. It happens 48 hours after Task 8's `scheduleBatch` broadcast. The plan documents it for traceability; the subagent flow does NOT execute it.

- [ ] **Step 1: Wait 48 h (real time)**

Operator coordinates downstream work during this window: SDK update plan, keeper config tweaks, monitoring scripts.

- [ ] **Step 2: Execute the batch**

```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool && set -a; source contracts/.env; set +a
# Reconstruct the batch arguments — must match exactly what was scheduled.
# Easiest: encode them in a small Forge script. Or use cast directly:

RPC=https://rpc.testnet.arc.network
TIMELOCK=0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83
# (Targets, values, calls match what P3GovernanceActions scheduled — see the script for the exact 9 operations.)

# Anyone (executor role is open) can execute. Use the deployer EOA for gas.
cast send $TIMELOCK 'executeBatch(address[],uint256[],bytes[],bytes32,bytes32)' \
    "[$REGISTRY,$REGISTRY,$REGISTRY,$REGISTRY,$REGISTRY,$REGISTRY,$REGISTRY,$REGISTRY,$REGISTRY]" \
    "[0,0,0,0,0,0,0,0,0]" \
    "[<setOracle USDC>,<setOracle USDT>,...,<setDeviation TRYC>,<setDeviation BRLC>]" \
    "0x0000...0000" "0x0000...0000" \
    --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url $RPC
```

For the operator, simpler: write a small `ExecuteP3Batch.s.sol` script that reads env vars and calls `executeBatch` — same structure as Task 8 step 5 but only the executeBatch call.

- [ ] **Step 3: Verify state**

```bash
RPC=https://rpc.testnet.arc.network
REGISTRY=0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB

# Each token's oracle now points at its aggregator
cast call $REGISTRY 'tokenInfo(address)((uint8,bool,address,uint16,uint32))' <USDC token> --rpc-url $RPC
# Expected: usdOracle == aggregator address

# TRYC and BRLC deviation caps now 200
# (parse the tuple output for the maxOracleDeviationBps field)
```

- [ ] **Step 4: Sanity swap**

Perform a small test swap on at least one pair (e.g., 10 USDC → USDT) using the deployer EOA. The swap should succeed and route through the aggregator path. If it reverts, the aggregator is misconfigured — investigate.

```bash
cast send $POOL_V3 'swap(address,address,uint256,uint256,uint256,address)(uint256)' \
    <USDC> <USDT> 10000000 0 $(($(date +%s) + 300)) $DEPLOYER \
    --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url $RPC
```

No commit — Task 9 is operator-driven and happens after the PR has merged.

---

### Task 10: Rollout doc

**Files:**
- Create: `docs/rollouts/2026-05-14-phase3-oracle.md`

- [ ] **Step 1: Write the rollout doc**

Create `docs/rollouts/2026-05-14-phase3-oracle.md` with these sections (fill in addresses captured in Task 7 / 8):

```markdown
# Phase 3 — Oracle Hardening Rollout (Testnet Rehearsal)

**Date:** 2026-05-14
**Branch:** phase3/oracle-rollout (merged to main as PR #N)
**Spec:** docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md
**Plan:** docs/superpowers/plans/2026-05-14-phase3-oracle-hardening.md

## Why this rollout

Closes audit finding #1 (HIGH TRYC/BRLC writer-compromise drain) and
the P1/P2 oracle-layer residuals.

## New P3 contract addresses

| Contract | Address |
|---|---|
| CumulativeDeviationGuard | `<GUARD_ADDR>` |
| USDC aggregator | `<AGGREGATOR_USDC>` |
| USDT aggregator | `<AGGREGATOR_USDT>` |
| PYUSD aggregator | `<AGGREGATOR_PYUSD>` |
| DAI aggregator | `<AGGREGATOR_DAI>` |
| EURC aggregator | `<AGGREGATOR_EURC>` |
| TRYC aggregator | `<AGGREGATOR_TRYC>` |
| BRLC aggregator | `<AGGREGATOR_BRLC>` |
| USDC secondary feed | `<SECONDARY_USDC>` |
| USDT secondary feed | `<SECONDARY_USDT>` |
| PYUSD secondary feed | `<SECONDARY_PYUSD>` |
| DAI secondary feed | `<SECONDARY_DAI>` |
| EURC secondary feed | `<SECONDARY_EURC>` |
| TRYC secondary feed | `<SECONDARY_TRYC>` |
| BRLC secondary feed | `<SECONDARY_BRLC>` |

## Configuration

| Token | maxDivergenceBps (aggregator) | maxCumulativeBps (guard) | windowSeconds (guard) |
|---|---|---|---|
| USDC  | 50 | 200 | 86_400 |
| USDT  | 50 | 200 | 86_400 |
| PYUSD | 50 | 200 | 86_400 |
| DAI   | 50 | 200 | 86_400 |
| EURC  | 100 | 300 | 86_400 |
| TRYC  | 200 | 500 | 86_400 |
| BRLC  | 200 | 500 | 86_400 |

Registry pool-side caps (maxOracleDeviationBps), updated by the batch:

| Token | Old | New |
|---|---|---|
| TRYC | 5000 | 200 |
| BRLC | 5000 | 200 |
| (others unchanged) | | |

## Sequence executed

1. Day 0: deployer broadcast DeployOraclesP3.s.sol (deploy 15 contracts).
2. Day 0: Governance Safe broadcast P3GovernanceActions.s.sol (acceptOwnership × 15, scheduleBatch).
3. Day 2 (48h later): anyone executed `Timelock.executeBatch(...)` — tx `<exec tx hash>`.
4. Day 2: sanity swap on USDC→USDT confirmed routing through aggregator — tx `<sanity swap tx hash>`.

## Downstream tasks (post-merge)

- [ ] Update keeper script (`/home/arcora/arcoradex-feeds/multi-feed-push.mjs`) to push to BOTH primary and secondary feeds. Secondary can use the same keeper EOA but should run on an offset schedule (e.g., primary minute 0, secondary minute 15) to simulate "two independent sources".
- [ ] Deploy `ops/monitoring/cumulative-deviation-recorder.mjs` on the VPS (call `guard.record(token, price)` every minute). NOT in this PR — spec'd for P5.
- [ ] Update auto-memory `arcoradex_role_eoas.md` with the new P3 addresses.
- [ ] Update SDK if it caches feed addresses.

## Tracking for P5

- On-chain auto-pause when the guard trips
- Pyth or other independent secondary source for mainnet
- Mainnet keeper deployment with operational SLAs

## Rollback

If the P3 oracle layer needs to be reverted (e.g., aggregator misbehaves
in production), the Governance Safe schedules a new
`Registry.setOracle(token, original_feed)` proposal through Timelock.
48h delay applies. For emergency situations, Pause Guardian can pause
the pool immediately.

## Phase 3 status

- ✅ Pool try/catch for reverting oracles
- ✅ Pool single-read refactor of `_readUsdPrice1e18WithGuard`
- ✅ OracleAggregator + 7 deploys
- ✅ CumulativeDeviationGuard
- ✅ Registry migration via Timelock scheduleBatch + executeBatch
- ✅ TRYC/BRLC deviation caps tightened 5000 → 200
- ⏭ Next: P4 — Spearbit private review
```

- [ ] **Step 2: Stage and commit**

```bash
git add docs/rollouts/2026-05-14-phase3-oracle.md
git commit -m "$(cat <<'EOF'
docs(rollout): phase 3 oracle hardening rollout (2026-05-14)

Live testnet rehearsal of the P3 oracle migration. 15 new contracts
deployed (1 guard + 7 aggregators + 7 secondary feeds); Governance
Safe accepted ownership and scheduled the 9-operation batch
(7 setOracle + 2 setDeviation) through Timelock. After 48h, anyone
executes the batch — Registry now points at aggregators, TRYC/BRLC
deviation caps tightened from 5000 to 200 bps.

Documents new addresses, per-token config, sequence executed,
downstream checklist (keeper + monitoring deploy), rollback strategy.

Spec: docs/superpowers/specs/2026-05-14-phase3-oracle-hardening-design.md §10

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Final pre-merge checks

**Files:** none modified.

- [ ] **Step 1: Run full test suite**

```bash
cd contracts && forge test 2>&1 | tail -3
```
Expected: ≥ 113 tests passing (101 P2 baseline + 12 P3 additions: 1 in Pool + 6 in P3Aggregator + 4 in P3CircuitBreaker + 1 P3 governance integration).

- [ ] **Step 2: Coverage check**

```bash
cd contracts && forge coverage --report summary 2>&1 | grep -E "src/(ArcoraDex|oracle|interfaces|testnet)" | head -10
```
Expected:
- `src/ArcoraDexPool.sol` ≥ 93 %
- `src/oracle/OracleAggregator.sol` ≥ 95 %
- `src/oracle/CumulativeDeviationGuard.sol` ≥ 90 %

If below, add targeted tests for uncovered branches.

- [ ] **Step 3: Slither check**

```bash
cd contracts && slither . 2>&1 | tail -10
```
Expected: same warning categories as P2 baseline. No new HIGH/MEDIUM.

- [ ] **Step 4: Branch state summary**

```bash
git log --oneline main..HEAD
git diff main --stat
```
Expected: 8 commits on branch (Task 2 + Task 3 + Task 4 + Task 5 + Task 6 + Task 7 + Task 8 + Task 10).

- [ ] **Step 5: STOP. Hand back to operator for PR creation and merge.**

The plan does not push or open the PR. Operator reviews the branch, then opens PR using the rollout doc commit body as the PR description seed.

---

## Rollback

Each task ships as its own commit. Reverting individual changes via `git revert <sha>` is straightforward:

- **A1 / A2 (Pool changes)**: reverting either commit restores the pre-P3 Pool behaviour. No on-chain effect since Pool wasn't redeployed.
- **B1 / C (new contracts)**: revert removes the new source files. On-chain contracts remain deployed but become orphaned (no one calls them).
- **B2 (governance migration)**: a separate Timelock proposal restores the original feed pointers in Registry. 48h delay applies. For emergency, Pause Guardian can pause the pool immediately.

For the planning-stage rollback (before broadcast), simply discard the local branch and the testnet stays at the P2 state.
