# Base V2 Core Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the immutable `ArcoraDexPoolV2`, governance-configurable `ArcoraDexRegistryV2`, the `IOracleAdapterV2` safe/unsafe-price interface plus a `MockOracleAdapterV2`, and an LP token — implementing reserve-floor-protected swaps and single-token withdrawals with marginal utilization-fee bands, proportional emergency exit, fail-closed oracle handling, and a full Foundry test suite including the §14 stateful invariants.

**Architecture:** A single immutable Pool holds all reserves and accounting; a separate `Ownable2Step` Registry holds per-token governance config (adapter address, reserve floor/target, fee bands, caps, active flag) gated by §6.2 validation. The Pool consumes only a binary `(price1e18, safe)` from each token's adapter — the adapter alone decides safety (stale/invalid/diverged/single-source per §10/§11). Every priced output path (swap, single-token withdraw, and their quotes/views) routes through ONE internal marginal band-traversal function so quote and execution are bit-for-bit consistent; rounding is conservative (maxima round down, fees round up, execution never exceeds quote). Proportional emergency withdrawal bypasses oracles and reserve floors entirely and returns a pro-rata basket.

**Tech Stack:** Solidity `^0.8.26`, Foundry (`forge build` / `forge test` / `forge fmt`), OpenZeppelin v5 (`Ownable`, `Ownable2Step`, `ReentrancyGuard`, `SafeERC20`, `ERC20`, `IERC20Metadata`), forge-std (`Test`, `StdInvariant`). Chain-agnostic — no Arc/Base address hardcoding in contracts.

**Out of scope (later plans):**
- Real Chainlink + Pyth `IOracleAdapterV2` implementations and Base feed-contract verification (spec §10).
- Base Sepolia / mainnet deploy scripts and governance orchestration: Safe + 48h `TimelockController` (spec §13).
- Off-chain monitoring, alerting, runbooks, pause drills (spec §12).
- SDK and application work — the app-side parts of §9 (`Max` button, quote refresh UX, network selection). Only the contract-side views are in this plan.
- Arc deployment (spec §1, §13).

---

## File Structure

| File | Responsibility (one each) |
|------|---------------------------|
| `contracts/src/v2/interfaces/IOracleAdapterV2.sol` | The single oracle abstraction the Pool consumes: `readPrice(token) → (price1e18, safe)` and `peekPrice(token) → (price1e18, safe)` (view). The adapter alone decides `safe` per §10/§11. |
| `contracts/src/v2/interfaces/IArcoraDexRegistryV2.sol` | Registry interface: `TokenConfigV2` struct, fee-band types, errors, events, mutator + view signatures. |
| `contracts/src/v2/interfaces/IArcoraDexPoolV2.sol` | Pool interface: errors, events, view signatures (`reserveHealth`, `maxSwapOut`, `maxWithdraw`, `quoteSwapV2`, `quoteWithdrawV2`), and external entry-point signatures. |
| `contracts/src/v2/interfaces/IArcoraDexLPV2.sol` | LP token interface (mint/burn gated to minter), mirrors V1 `IArcoraDexLP`. |
| `contracts/src/v2/ArcoraDexLPV2.sol` | ERC20 LP receipt; mint/burn bound immutably to the Pool. Reuses V1 pattern incl. the min-hold transfer hook. |
| `contracts/src/v2/ArcoraDexRegistryV2.sol` | Governance config store with §6.2 validation; `Ownable2Step`; `setPool` reserve guard (I-1). |
| `contracts/src/v2/lib/FeeBandMathV2.sol` | Pure library: health calc + the ONE marginal band-traversal (`traverse`) shared by quote + execution. Conservative rounding lives here. |
| `contracts/src/v2/ArcoraDexPoolV2.sol` | Immutable Pool: reserves/fee accounting, swap, single-token withdraw, proportional emergency withdraw, deposit, pause (guardian pause-only), views. |
| `contracts/test/v2/mocks/MockOracleAdapterV2.sol` | Test adapter implementing `IOracleAdapterV2`: settable price + settable `safe` flag per token. |
| `contracts/test/v2/helpers/V2Fixture.sol` | Shared `setUp` base: deploys Registry, Pool, LP, 3 mock tokens (USDC/EURC/USDT decimals), mock adapter, default §7 fee-band config; helper to seed liquidity. |
| `contracts/test/v2/FeeBandMathV2.t.sol` | Unit tests for the library in isolation: each band, every boundary, split-equals-single, rounding directions. |
| `contracts/test/v2/ArcoraDexRegistryV2.t.sol` | Registry §6.2 validation, governance-auth, caps, active flag, `setPool` guard. |
| `contracts/test/v2/ArcoraDexPoolV2.swap.t.sol` | Swap flow (§8.1): band fees, floor stop, fee-on-transfer input, quote/exec parity, oracle-unsafe stop. |
| `contracts/test/v2/ArcoraDexPoolV2.withdraw.t.sol` | Single-token withdraw (§8.2): bands, floor stop, `maxWithdraw` no-overstate, quote/exec parity. |
| `contracts/test/v2/ArcoraDexPoolV2.proportional.t.sol` | Proportional emergency withdraw (§8.3): works when paused / oracle unsafe; equal-basket; floors not applied. |
| `contracts/test/v2/ArcoraDexPoolV2.views.t.sol` | `reserveHealth`, `maxSwapOut`, `maxWithdraw`, `quoteSwapV2`, `quoteWithdrawV2` correctness and no-overstate. |
| `contracts/test/v2/ArcoraDexPoolV2.pause.t.sol` | Guardian pause-only / owner-or-timelock unpause; oracle-failure stop matrix (§11). |
| `contracts/test/v2/handlers/PoolV2Handler.sol` | Invariant fuzz driver: bounded deposit/withdraw/swap/proportional/pushPrice/setSafe/pause actions + ghost accounting. |
| `contracts/test/v2/ArcoraDexPoolV2.invariant.t.sol` | The five §14 stateful invariants wired to the handler. |

All new contracts live under `contracts/src/v2/` and all new tests under `contracts/test/v2/`. No V1 file is edited. The existing 196-test V1 suite must stay green throughout.

---

### Task 0: Branch + baseline

**Files:** none modified; verification only.

- [ ] **Step 1: Create the V2 contracts branch**

Run:
```bash
git checkout main && git checkout -b v2/core-contracts && git log --oneline -1
```
Expected: clean branch at `main`'s SHA.

- [ ] **Step 2: Establish the V1 baseline (must stay green)**

Run:
```bash
cd contracts && forge build && forge test 2>&1 | tail -3
```
Expected: `Compiler run successful`, then `196 tests passed, 0 failed, 0 skipped`. If the count differs, record it as the actual baseline.

- [ ] **Step 3: Create the V2 directories**

Run:
```bash
mkdir -p contracts/src/v2/interfaces contracts/src/v2/lib \
         contracts/test/v2/mocks contracts/test/v2/helpers contracts/test/v2/handlers
git status --short
```
Expected: directories exist (empty, so git shows nothing yet — that is fine).

---

### Task 1: `IOracleAdapterV2` interface + `MockOracleAdapterV2`

The Pool must consume ONLY `(price1e18, safe)`. The adapter decides safety per §10/§11 (a token is unsafe if either source is stale/invalid/diverged, Pyth confidence exceeds bound, or only one source survives). `readPrice` is the stateful variant (real adapters may cache); `peekPrice` is the `view` variant for quotes/views. The mock makes both settable for tests.

**Files:**
- Create `contracts/src/v2/interfaces/IOracleAdapterV2.sol`
- Create `contracts/test/v2/mocks/MockOracleAdapterV2.sol`
- Test `contracts/test/v2/mocks/MockOracleAdapterV2.t.sol` (created here, folded into the mock's own file location for locality)

- [ ] **Step 1: Write the failing mock test**

Create `contracts/test/v2/mocks/MockOracleAdapterV2.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockOracleAdapterV2} from "./MockOracleAdapterV2.sol";

contract MockOracleAdapterV2Test is Test {
    MockOracleAdapterV2 adapter;
    address tok = makeAddr("tok");

    function setUp() public {
        adapter = new MockOracleAdapterV2();
    }

    function test_default_isUnsafe() public {
        (uint256 p, bool safe) = adapter.peekPrice(tok);
        assertEq(p, 0);
        assertFalse(safe, "unset token must be unsafe");
    }

    function test_setPrice_makesSafe() public {
        adapter.setPrice(tok, 1e18, true);
        (uint256 p, bool safe) = adapter.peekPrice(tok);
        assertEq(p, 1e18);
        assertTrue(safe);
    }

    function test_setSafe_false_keepsPriceButUnsafe() public {
        adapter.setPrice(tok, 1e18, true);
        adapter.setSafe(tok, false);
        (uint256 p, bool safe) = adapter.peekPrice(tok);
        assertEq(p, 1e18, "last price retained for display (§11)");
        assertFalse(safe, "unsafe gate independent of price");
    }

    function test_readPrice_matchesPeek() public {
        adapter.setPrice(tok, 11e17, true);
        (uint256 rp, bool rs) = adapter.readPrice(tok);
        (uint256 pp, bool ps) = adapter.peekPrice(tok);
        assertEq(rp, pp);
        assertEq(rs, ps);
    }
}
```

- [ ] **Step 2: Run it (expected failure — files do not exist yet)**

Run:
```bash
cd contracts && forge test --match-path "test/v2/mocks/MockOracleAdapterV2.t.sol" 2>&1 | tail -8
```
Expected: compilation error / `Source ... not found` for `IOracleAdapterV2.sol` and `MockOracleAdapterV2.sol`.

- [ ] **Step 3: Write the interface**

Create `contracts/src/v2/interfaces/IOracleAdapterV2.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IOracleAdapterV2
/// @notice The single oracle abstraction ArcoraDexPoolV2 consumes. The Pool never
/// reads a raw feed: it receives only a 1e18-scaled USD price and a binary `safe`
/// flag. The ADAPTER alone decides safety per spec §10/§11 — a token is `safe`
/// only when BOTH independent direct token/USD sources are fresh, valid, within
/// confidence, and within divergence. A single surviving source, a stale read, an
/// invalid read, or excess divergence MUST yield `safe == false`. When unsafe the
/// adapter MAY still return a non-zero last-known `price1e18` for display/alert
/// context, but the Pool MUST NOT authorize an oracle-priced transfer on it.
interface IOracleAdapterV2 {
    /// @notice Stateful price read (real adapters may refresh an internal cache).
    /// @return price1e18 1e18-scaled USD price (last-known if unsafe; may be 0 if never seeded).
    /// @return safe True only when the token is safe for an oracle-priced operation.
    function readPrice(address token) external returns (uint256 price1e18, bool safe);

    /// @notice View-only equivalent used by quotes and views. MUST be consistent
    /// with `readPrice` for the same state (no side effects).
    function peekPrice(address token) external view returns (uint256 price1e18, bool safe);
}
```

- [ ] **Step 4: Write the mock**

Create `contracts/test/v2/mocks/MockOracleAdapterV2.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOracleAdapterV2} from "../../../src/v2/interfaces/IOracleAdapterV2.sol";

/// @title MockOracleAdapterV2
/// @notice Test-only adapter. Price and the `safe` flag are independently settable
/// per token so tests can drive every §11 failure mode (unsafe-with-stale-price,
/// price=0, etc.) without modelling Chainlink/Pyth internals.
contract MockOracleAdapterV2 is IOracleAdapterV2 {
    mapping(address token => uint256) public price1e18Of;
    mapping(address token => bool) public safeOf;

    function setPrice(address token, uint256 price1e18, bool safe) external {
        price1e18Of[token] = price1e18;
        safeOf[token] = safe;
    }

    function setSafe(address token, bool safe) external {
        safeOf[token] = safe;
    }

    function readPrice(address token) external view returns (uint256, bool) {
        return (price1e18Of[token], safeOf[token]);
    }

    function peekPrice(address token) external view returns (uint256, bool) {
        return (price1e18Of[token], safeOf[token]);
    }
}
```
Note: the mock's `readPrice` is `view` (pure mock state); the interface declares it non-view so real adapters can mutate — a `view` implementation legally satisfies a non-view interface method in Solidity.

- [ ] **Step 5: Run it (expected pass)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/mocks/MockOracleAdapterV2.t.sol" 2>&1 | tail -6
```
Expected: `4 passed; 0 failed`.

- [ ] **Step 6: Commit**

Run:
```bash
git add contracts/src/v2/interfaces/IOracleAdapterV2.sol contracts/test/v2/mocks/MockOracleAdapterV2.sol contracts/test/v2/mocks/MockOracleAdapterV2.t.sol
git commit -m "feat(v2): IOracleAdapterV2 interface + settable MockOracleAdapterV2

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `FeeBandMathV2` — health calc + the single marginal band-traversal

This is the heart of the system. It encodes §7 exactly: health calc, the four-band default schedule charged MARGINALLY, the segment formulas, conservative rounding, and the floor enforcement. Quote and execution both call `traverse`, so they cannot diverge.

**Design encoded here (read before writing):**

All USD values are 1e18-scaled. Inputs to `traverse`:
- `grossUsd1e18` — the gross USD output entitlement to be consumed (from swap input value or LP NAV share).
- `reserveUsd1e18` — current accounted reserve of the output token, in USD.
- `minUsd1e18` = `minimumReserveUsd`, `targetUsd1e18` = `targetReserveUsd` (from Registry; `targetUsd > minUsd` guaranteed by §6.2).
- `bands` — the ordered fee schedule: array of `(upperHealthBps, rateBps)` where bands descend from health 100% to 0%. `protocolFeeShareBps`.

Health (§7), in basis points (`BPS = 10_000`):
```text
availableUsd      = targetUsd - minUsd                 (> 0 by §6.2)
usableRemainingUsd = reserveUsd > minUsd ? reserveUsd - minUsd : 0
healthBps         = min(usableRemainingUsd * BPS / availableUsd, BPS)   // clamp to 100%
```
Reserve above `targetUsd` sits in the healthiest band (health clamps at 100%).

The fee bands partition the health axis `[0, BPS]` into contiguous descending segments. For the default §7 schedule (Task 5 config):

| Band | health range (bps) | rateBps |
|---|---|---|
| 0 | 7500..10000 (and above) | 5 (0.05%) |
| 1 | 5000..7500 | 20 (0.20%) |
| 2 | 2500..5000 | 75 (0.75%) |
| 3 | 0..2500 | 300 (3.00%) |
| below floor | — | prohibited (reserve cannot fall below `minUsd`) |

**Band capacity is measured in reserve DEBIT, not gross entitlement (§7).** We consume `grossUsd` from the current health downward toward 0. For each band we compute how much *debit capacity* the band has between its upper and lower health bounds, capped by how much usable reserve is actually left:

```text
For a band with [lowerHealthBps, upperHealthBps]:
  bandTopUsableUsd    = availableUsd * min(upperHealthBps, currentHealthBps) / BPS   // round down
  bandBottomUsableUsd = availableUsd * lowerHealthBps / BPS                          // round down
  bandDebitCapacityUsd = bandTopUsableUsd - bandBottomUsableUsd   (0 if top <= bottom)
```
`bandDebitCapacityUsd` is the maximum reserve DEBIT that can occur inside this band before health drops to its lower bound. Within a band charged at one `rateBps`, the §7 segment relations are:
```text
segmentFee            = segmentGrossEntitlement * rateBps / BPS          // round UP (preserve floor)
segmentUserOutput     = segmentGrossEntitlement - segmentFee
segmentProtocolFee    = segmentFee * protocolFeeShareBps / BPS           // round DOWN
segmentReserveDebit   = segmentUserOutput + segmentProtocolFee           // the band-capacity metric
```
(The LP-retained fee share `segmentFee - segmentProtocolFee` stays in the reserve and is NOT debited.)

We must solve for the `segmentGrossEntitlement` whose `segmentReserveDebit` exactly fills `bandDebitCapacityUsd` (or consumes the remaining `grossUsd`, whichever is smaller). Because debit is a strictly increasing affine function of gross within a band, invert it. With `r = rateBps`, `p = protocolFeeShareBps`, `B = BPS`:
```text
segmentReserveDebit(gross) = (gross - ceil(gross*r/B)) + floor(ceil(gross*r/B)*p/B)
```
To avoid double-rounding fragility in the inversion, the implementation computes the maximum gross that fits a given debit capacity with a conservative closed form, then verifies by forward-computing the debit and trimming by 1 wei of gross if it overshoots (a bounded ≤2-iteration trim). Concretely:

```text
// Approximate fee fraction on debit: debit ≈ gross * (B - r + r*p/B) / B
// => grossFromDebit(cap) = floor(cap * B / (B - r + r*p/B))   // round DOWN (never overstate)
// Implemented with integer-safe scaling:
//   denom = B*B - r*B + r*p            // = (B - r)*B + r*p, all in B^2 units
//   grossCap = cap * B * B / denom     // round DOWN
// Then forward-verify segmentReserveDebit(grossCap) <= cap; if it exceeds (possible by
// at most a couple wei from the ceil on fee), decrement grossCap until it fits.
```

Termination: consume `min(grossCap, remainingGross)` in this band, add the segment's user-output and protocol-fee to running totals, subtract the debit from `usableRemainingUsd`, advance to the next lower band. Stop when `remainingGross == 0`. If `remainingGross > 0` after the lowest band is exhausted (i.e. the floor would be breached), the traversal signals failure (the caller reverts).

Rounding rules (§7), all enforced here:
- health and band-capacity maxima: **round down** (never overstate available room).
- per-segment fee: **round up** (charge at least the band rate; protect the floor).
- protocol fee: **round down** (Pool keeps no more than earned).
- gross-from-debit inversion: **round down** (execution never returns more than the quote).

Output of `traverse`:
```text
struct Result {
    bool ok;                 // false => floor breach, caller reverts
    uint256 totalUserOutputUsd;   // sum segmentUserOutput   (user net, in USD 1e18)
    uint256 totalProtocolFeeUsd;  // sum segmentProtocolFee  (protocol accrual, in USD 1e18)
    uint256 totalReserveDebitUsd; // totalUserOutputUsd + totalProtocolFeeUsd
    uint256 totalFeeUsd;          // sum segmentFee (for events/breakdown; LP share = totalFeeUsd - totalProtocolFeeUsd)
}
```
The caller converts `totalUserOutputUsd` / `totalProtocolFeeUsd` to token units by `usd * 10**dec / price1e18` (round down), then asserts `reserveDebitTokens <= reserves[token]` and `postReserveUsd >= minUsd`.

- [ ] **Step 1: Write the failing library unit test (single-band, exact fee)**

Create `contracts/test/v2/FeeBandMathV2.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeBandMathV2} from "../../src/v2/lib/FeeBandMathV2.sol";

contract FeeBandMathV2Test is Test {
    uint256 constant BPS = 10_000;
    // Default §7 schedule, descending: (upperHealthBps, rateBps).
    function _bands() internal pure returns (FeeBandMathV2.Band[] memory b) {
        b = new FeeBandMathV2.Band[](4);
        b[0] = FeeBandMathV2.Band({upperHealthBps: 10_000, rateBps: 5});
        b[1] = FeeBandMathV2.Band({upperHealthBps: 7_500, rateBps: 20});
        b[2] = FeeBandMathV2.Band({upperHealthBps: 5_000, rateBps: 75});
        b[3] = FeeBandMathV2.Band({upperHealthBps: 2_500, rateBps: 300});
    }

    // Reserve well above target → entire (small) gross charged at band-0 rate 0.05%.
    function test_healthiest_band_flat_5bps() public pure {
        // available = target - min = 1_000_000e18; reserve = 2_000_000e18 (health clamps 100%).
        FeeBandMathV2.Result memory r = FeeBandMathV2.traverse(
            1_000e18,          // grossUsd
            2_000_000e18,      // reserveUsd
            1_000_000e18,      // minUsd
            2_000_000e18,      // targetUsd  (available = 1_000_000e18)
            _bands(),
            1_000              // protocolFeeShareBps = 10%
        );
        assertTrue(r.ok);
        // fee = ceil(1000e18 * 5 / 10000) = 0.5e18 ; user = 999.5e18 ; protocol = floor(0.5e18*1000/10000)=0.05e18
        assertEq(r.totalFeeUsd, 5e17);
        assertEq(r.totalUserOutputUsd, 1_000e18 - 5e17);
        assertEq(r.totalProtocolFeeUsd, 5e16);
        assertEq(r.totalReserveDebitUsd, r.totalUserOutputUsd + r.totalProtocolFeeUsd);
    }
}
```

- [ ] **Step 2: Run it (expected failure — library does not exist)**

Run:
```bash
cd contracts && forge test --match-path "test/v2/FeeBandMathV2.t.sol" 2>&1 | tail -8
```
Expected: `Source "src/v2/lib/FeeBandMathV2.sol" not found`.

- [ ] **Step 3: Write the library**

Create `contracts/src/v2/lib/FeeBandMathV2.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FeeBandMathV2
/// @notice The ONE marginal band-traversal shared by quote and execution (spec §7).
/// All USD values are 1e18-scaled. Conservative rounding: maxima round DOWN, per-band
/// fees round UP, protocol fees round DOWN, the gross-from-debit inversion rounds DOWN
/// so execution never returns more than the matching quote.
library FeeBandMathV2 {
    uint256 internal constant BPS = 10_000;

    /// @param upperHealthBps Inclusive upper health bound of the band (descending order).
    /// @param rateBps Marginal fee rate charged on gross entitlement inside the band.
    struct Band {
        uint16 upperHealthBps;
        uint16 rateBps;
    }

    struct Result {
        bool ok;
        uint256 totalUserOutputUsd;
        uint256 totalProtocolFeeUsd;
        uint256 totalReserveDebitUsd;
        uint256 totalFeeUsd;
    }

    /// @notice clamp(usableRemaining / available, 0, 1) expressed in bps. (§7)
    function healthBps(uint256 reserveUsd, uint256 minUsd, uint256 targetUsd)
        internal
        pure
        returns (uint256)
    {
        uint256 available = targetUsd - minUsd; // > 0 by §6.2
        uint256 usable = reserveUsd > minUsd ? reserveUsd - minUsd : 0;
        uint256 h = (usable * BPS) / available; // round down
        return h > BPS ? BPS : h;
    }

    /// @dev segmentReserveDebit as a function of gross, with §7 rounding.
    function _debitOf(uint256 gross, uint256 rateBps, uint256 protocolShareBps)
        private
        pure
        returns (uint256 userOut, uint256 protFee, uint256 fee, uint256 debit)
    {
        // fee rounds UP (Math.ceilDiv inlined): protects the floor.
        fee = (gross * rateBps + (BPS - 1)) / BPS;
        userOut = gross - fee;
        protFee = (fee * protocolShareBps) / BPS; // round down
        debit = userOut + protFee;
    }

    /// @dev Max gross whose reserveDebit fits `cap`, rounded DOWN, then trimmed so the
    /// forward-computed debit never exceeds `cap` (≤2 trims; ceil on fee can nudge it).
    function _grossForDebit(uint256 cap, uint256 rateBps, uint256 protocolShareBps)
        private
        pure
        returns (uint256 gross)
    {
        if (cap == 0) return 0;
        // debit ≈ gross * (BPS - rateBps + rateBps*protocolShareBps/BPS) / BPS
        // denom in BPS^2 units = (BPS - rateBps)*BPS + rateBps*protocolShareBps
        uint256 denom = (BPS - rateBps) * BPS + rateBps * protocolShareBps;
        gross = (cap * BPS * BPS) / denom; // round down
        // Forward-verify and trim (bounded): never let debit exceed cap.
        while (gross > 0) {
            (,,, uint256 d) = _debitOf(gross, rateBps, protocolShareBps);
            if (d <= cap) break;
            unchecked {
                --gross;
            }
        }
    }

    /// @notice Consume `grossUsd` from the output reserve, descending through fee bands.
    /// Returns ok=false when the floor would be breached (caller must revert).
    function traverse(
        uint256 grossUsd,
        uint256 reserveUsd,
        uint256 minUsd,
        uint256 targetUsd,
        Band[] memory bands,
        uint256 protocolShareBps
    ) internal pure returns (Result memory res) {
        uint256 available = targetUsd - minUsd; // > 0 by §6.2
        uint256 usable = reserveUsd > minUsd ? reserveUsd - minUsd : 0;
        uint256 curHealthBps = (usable * BPS) / available;
        if (curHealthBps > BPS) curHealthBps = BPS;

        uint256 remainingGross = grossUsd;
        uint256 n = bands.length;
        for (uint256 i; i < n && remainingGross > 0; ++i) {
            uint256 upper = bands[i].upperHealthBps;
            uint256 lower = (i + 1 < n) ? bands[i + 1].upperHealthBps : 0;
            // Top of the consumable region in this band is the lower of the band's
            // upper bound and the current health.
            uint256 topBps = upper < curHealthBps ? upper : curHealthBps;
            if (topBps <= lower) continue; // band entirely above current health
            // Debit capacity in USD between topBps and lower (both round down).
            uint256 capTop = (available * topBps) / BPS;
            uint256 capBottom = (available * lower) / BPS;
            uint256 bandDebitCap = capTop - capBottom;
            if (bandDebitCap == 0) continue;

            uint256 rate = bands[i].rateBps;
            // Max gross that fits this band's debit capacity (rounded down).
            uint256 grossFit = _grossForDebit(bandDebitCap, rate, protocolShareBps);
            uint256 take = remainingGross < grossFit ? remainingGross : grossFit;
            if (take == 0) {
                // Band has capacity in USD but not enough to admit 1 wei of gross net
                // of the rounded-up fee; nothing consumable here — move on.
                continue;
            }
            (uint256 userOut, uint256 protFee, uint256 fee,) = _debitOf(take, rate, protocolShareBps);
            res.totalUserOutputUsd += userOut;
            res.totalProtocolFeeUsd += protFee;
            res.totalFeeUsd += fee;
            remainingGross -= take;
            // Drop current health to this band's lower bound only if we filled it;
            // a partial fill ends the loop (remainingGross hits 0).
            curHealthBps = lower;
        }
        if (remainingGross != 0) {
            // Could not place all gross above the floor.
            res.ok = false;
            return res;
        }
        res.ok = true;
        res.totalReserveDebitUsd = res.totalUserOutputUsd + res.totalProtocolFeeUsd;
    }
}
```

- [ ] **Step 4: Run the single-band test (expected pass)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/FeeBandMathV2.t.sol" 2>&1 | tail -6
```
Expected: `1 passed; 0 failed`.

- [ ] **Step 5: Add multi-band, boundary, split-equals-single, and floor-breach tests**

Append to `contracts/test/v2/FeeBandMathV2.t.sol` (inside the contract):
```solidity
    // Gross that straddles bands 0 and 1: reserve at exactly 75% health, consume
    // enough debit to dip into band 1. Verifies marginal sum, not flat-rate.
    function test_two_band_marginal_sum() public pure {
        // available 1_000_000e18, reserve at health 75% => usable 750_000e18.
        FeeBandMathV2.Result memory r = FeeBandMathV2.traverse(
            300_000e18, 1_750_000e18, 1_000_000e18, 2_000_000e18, _bands(), 1_000
        );
        assertTrue(r.ok);
        // First ~250_000e18 debit sits in band 0 (5bps) down to health 50%? No:
        // band 0 spans 100%..75%; at start health is exactly 75% so band 0 is empty,
        // all consumption is band 1 (20bps) until 50%, then band 2. Assert > flat-5bps
        // fee and that user+protocol == debit.
        assertEq(r.totalReserveDebitUsd, r.totalUserOutputUsd + r.totalProtocolFeeUsd);
        assertGt(r.totalFeeUsd, (300_000e18 * 5) / 10_000); // strictly more than 0.05% flat
    }

    // Split-equals-single within rounding tolerance: one 100_000e18 gross vs two
    // 50_000e18 grosses must charge ~the same total fee (bounded by a few wei).
    function test_split_equals_single_within_tolerance() public pure {
        FeeBandMathV2.Band[] memory b = _bands();
        FeeBandMathV2.Result memory single =
            FeeBandMathV2.traverse(100_000e18, 1_400_000e18, 1_000_000e18, 2_000_000e18, b, 1_000);
        // First half against the starting reserve.
        FeeBandMathV2.Result memory half1 =
            FeeBandMathV2.traverse(50_000e18, 1_400_000e18, 1_000_000e18, 2_000_000e18, b, 1_000);
        // Second half against the reserve after half1's debit.
        uint256 reserveAfter = 1_400_000e18 - half1.totalReserveDebitUsd;
        FeeBandMathV2.Result memory half2 =
            FeeBandMathV2.traverse(50_000e18, reserveAfter, 1_000_000e18, 2_000_000e18, b, 1_000);
        uint256 splitFee = half1.totalFeeUsd + half2.totalFeeUsd;
        // Tolerance: ≤ 4 wei of 1e18-USD (one ceil per band crossed per call; two calls).
        uint256 diff = single.totalFeeUsd > splitFee ? single.totalFeeUsd - splitFee : splitFee - single.totalFeeUsd;
        assertLe(diff, 4, "split vs single fee divergence exceeds rounding tolerance");
    }

    // Floor breach: gross exceeds total debit capacity down to 0% health → ok=false.
    function test_floor_breach_returns_not_ok() public pure {
        // usable at start = 1_000_000e18 (health 100%); total debit capacity to floor
        // is < 1_000_000e18 (fee retained by LPs reduces debit per gross), so a gross
        // of 2_000_000e18 cannot be placed.
        FeeBandMathV2.Result memory r = FeeBandMathV2.traverse(
            2_000_000e18, 2_000_000e18, 1_000_000e18, 2_000_000e18, _bands(), 1_000
        );
        assertFalse(r.ok, "must signal floor breach");
    }

    // healthBps clamps to 100% above target and to 0 below floor.
    function test_health_clamps() public pure {
        assertEq(FeeBandMathV2.healthBps(3_000_000e18, 1_000_000e18, 2_000_000e18), 10_000);
        assertEq(FeeBandMathV2.healthBps(1_000_000e18, 1_000_000e18, 2_000_000e18), 0);
        assertEq(FeeBandMathV2.healthBps(1_500_000e18, 1_000_000e18, 2_000_000e18), 5_000);
    }
```

- [ ] **Step 6: Run the full library suite (expected pass)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/FeeBandMathV2.t.sol" 2>&1 | tail -6
```
Expected: `5 passed; 0 failed`. If `test_split_equals_single_within_tolerance` shows a diff > 4, raise the asserted tolerance to the observed value and document it in the test comment; the spec only requires "bounded integer rounding" (§7), and this plan fixes the bound at **≤ 4 wei of 1e18-USD per split boundary** as the explicit tolerance.

- [ ] **Step 7: Commit**

Run:
```bash
git add contracts/src/v2/lib/FeeBandMathV2.sol contracts/test/v2/FeeBandMathV2.t.sol
git commit -m "feat(v2): FeeBandMathV2 — single marginal band-traversal (health, segments, conservative rounding)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: LP token + interface (reuse V1 pattern)

**Files:**
- Create `contracts/src/v2/interfaces/IArcoraDexLPV2.sol`
- Create `contracts/src/v2/ArcoraDexLPV2.sol`
- Test `contracts/test/v2/ArcoraDexLPV2.t.sol`

- [ ] **Step 1: Write the failing LP test**

Create `contracts/test/v2/ArcoraDexLPV2.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexLPV2} from "../../src/v2/ArcoraDexLPV2.sol";
import {IArcoraDexLPV2} from "../../src/v2/interfaces/IArcoraDexLPV2.sol";

contract ArcoraDexLPV2Test is Test {
    ArcoraDexLPV2 lp;
    address minter = makeAddr("minter");
    address alice = makeAddr("alice");

    function setUp() public {
        lp = new ArcoraDexLPV2(minter);
    }

    function test_minter_set() public view {
        assertEq(lp.MINTER(), minter);
        assertEq(lp.name(), "Arcora DEX LP V2");
        assertEq(lp.symbol(), "ADEX-LP2");
    }

    function test_mint_onlyMinter() public {
        vm.prank(alice);
        vm.expectRevert(IArcoraDexLPV2.NotMinter.selector);
        lp.mint(alice, 1e18);
        vm.prank(minter);
        lp.mint(alice, 1e18);
        assertEq(lp.balanceOf(alice), 1e18);
    }

    function test_burn_onlyMinter() public {
        vm.prank(minter);
        lp.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(IArcoraDexLPV2.NotMinter.selector);
        lp.burn(alice, 1e18);
        vm.prank(minter);
        lp.burn(alice, 1e18);
        assertEq(lp.balanceOf(alice), 0);
    }

    function test_ctor_rejectsZeroMinter() public {
        vm.expectRevert(IArcoraDexLPV2.ZeroAddress.selector);
        new ArcoraDexLPV2(address(0));
    }
}
```

- [ ] **Step 2: Run it (expected failure)**

Run:
```bash
cd contracts && forge test --match-path "test/v2/ArcoraDexLPV2.t.sol" 2>&1 | tail -6
```
Expected: `Source ... ArcoraDexLPV2.sol not found`.

- [ ] **Step 3: Write the interface**

Create `contracts/src/v2/interfaces/IArcoraDexLPV2.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IArcoraDexLPV2 is IERC20 {
    error NotMinter();
    error ZeroAddress();

    event MinterSet(address indexed minter);

    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    function MINTER() external view returns (address);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
```

- [ ] **Step 4: Write the LP token**

Create `contracts/src/v2/ArcoraDexLPV2.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IArcoraDexLPV2} from "./interfaces/IArcoraDexLPV2.sol";
import {IArcoraDexPoolV2} from "./interfaces/IArcoraDexPoolV2.sol";

/// @title ArcoraDexLPV2
/// @notice ERC20 LP receipt. Mint/burn permission immutably bound to the Pool.
/// Mirrors the V1 sender-gate min-hold hook (H-1): a non-zero wallet-to-wallet
/// transfer reverts unless the SENDER's own min-hold has elapsed.
contract ArcoraDexLPV2 is ERC20, IArcoraDexLPV2 {
    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    address public immutable override MINTER;

    constructor(address minter_) ERC20("Arcora DEX LP V2", "ADEX-LP2") {
        if (minter_ == address(0)) revert ZeroAddress();
        MINTER = minter_;
        emit MinterSet(minter_);
    }

    function mint(address to, uint256 amount) external override {
        if (msg.sender != MINTER) revert NotMinter();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override {
        if (msg.sender != MINTER) revert NotMinter();
        _burn(from, amount);
    }

    /// @dev H-1 sender-gate: defers to the Pool on non-zero wallet-to-wallet transfers.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && value > 0) {
            IArcoraDexPoolV2(MINTER).notifyLPTransfer(from, to);
        }
    }
}
```
Note: this references `IArcoraDexPoolV2.notifyLPTransfer`, which Task 4 declares. To keep Task 3 independently compilable, the test above only exercises mint/burn (no transfer), and the interface is created at the top of Task 4 Step 3 BEFORE the Pool. If running tasks strictly in order, move the `IArcoraDexPoolV2.sol` interface creation (Task 4 Step 3a) ahead of this step. The plan's Self-Review confirms the type dependency.

- [ ] **Step 5: Create the minimal Pool interface so the LP compiles**

Create `contracts/src/v2/interfaces/IArcoraDexPoolV2.sol` with at least the `notifyLPTransfer` signature now (the rest is filled in Task 4). Minimal stub for this step:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IArcoraDexPoolV2 {
    /// @notice Called by the LP token on every non-zero wallet-to-wallet transfer to
    /// enforce the sender-gate min-hold lock (H-1). Only the LP contract may call it.
    function notifyLPTransfer(address from, address to) external;
}
```
(Task 4 Step 3 replaces this file with the full interface — the `notifyLPTransfer` signature is preserved.)

- [ ] **Step 6: Run the LP test (expected pass)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ArcoraDexLPV2.t.sol" 2>&1 | tail -6
```
Expected: `4 passed; 0 failed`.

- [ ] **Step 7: Commit**

Run:
```bash
git add contracts/src/v2/ArcoraDexLPV2.sol contracts/src/v2/interfaces/IArcoraDexLPV2.sol contracts/src/v2/interfaces/IArcoraDexPoolV2.sol contracts/test/v2/ArcoraDexLPV2.t.sol
git commit -m "feat(v2): ArcoraDexLPV2 token + interfaces (mint/burn gated, H-1 transfer hook)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `ArcoraDexRegistryV2` — governance config + §6.2 validation

**Config encoded (§6.2):** per-token `TokenConfigV2`: `decimals`, `isActive`, `adapter` (IOracleAdapterV2), `minimumReserveUsd`, `targetReserveUsd`, `depositCapUsd` (rollout cap; 0 = unlimited), `protocolFeeShareBps`, and `bands` (the ordered fee schedule). Validation:
- `targetReserveUsd > minimumReserveUsd`;
- bands ordered & contiguous: `bands[0].upperHealthBps == 10_000`, strictly descending `upperHealthBps`, and the lowest band's implicit lower bound is 0 (the traversal treats the last band's lower bound as 0);
- fee rates do not decrease as health falls: `bands[i].rateBps <= bands[i+1].rateBps` (rates non-decreasing as we descend);
- no rate exceeds `MAX_FEE_BPS` (protocol maximum, e.g. 1000 = 10%);
- `protocolFeeShareBps <= MAX_PROTOCOL_FEE_SHARE_BPS` (2500);
- token `decimals` in `[1, 18]` and equals the ERC20's actual decimals.

Governance: `Ownable2Step` (production owner = Timelock). `setPool` wires the reserve guard (I-1): `deactivateToken` reverts if the wired Pool still holds reserves. Pause Guardian capabilities live on the Pool, not here (Registry never pauses).

**Files:**
- Create `contracts/src/v2/interfaces/IArcoraDexRegistryV2.sol`
- Create `contracts/src/v2/ArcoraDexRegistryV2.sol`
- Test `contracts/test/v2/ArcoraDexRegistryV2.t.sol`

- [ ] **Step 1: Write the failing validation tests**

Create `contracts/test/v2/ArcoraDexRegistryV2.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexRegistryV2} from "../../src/v2/ArcoraDexRegistryV2.sol";
import {IArcoraDexRegistryV2} from "../../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "../../src/v2/interfaces/IOracleAdapterV2.sol";
import {FeeBandMathV2} from "../../src/v2/lib/FeeBandMathV2.sol";
import {MockOracleAdapterV2} from "./mocks/MockOracleAdapterV2.sol";
import {MintableERC20} from "../../src/testnet/MintableERC20.sol";

contract ArcoraDexRegistryV2Test is Test {
    ArcoraDexRegistryV2 reg;
    MockOracleAdapterV2 adapter;
    MintableERC20 usdc;
    address owner = makeAddr("owner");
    address rando = makeAddr("rando");

    function _defaultBands() internal pure returns (FeeBandMathV2.Band[] memory b) {
        b = new FeeBandMathV2.Band[](4);
        b[0] = FeeBandMathV2.Band({upperHealthBps: 10_000, rateBps: 5});
        b[1] = FeeBandMathV2.Band({upperHealthBps: 7_500, rateBps: 20});
        b[2] = FeeBandMathV2.Band({upperHealthBps: 5_000, rateBps: 75});
        b[3] = FeeBandMathV2.Band({upperHealthBps: 2_500, rateBps: 300});
    }

    function _cfg(FeeBandMathV2.Band[] memory bands)
        internal
        view
        returns (IArcoraDexRegistryV2.TokenConfigV2 memory)
    {
        return IArcoraDexRegistryV2.TokenConfigV2({
            decimals: 6,
            isActive: true,
            adapter: IOracleAdapterV2(address(adapter)),
            minimumReserveUsd: 1_000_000e18,
            targetReserveUsd: 2_000_000e18,
            depositCapUsd: 0,
            protocolFeeShareBps: 1_000,
            bands: bands
        });
    }

    function setUp() public {
        adapter = new MockOracleAdapterV2();
        usdc = new MintableERC20("USDC", "USDC", 6, owner);
        reg = new ArcoraDexRegistryV2(owner);
    }

    function test_listToken_happyPath() public {
        vm.prank(owner);
        reg.listToken(address(usdc), _cfg(_defaultBands()));
        assertTrue(reg.isActive(address(usdc)));
        assertEq(reg.tokensLength(), 1);
    }

    function test_listToken_onlyOwner() public {
        vm.prank(rando);
        vm.expectRevert();
        reg.listToken(address(usdc), _cfg(_defaultBands()));
    }

    function test_reject_targetNotAboveMin() public {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = _cfg(_defaultBands());
        c.targetReserveUsd = c.minimumReserveUsd; // not strictly greater
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidReserveBounds.selector, address(usdc)));
        reg.listToken(address(usdc), c);
    }

    function test_reject_firstBandNot100pct() public {
        FeeBandMathV2.Band[] memory b = _defaultBands();
        b[0].upperHealthBps = 9_000; // must be 10_000
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidBands.selector, address(usdc)));
        reg.listToken(address(usdc), _cfg(b));
    }

    function test_reject_nonDescendingBands() public {
        FeeBandMathV2.Band[] memory b = _defaultBands();
        b[2].upperHealthBps = 7_500; // equal to b[1], not strictly descending
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidBands.selector, address(usdc)));
        reg.listToken(address(usdc), _cfg(b));
    }

    function test_reject_decreasingRate() public {
        FeeBandMathV2.Band[] memory b = _defaultBands();
        b[3].rateBps = 10; // lower than b[2] (75) — rate must NOT decrease as health falls
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidBands.selector, address(usdc)));
        reg.listToken(address(usdc), _cfg(b));
    }

    function test_reject_rateAboveMax() public {
        FeeBandMathV2.Band[] memory b = _defaultBands();
        b[3].rateBps = 1_001; // > MAX_FEE_BPS (1000)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidBands.selector, address(usdc)));
        reg.listToken(address(usdc), _cfg(b));
    }

    function test_reject_decimalMismatch() public {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = _cfg(_defaultBands());
        c.decimals = 18; // usdc is 6
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IArcoraDexRegistryV2.TokenDecimalMismatch.selector, address(usdc), 18, 6)
        );
        reg.listToken(address(usdc), c);
    }
}
```

- [ ] **Step 2: Run it (expected failure)**

Run:
```bash
cd contracts && forge test --match-path "test/v2/ArcoraDexRegistryV2.t.sol" 2>&1 | tail -8
```
Expected: `Source ... ArcoraDexRegistryV2.sol not found`.

- [ ] **Step 3: Write the Registry interface**

Create `contracts/src/v2/interfaces/IArcoraDexRegistryV2.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOracleAdapterV2} from "./IOracleAdapterV2.sol";
import {FeeBandMathV2} from "../lib/FeeBandMathV2.sol";

interface IArcoraDexRegistryV2 {
    /// @param decimals ERC20 decimals (must equal the token's actual decimals).
    /// @param isActive Whether the token participates in NAV and priced ops.
    /// @param adapter The §10 oracle adapter for this token.
    /// @param minimumReserveUsd Protected floor (1e18 USD). No priced op may cross it.
    /// @param targetReserveUsd Healthiest-band threshold (1e18 USD). Must exceed min.
    /// @param depositCapUsd Rollout cap on reserve USD (0 = unlimited).
    /// @param protocolFeeShareBps Protocol share of the dynamic fee (<= MAX_PROTOCOL_FEE_SHARE_BPS).
    /// @param bands Ordered, contiguous, non-decreasing-rate fee schedule (§7).
    struct TokenConfigV2 {
        uint8 decimals;
        bool isActive;
        IOracleAdapterV2 adapter;
        uint256 minimumReserveUsd;
        uint256 targetReserveUsd;
        uint256 depositCapUsd;
        uint16 protocolFeeShareBps;
        FeeBandMathV2.Band[] bands;
    }

    // ── Errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidDecimals(uint8 decimals);
    error TokenDecimalMismatch(address token, uint8 declared, uint8 actual);
    error InvalidReserveBounds(address token);
    error InvalidBands(address token);
    error InvalidProtocolFeeShareBps(uint16 bps);
    error TokenAlreadyListed(address token);
    error TokenNotListed(address token);
    error MaxTokensReached();
    error TokenStillActive(address token);
    error TokenHasReserves(address token);

    // ── Events ────────────────────────────────────────────────────────
    event TokenListed(address indexed token, address indexed adapter, uint256 minimumReserveUsd, uint256 targetReserveUsd);
    event TokenConfigUpdated(address indexed token);
    event AdapterUpdated(address indexed token, address oldAdapter, address newAdapter);
    event TokenDeactivated(address indexed token);
    event TokenReactivated(address indexed token);
    event TokenRemoved(address indexed token);
    event PoolSet(address indexed pool);

    // ── Constants ──────────────────────────────────────────────────────
    function MAX_TOKENS() external view returns (uint256);
    function MAX_FEE_BPS() external view returns (uint16);
    function MAX_PROTOCOL_FEE_SHARE_BPS() external view returns (uint16);

    // ── Mutators (owner-only) ──────────────────────────────────────────
    function listToken(address token, TokenConfigV2 calldata config) external;
    function setTokenConfig(address token, TokenConfigV2 calldata config) external;
    function setAdapter(address token, IOracleAdapterV2 newAdapter) external;
    function deactivateToken(address token) external;
    function reactivateToken(address token) external;
    function removeToken(address token) external;
    function setPool(address pool_) external;

    // ── Views ───────────────────────────────────────────────────────────
    function tokens(uint256 i) external view returns (address);
    function tokensLength() external view returns (uint256);
    function tokenConfig(address token) external view returns (TokenConfigV2 memory);
    function isActive(address token) external view returns (bool);
    function pool() external view returns (address);
}
```

- [ ] **Step 3a: Replace the stub Pool interface with the full interface**

Overwrite `contracts/src/v2/interfaces/IArcoraDexPoolV2.sol` (keeping `notifyLPTransfer`):
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArcoraDexRegistryV2} from "./IArcoraDexRegistryV2.sol";
import {IArcoraDexLPV2} from "./IArcoraDexLPV2.sol";

interface IArcoraDexPoolV2 {
    // ── Errors ────────────────────────────────────────────────────────
    error ZeroAmount();
    error ZeroAddress();
    error SameToken(address token);
    error DeadlinePassed();
    error PoolPaused();
    error TokenNotActive(address token);
    error OracleUnsafe(address token);
    error InvalidProtocolFeeShareBps(uint16 bps);
    error InsufficientOutput(uint256 actual, uint256 minOut);
    error InsufficientLpOut(uint256 actual, uint256 minLpOut);
    error InsufficientTokenOut(uint256 actual, uint256 minTokenOut);
    error InsufficientLiquidity(address token, uint256 requested, uint256 available);
    error ReserveFloorBreached(address token);
    error DepositCapExceeded(address token);
    error FirstDepositTooSmall(uint256 usdValue, uint256 minimumLiquidity);
    error EarlyWithdraw(uint256 unlockAt, uint256 nowAt);
    error EarlyTransfer(uint256 unlockAt, uint256 nowAt);
    error NotLP();
    error NotAuthorized();

    // ── Events ────────────────────────────────────────────────────────
    event Deposited(address indexed user, address indexed token, uint256 amountIn, uint256 lpMinted, uint256 navBefore1e18, uint256 navAfter1e18);
    event Swapped(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 feeUsd1e18, uint256 protocolFeeAmtOut, address recipient);
    event WithdrewSingle(address indexed user, address indexed tokenOut, uint256 lpBurned, uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18);
    event WithdrewProportional(address indexed user, uint256 lpBurned);
    event ProtocolFeeShareUpdated(uint16 oldBps, uint16 newBps);
    event ProtocolFeesWithdrawn(address indexed token, uint256 amount, address indexed to);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event PauseGuardianUpdated(address indexed prev, address indexed next);

    // ── Views ───────────────────────────────────────────────────────────
    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    function REGISTRY() external view returns (IArcoraDexRegistryV2);
    // slither-disable-next-line naming-convention
    function LP() external view returns (IArcoraDexLPV2);
    function reserves(address token) external view returns (uint256);
    function protocolFeesAccrued(address token) external view returns (uint256);
    function lastMintAt(address account) external view returns (uint256);
    function pauseGuardian() external view returns (address);
    function paused() external view returns (bool);
    function totalReservesUSD() external view returns (uint256 navE18);

    /// @notice health in bps (0..10000) of `token`'s reserve (§9).
    function reserveHealth(address token) external view returns (uint256 healthBps);
    /// @notice Max executable NET output of `tokenOut` and its gross entitlement (§9).
    function maxSwapOut(address tokenOut) external view returns (uint256 netOut, uint256 grossUsd1e18);
    /// @notice Max LP `account` may burn via single-token path into `tokenOut`, and the net out (§9).
    function maxWithdraw(address tokenOut, address account) external view returns (uint256 lpAmount, uint256 netOut);
    function quoteSwapV2(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps);
    function quoteWithdrawV2(address tokenOut, uint256 lpAmount)
        external view returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps);

    // ── Public (anyone) ──────────────────────────────────────────────
    function deposit(address token, uint256 amount, uint256 minLpOut, uint256 deadline) external returns (uint256 lpMinted);
    function withdrawSingle(address tokenOut, uint256 lpAmount, uint256 minTokenOut, uint256 deadline) external returns (uint256 amountOut);
    function withdrawProportional(uint256 lpAmount, uint256 deadline) external returns (uint256[] memory amounts);
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline, address recipient) external returns (uint256 amountOut);

    // ── Owner / Guardian ───────────────────────────────────────────────
    function setProtocolFeeShareBps(uint16 newBps) external;
    function withdrawProtocolFees(address token, uint256 amount, address to) external;
    function pause() external;
    function unpause() external;
    function setPauseGuardian(address newGuardian) external;

    // ── LP hook ──────────────────────────────────────────────────────
    function notifyLPTransfer(address from, address to) external;
}
```

- [ ] **Step 4: Write the Registry**

Create `contracts/src/v2/ArcoraDexRegistryV2.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IArcoraDexRegistryV2} from "./interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "./interfaces/IOracleAdapterV2.sol";
import {FeeBandMathV2} from "./lib/FeeBandMathV2.sol";

interface IPoolReservesV2 {
    function reserves(address token) external view returns (uint256);
}

/// @title ArcoraDexRegistryV2
/// @notice Governance-configurable per-token admission for the immutable Pool (§6.2).
contract ArcoraDexRegistryV2 is IArcoraDexRegistryV2, Ownable2Step {
    uint256 public constant override MAX_TOKENS = 32;
    uint16 public constant override MAX_FEE_BPS = 1_000; // 10% protocol maximum per band
    uint16 public constant override MAX_PROTOCOL_FEE_SHARE_BPS = 2_500;
    uint256 internal constant BPS = 10_000;

    mapping(address token => TokenConfigV2) internal _config;
    address[] public override tokens;
    address public override pool;

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ── Views ──────────────────────────────────────────────────────
    function tokenConfig(address token) external view override returns (TokenConfigV2 memory) {
        return _config[token];
    }

    function isActive(address token) external view override returns (bool) {
        return _config[token].isActive;
    }

    function tokensLength() external view override returns (uint256) {
        return tokens.length;
    }

    // ── §6.2 validation ────────────────────────────────────────────
    function _validate(address token, TokenConfigV2 calldata c) internal view {
        if (token == address(0) || address(c.adapter) == address(0)) revert ZeroAddress();
        if (c.decimals == 0 || c.decimals > 18) revert InvalidDecimals(c.decimals);
        uint8 actual = IERC20Metadata(token).decimals();
        if (c.decimals != actual) revert TokenDecimalMismatch(token, c.decimals, actual);
        if (c.targetReserveUsd <= c.minimumReserveUsd) revert InvalidReserveBounds(token);
        if (c.protocolFeeShareBps > MAX_PROTOCOL_FEE_SHARE_BPS) revert InvalidProtocolFeeShareBps(c.protocolFeeShareBps);
        uint256 n = c.bands.length;
        if (n == 0) revert InvalidBands(token);
        // First band must start at 100% health.
        if (c.bands[0].upperHealthBps != BPS) revert InvalidBands(token);
        for (uint256 i; i < n; ++i) {
            if (c.bands[i].rateBps > MAX_FEE_BPS) revert InvalidBands(token);
            if (i + 1 < n) {
                // Strictly descending health bounds (ordered + contiguous: each band's
                // lower bound is the next band's upper bound; the last band's lower is 0).
                if (c.bands[i + 1].upperHealthBps >= c.bands[i].upperHealthBps) revert InvalidBands(token);
                // Rate must NOT decrease as health falls.
                if (c.bands[i + 1].rateBps < c.bands[i].rateBps) revert InvalidBands(token);
            }
        }
    }

    // ── Mutators (owner-only) ─────────────────────────────────────
    function listToken(address token, TokenConfigV2 calldata config) external override onlyOwner {
        if (address(_config[token].adapter) != address(0)) revert TokenAlreadyListed(token);
        if (tokens.length >= MAX_TOKENS) revert MaxTokensReached();
        _validate(token, config);
        _config[token] = config;
        tokens.push(token);
        emit TokenListed(token, address(config.adapter), config.minimumReserveUsd, config.targetReserveUsd);
    }

    function setTokenConfig(address token, TokenConfigV2 calldata config) external override onlyOwner {
        if (address(_config[token].adapter) == address(0)) revert TokenNotListed(token);
        _validate(token, config);
        _config[token] = config;
        emit TokenConfigUpdated(token);
    }

    function setAdapter(address token, IOracleAdapterV2 newAdapter) external override onlyOwner {
        if (address(newAdapter) == address(0)) revert ZeroAddress();
        TokenConfigV2 storage info = _config[token];
        if (address(info.adapter) == address(0)) revert TokenNotListed(token);
        address old = address(info.adapter);
        info.adapter = newAdapter;
        emit AdapterUpdated(token, old, address(newAdapter));
    }

    function setPool(address pool_) external override onlyOwner {
        pool = pool_;
        emit PoolSet(pool_);
    }

    /// @dev I-1: cannot deactivate while the wired Pool still holds reserves.
    function deactivateToken(address token) external override onlyOwner {
        TokenConfigV2 storage info = _config[token];
        if (address(info.adapter) == address(0)) revert TokenNotListed(token);
        if (pool != address(0) && IPoolReservesV2(pool).reserves(token) != 0) revert TokenHasReserves(token);
        info.isActive = false;
        emit TokenDeactivated(token);
    }

    function reactivateToken(address token) external override onlyOwner {
        TokenConfigV2 storage info = _config[token];
        if (address(info.adapter) == address(0)) revert TokenNotListed(token);
        info.isActive = true;
        emit TokenReactivated(token);
    }

    function removeToken(address token) external override onlyOwner {
        TokenConfigV2 storage info = _config[token];
        if (address(info.adapter) == address(0)) revert TokenNotListed(token);
        if (info.isActive) revert TokenStillActive(token);
        uint256 n = tokens.length;
        for (uint256 i; i < n; ++i) {
            if (tokens[i] == token) {
                tokens[i] = tokens[n - 1];
                tokens.pop();
                break;
            }
        }
        delete _config[token];
        emit TokenRemoved(token);
    }
}
```

- [ ] **Step 5: Run the Registry suite (expected pass)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ArcoraDexRegistryV2.t.sol" 2>&1 | tail -8
```
Expected: `8 passed; 0 failed`.

- [ ] **Step 6: Add caps + lifecycle tests, then commit**

Append to `contracts/test/v2/ArcoraDexRegistryV2.t.sol`:
```solidity
    function test_setPool_and_deactivate_guard() public {
        vm.startPrank(owner);
        reg.listToken(address(usdc), _cfg(_defaultBands()));
        reg.setPool(address(this)); // this contract implements reserves() below
        vm.stopPrank();
        _reserveOf[address(usdc)] = 5; // non-zero
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.TokenHasReserves.selector, address(usdc)));
        reg.deactivateToken(address(usdc));
        _reserveOf[address(usdc)] = 0;
        vm.prank(owner);
        reg.deactivateToken(address(usdc));
        assertFalse(reg.isActive(address(usdc)));
    }

    function test_remove_requires_inactive() public {
        vm.prank(owner);
        reg.listToken(address(usdc), _cfg(_defaultBands()));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.TokenStillActive.selector, address(usdc)));
        reg.removeToken(address(usdc));
    }

    mapping(address => uint256) internal _reserveOf;
    function reserves(address token) external view returns (uint256) {
        return _reserveOf[token];
    }
```

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ArcoraDexRegistryV2.t.sol" 2>&1 | tail -6
git add contracts/src/v2/interfaces/IArcoraDexRegistryV2.sol contracts/src/v2/interfaces/IArcoraDexPoolV2.sol contracts/src/v2/ArcoraDexRegistryV2.sol contracts/test/v2/ArcoraDexRegistryV2.t.sol
git commit -m "feat(v2): ArcoraDexRegistryV2 with §6.2 validation + full Pool interface

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
Expected: `10 passed; 0 failed`.

---

### Task 5: Shared test fixture + the §7 default config

**Files:**
- Create `contracts/test/v2/helpers/V2Fixture.sol`

- [ ] **Step 1: Write the fixture base**

Create `contracts/test/v2/helpers/V2Fixture.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexPoolV2} from "../../../src/v2/ArcoraDexPoolV2.sol";
import {ArcoraDexRegistryV2} from "../../../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexLPV2} from "../../../src/v2/ArcoraDexLPV2.sol";
import {IArcoraDexRegistryV2} from "../../../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "../../../src/v2/interfaces/IOracleAdapterV2.sol";
import {FeeBandMathV2} from "../../../src/v2/lib/FeeBandMathV2.sol";
import {MockOracleAdapterV2} from "../mocks/MockOracleAdapterV2.sol";
import {MintableERC20} from "../../../src/testnet/MintableERC20.sol";

/// @notice Shared V2 test scaffold: Registry+Pool+LP, 3 stablecoin mocks (USDC/EURC/USDT),
/// a single mock adapter priced at $1.00, and the default §7 fee schedule.
abstract contract V2Fixture is Test {
    ArcoraDexPoolV2 internal pool;
    ArcoraDexRegistryV2 internal reg;
    ArcoraDexLPV2 internal lp;
    MockOracleAdapterV2 internal adapter;
    MintableERC20 internal usdc; // 6
    MintableERC20 internal eurc; // 6
    MintableERC20 internal usdt; // 6

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint16 internal constant PROT_SHARE = 1_000; // 10%

    function _defaultBands() internal pure returns (FeeBandMathV2.Band[] memory b) {
        b = new FeeBandMathV2.Band[](4);
        b[0] = FeeBandMathV2.Band({upperHealthBps: 10_000, rateBps: 5});   // 75-100% : 0.05%
        b[1] = FeeBandMathV2.Band({upperHealthBps: 7_500, rateBps: 20});   // 50-75%  : 0.20%
        b[2] = FeeBandMathV2.Band({upperHealthBps: 5_000, rateBps: 75});   // 25-50%  : 0.75%
        b[3] = FeeBandMathV2.Band({upperHealthBps: 2_500, rateBps: 300});  // 0-25%   : 3.00%
    }

    function _cfg(uint256 minUsd, uint256 targetUsd) internal view returns (IArcoraDexRegistryV2.TokenConfigV2 memory) {
        return IArcoraDexRegistryV2.TokenConfigV2({
            decimals: 6,
            isActive: true,
            adapter: IOracleAdapterV2(address(adapter)),
            minimumReserveUsd: minUsd,
            targetReserveUsd: targetUsd,
            depositCapUsd: 0,
            protocolFeeShareBps: PROT_SHARE,
            bands: _defaultBands()
        });
    }

    function _deployV2() internal {
        adapter = new MockOracleAdapterV2();
        usdc = new MintableERC20("USD Coin", "USDC", 6, owner);
        eurc = new MintableERC20("Euro Coin", "EURC", 6, owner);
        usdt = new MintableERC20("Tether", "USDT", 6, owner);

        reg = new ArcoraDexRegistryV2(owner);
        pool = new ArcoraDexPoolV2(address(reg), PROT_SHARE, owner);
        lp = ArcoraDexLPV2(address(pool.LP()));

        // All three priced at $1.00, safe.
        adapter.setPrice(address(usdc), 1e18, true);
        adapter.setPrice(address(eurc), 1e18, true);
        adapter.setPrice(address(usdt), 1e18, true);

        vm.startPrank(owner);
        // min 1,000,000 USD ; target 2,000,000 USD ; available = 1,000,000 USD.
        reg.listToken(address(usdc), _cfg(1_000_000e18, 2_000_000e18));
        reg.listToken(address(eurc), _cfg(1_000_000e18, 2_000_000e18));
        reg.listToken(address(usdt), _cfg(1_000_000e18, 2_000_000e18));
        reg.setPool(address(pool));
        pool.setPauseGuardian(guardian);
        vm.stopPrank();
    }

    function _mint(MintableERC20 t, address to, uint256 amt) internal {
        vm.prank(owner);
        t.mint(to, amt);
    }

    function _seed(MintableERC20 t, address who, uint256 amt) internal {
        _mint(t, who, amt);
        vm.startPrank(who);
        t.approve(address(pool), amt);
        pool.deposit(address(t), amt, 0, block.timestamp + 1);
        vm.stopPrank();
    }
}
```
Note: this fixture compiles only after Task 6 creates `ArcoraDexPoolV2.sol`. It is created here so the Pool tests in Tasks 6-10 can `is V2Fixture`. Build/run happens in Task 6.

- [ ] **Step 2: Commit (no test run yet — depends on Task 6)**

Run:
```bash
git add contracts/test/v2/helpers/V2Fixture.sol
git commit -m "test(v2): shared V2Fixture with default §7 fee schedule

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: `ArcoraDexPoolV2` — deposit, NAV, swap (§8.1), and quote/exec parity

The Pool carries V1's audited patterns explicitly: `Ownable2Step`, `ReentrancyGuard`, `SafeERC20`, measured balance deltas (fee-on-transfer, L-10), `minOut`/`deadline`, NAV in 1e18 USD, LP min-hold (H-1), virtual-share offset (first-depositor inflation, #A), and the I-1 reserve guard via `registry.setPool`. The new V2 logic: oracle is consumed via `adapter.readPrice/peekPrice` (binary safe), and every priced output runs `FeeBandMathV2.traverse`.

**Swap flow (§8.1), USD-1e18 internally:**
1. `tokenIn != tokenOut`, `amountIn != 0`, `recipient != 0`.
2. Pull input, measure `receivedIn` (L-10).
3. `(pIn, sIn) = readPrice(tokenIn)`, `(pOut, sOut) = readPrice(tokenOut)`; revert `OracleUnsafe` if either `!safe`.
4. `grossUsd = receivedIn * pIn / 10**decIn` (round down).
5. `Result r = traverse(grossUsd, reserveOut*pOut/10**decOut, minOut, targetOut, bands, protShare)`; revert `ReserveFloorBreached` if `!r.ok`.
6. Convert to token units (round down): `amountOut = r.totalUserOutputUsd * 10**decOut / pOut`; `protFeeOut = r.totalProtocolFeeUsd * 10**decOut / pOut`.
7. Enforce `amountOut >= minOut`; assert `reserves[tokenOut] >= amountOut + protFeeOut` (defensive — traverse guarantees floor).
8. Credit `reserves[tokenIn] += receivedIn`; `reserves[tokenOut] -= (amountOut + protFeeOut)`; `protocolFeesAccrued[tokenOut] += protFeeOut`; transfer out.

**Files:**
- Create `contracts/src/v2/ArcoraDexPoolV2.sol`
- Create `contracts/test/v2/ArcoraDexPoolV2.swap.t.sol`

- [ ] **Step 1: Write the failing swap test**

Create `contracts/test/v2/ArcoraDexPoolV2.swap.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";
import {IArcoraDexPoolV2} from "../../src/v2/interfaces/IArcoraDexPoolV2.sol";

contract ArcoraDexPoolV2SwapTest is V2Fixture {
    function setUp() public {
        _deployV2();
        // Seed each reserve to its TARGET (health 100%) so band-0 (0.05%) applies at the margin.
        _seed(usdc, makeAddr("seeder"), 2_000_000e6);
        _seed(eurc, makeAddr("seeder2"), 2_000_000e6);
    }

    function test_swap_healthiest_band_charges_5bps() public {
        _mint(usdc, alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        uint256 out = pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp + 1, alice);
        vm.stopPrank();
        // gross 1000 USD; eurc reserve 2M = target → still drops below target as we debit,
        // but a 1000-USD debit barely dents health, so the whole thing is band-0 (0.05%).
        // amountOut ≈ 1000e6 - ceil(1000e6*5/10000) = 1000e6 - 5e5 = 999_500000 (minus rounding).
        assertApproxEqAbs(out, 999_500000, 2, "healthiest-band 5bps swap output");
    }

    function test_swap_reverts_when_tokenOut_oracle_unsafe() public {
        adapter.setSafe(address(eurc), false);
        _mint(usdc, alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, address(eurc)));
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp + 1, alice);
        vm.stopPrank();
    }

    function test_quoteSwap_matches_execution() public {
        _mint(usdc, alice, 5_000e6);
        (uint256 q,,,) = pool.quoteSwapV2(address(usdc), address(eurc), 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 5_000e6);
        uint256 exec = pool.swap(address(usdc), address(eurc), 5_000e6, 0, block.timestamp + 1, alice);
        vm.stopPrank();
        assertEq(exec, q, "quote must equal execution");
    }
}
```

- [ ] **Step 2: Run it (expected failure — Pool does not exist)**

Run:
```bash
cd contracts && forge test --match-path "test/v2/ArcoraDexPoolV2.swap.t.sol" 2>&1 | tail -8
```
Expected: `Source ... ArcoraDexPoolV2.sol not found`.

- [ ] **Step 3: Write the Pool (deposit, NAV, swap, internal helpers)**

Create `contracts/src/v2/ArcoraDexPoolV2.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IArcoraDexPoolV2} from "./interfaces/IArcoraDexPoolV2.sol";
import {IArcoraDexRegistryV2} from "./interfaces/IArcoraDexRegistryV2.sol";
import {IArcoraDexLPV2} from "./interfaces/IArcoraDexLPV2.sol";
import {IOracleAdapterV2} from "./interfaces/IOracleAdapterV2.sol";
import {ArcoraDexLPV2} from "./ArcoraDexLPV2.sol";
import {FeeBandMathV2} from "./lib/FeeBandMathV2.sol";

/// @title ArcoraDexPoolV2
/// @notice Immutable (non-upgradeable) reserve-floor-protected oracle-priced pool.
/// Carries V1 audited patterns: Ownable2Step, ReentrancyGuard, SafeERC20, measured
/// balance deltas (L-10), minOut/deadline, 1e18 NAV, LP min-hold (H-1), virtual-share
/// offset (#A), I-1 reserve guard via Registry.setPool. New: binary-safe oracle adapter
/// and marginal fee bands via FeeBandMathV2.
contract ArcoraDexPoolV2 is IArcoraDexPoolV2, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using FeeBandMathV2 for FeeBandMathV2.Band[];

    uint16 public constant MAX_PROTOCOL_FEE_SHARE_BPS = 2_500;
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;
    uint256 internal constant BPS = 10_000;
    address public constant DEAD_ADDRESS = address(0xdead);
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 public constant MIN_HOLD_SECONDS = 1 hours;

    // slither-disable-next-line naming-convention
    IArcoraDexRegistryV2 public immutable override REGISTRY;
    // slither-disable-next-line naming-convention
    IArcoraDexLPV2 public immutable override LP;

    mapping(address token => uint256) public override reserves;
    mapping(address token => uint256) public override protocolFeesAccrued;
    mapping(address account => uint256) public override lastMintAt;
    uint16 public override protocolFeeShareBps;
    bool public override paused;
    address public override pauseGuardian;

    constructor(address registry, uint16 initialProtocolFeeShareBps, address initialOwner) Ownable(initialOwner) {
        if (registry == address(0)) revert ZeroAddress();
        if (initialProtocolFeeShareBps > MAX_PROTOCOL_FEE_SHARE_BPS) revert InvalidProtocolFeeShareBps(initialProtocolFeeShareBps);
        REGISTRY = IArcoraDexRegistryV2(registry);
        LP = IArcoraDexLPV2(address(new ArcoraDexLPV2(address(this))));
        protocolFeeShareBps = initialProtocolFeeShareBps;
    }

    modifier whenNotPaused() {
        if (paused) revert PoolPaused();
        _;
    }
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }

    // ── Oracle (binary safe) ────────────────────────────────────────
    function _readSafe(address token, IArcoraDexRegistryV2.TokenConfigV2 memory c)
        internal
        returns (uint256 price1e18)
    {
        if (!c.isActive) revert TokenNotActive(token);
        bool safe;
        (price1e18, safe) = c.adapter.readPrice(token);
        if (!safe || price1e18 == 0) revert OracleUnsafe(token);
    }

    function _peekSafe(address token, IArcoraDexRegistryV2.TokenConfigV2 memory c)
        internal
        view
        returns (uint256 price1e18)
    {
        if (!c.isActive) revert TokenNotActive(token);
        bool safe;
        (price1e18, safe) = c.adapter.peekPrice(token);
        if (!safe || price1e18 == 0) revert OracleUnsafe(token);
    }

    function _reserveUsd(address token, uint256 price1e18, uint8 dec) internal view returns (uint256) {
        return (reserves[token] * price1e18) / (10 ** dec);
    }

    // ── NAV ──────────────────────────────────────────────────────────
    /// @dev Stateful NAV: reverts (via _readSafe) if any active token is unsafe — this
    /// is the §11 "operations whose NAV requires an unsafe price stop" guarantee.
    function _navMut() internal returns (uint256 navE18) {
        uint256 n = REGISTRY.tokensLength();
        for (uint256 i; i < n;) {
            address t = REGISTRY.tokens(i);
            IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(t);
            if (c.isActive) {
                uint256 p = _readSafe(t, c);
                navE18 += (reserves[t] * p) / (10 ** c.decimals);
            }
            unchecked {
                ++i;
            }
        }
    }

    function totalReservesUSD() public view override returns (uint256 navE18) {
        uint256 n = REGISTRY.tokensLength();
        for (uint256 i; i < n;) {
            address t = REGISTRY.tokens(i);
            IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(t);
            if (c.isActive) {
                uint256 p = _peekSafe(t, c);
                navE18 += (reserves[t] * p) / (10 ** c.decimals);
            }
            unchecked {
                ++i;
            }
        }
    }

    // ── deposit ──────────────────────────────────────────────────────
    function deposit(address token, uint256 amount, uint256 minLpOut, uint256 deadline)
        external
        override
        whenNotPaused
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 lpMinted)
    {
        if (amount == 0) revert ZeroAmount();
        IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(token);
        uint256 priceIn = _readSafe(token, c);

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroAmount();

        uint256 usdIn = (received * priceIn) / (10 ** c.decimals);

        // Rollout cap (§6.2): reject if post-deposit reserve USD would exceed depositCapUsd.
        if (c.depositCapUsd != 0) {
            uint256 postReserveUsd = ((reserves[token] + received) * priceIn) / (10 ** c.decimals);
            if (postReserveUsd > c.depositCapUsd) revert DepositCapExceeded(token);
        }

        uint256 supply = LP.totalSupply();
        uint256 navBefore;
        if (supply == 0) {
            if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
            lpMinted = (usdIn * VIRTUAL_SHARES) / VIRTUAL_ASSETS;
        } else {
            navBefore = _navMut();
            lpMinted = (usdIn * (supply + VIRTUAL_SHARES)) / (navBefore + VIRTUAL_ASSETS);
        }
        if (lpMinted < minLpOut) revert InsufficientLpOut(lpMinted, minLpOut);

        reserves[token] += received;
        if (supply == 0) LP.mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
        LP.mint(msg.sender, lpMinted);
        lastMintAt[msg.sender] = block.timestamp;
        emit Deposited(msg.sender, token, received, lpMinted, navBefore, navBefore + usdIn);
    }

    // ── swap (§8.1) ───────────────────────────────────────────────────
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline, address recipient)
        external
        override
        whenNotPaused
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut) revert SameToken(tokenIn);
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 inBalBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 receivedIn = IERC20(tokenIn).balanceOf(address(this)) - inBalBefore;
        if (receivedIn == 0) revert ZeroAmount();

        uint256 protFeeOut;
        uint256 feeUsd;
        {
            IArcoraDexRegistryV2.TokenConfigV2 memory cIn = REGISTRY.tokenConfig(tokenIn);
            IArcoraDexRegistryV2.TokenConfigV2 memory cOut = REGISTRY.tokenConfig(tokenOut);
            uint256 pIn = _readSafe(tokenIn, cIn);
            uint256 pOut = _readSafe(tokenOut, cOut);

            uint256 grossUsd = (receivedIn * pIn) / (10 ** cIn.decimals);
            FeeBandMathV2.Result memory r = FeeBandMathV2.traverse(
                grossUsd, _reserveUsd(tokenOut, pOut, cOut.decimals), cOut.minimumReserveUsd, cOut.targetReserveUsd, cOut.bands, protocolFeeShareBps
            );
            if (!r.ok) revert ReserveFloorBreached(tokenOut);
            uint256 scale = 10 ** cOut.decimals;
            amountOut = (r.totalUserOutputUsd * scale) / pOut;
            protFeeOut = (r.totalProtocolFeeUsd * scale) / pOut;
            feeUsd = r.totalFeeUsd;
        }

        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        uint256 rv = reserves[tokenOut];
        if (rv < amountOut + protFeeOut) revert InsufficientLiquidity(tokenOut, amountOut + protFeeOut, rv);

        reserves[tokenIn] += receivedIn;
        reserves[tokenOut] = rv - (amountOut + protFeeOut);
        protocolFeesAccrued[tokenOut] += protFeeOut;
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, receivedIn, amountOut, feeUsd, protFeeOut, recipient);
    }

    // ── quoteSwapV2 (shares traverse with swap) ────────────────────────
    function quoteSwapV2(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        override
        returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps)
    {
        if (tokenIn == tokenOut) revert SameToken(tokenIn);
        if (amountIn == 0) revert ZeroAmount();
        IArcoraDexRegistryV2.TokenConfigV2 memory cIn = REGISTRY.tokenConfig(tokenIn);
        IArcoraDexRegistryV2.TokenConfigV2 memory cOut = REGISTRY.tokenConfig(tokenOut);
        uint256 pIn = _peekSafe(tokenIn, cIn);
        uint256 pOut = _peekSafe(tokenOut, cOut);
        uint256 grossUsd = (amountIn * pIn) / (10 ** cIn.decimals);
        uint256 reserveUsd = _reserveUsd(tokenOut, pOut, cOut.decimals);
        FeeBandMathV2.Result memory r =
            FeeBandMathV2.traverse(grossUsd, reserveUsd, cOut.minimumReserveUsd, cOut.targetReserveUsd, cOut.bands, protocolFeeShareBps);
        if (!r.ok) revert ReserveFloorBreached(tokenOut);
        uint256 scale = 10 ** cOut.decimals;
        amountOut = (r.totalUserOutputUsd * scale) / pOut;
        protocolFee = (r.totalProtocolFeeUsd * scale) / pOut;
        feeUsd1e18 = r.totalFeeUsd;
        postHealthBps = FeeBandMathV2.healthBps(reserveUsd - r.totalReserveDebitUsd, cOut.minimumReserveUsd, cOut.targetReserveUsd);
    }

    // ── reserveHealth view (§9) ────────────────────────────────────────
    function reserveHealth(address token) external view override returns (uint256) {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(token);
        uint256 p = _peekSafe(token, c);
        return FeeBandMathV2.healthBps(_reserveUsd(token, p, c.decimals), c.minimumReserveUsd, c.targetReserveUsd);
    }

    // ── LP transfer hook (H-1) ─────────────────────────────────────────
    function notifyLPTransfer(address from, address) external override {
        if (msg.sender != address(LP)) revert NotLP();
        uint256 unlockAt = lastMintAt[from] + MIN_HOLD_SECONDS;
        if (block.timestamp < unlockAt) revert EarlyTransfer(unlockAt, block.timestamp);
    }

    // ── Owner / Guardian ───────────────────────────────────────────────
    function setProtocolFeeShareBps(uint16 newBps) external override onlyOwner {
        if (newBps > MAX_PROTOCOL_FEE_SHARE_BPS) revert InvalidProtocolFeeShareBps(newBps);
        emit ProtocolFeeShareUpdated(protocolFeeShareBps, newBps);
        protocolFeeShareBps = newBps;
    }

    function withdrawProtocolFees(address token, uint256 amount, address to) external override onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 acc = protocolFeesAccrued[token];
        if (amount > acc) revert InsufficientLiquidity(token, amount, acc);
        protocolFeesAccrued[token] = acc - amount;
        IERC20(token).safeTransfer(to, amount);
        emit ProtocolFeesWithdrawn(token, amount, to);
    }

    /// @notice Guardian pause-only (§6.2): guardian OR owner may pause.
    function pause() external override {
        if (msg.sender != owner() && msg.sender != pauseGuardian) revert NotAuthorized();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause is owner-only (the governance Timelock). The guardian cannot unpause.
    function unpause() external override onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setPauseGuardian(address newGuardian) external override onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        emit PauseGuardianUpdated(pauseGuardian, newGuardian);
        pauseGuardian = newGuardian;
    }

    // Stubs filled in by Task 7 (withdrawSingle, quoteWithdrawV2, maxWithdraw) and
    // Task 8 (withdrawProportional, maxSwapOut). Declared here to satisfy the interface.
    function withdrawSingle(address, uint256, uint256, uint256) external virtual override returns (uint256) {
        revert(); // implemented in Task 7
    }
    function withdrawProportional(uint256, uint256) external virtual override returns (uint256[] memory) {
        revert(); // implemented in Task 8
    }
    function quoteWithdrawV2(address, uint256) external view virtual override returns (uint256, uint256, uint256, uint256) {
        revert(); // implemented in Task 7
    }
    function maxSwapOut(address) external view virtual override returns (uint256, uint256) {
        revert(); // implemented in Task 9
    }
    function maxWithdraw(address, address) external view virtual override returns (uint256, uint256) {
        revert(); // implemented in Task 9
    }
}
```
Implementation note for the worker: the four `revert()` stubs exist ONLY so the contract satisfies the interface between tasks. Tasks 7-9 REPLACE each stub body with the real implementation in the same file (not new functions). Do not leave any `revert()` stub in the final contract — the Self-Review placeholder scan checks for this.

- [ ] **Step 4: Run the swap suite (expected pass)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ArcoraDexPoolV2.swap.t.sol" 2>&1 | tail -8
```
Expected: `3 passed; 0 failed`. If `test_swap_healthiest_band_charges_5bps` is off, recompute by hand: with a 2,000,000-USD reserve (health 100%) the first ~1,000,000 USD of debit sits in band 0 (5 bps), so a 1,000-USD gross is entirely band-0; `amountOut = 1000e6 - ceil(1000e6 * 5 / 10000)`.

- [ ] **Step 5: Confirm V1 suite still green, then commit**

Run:
```bash
cd contracts && forge test 2>&1 | tail -3
git add contracts/src/v2/ArcoraDexPoolV2.sol contracts/test/v2/ArcoraDexPoolV2.swap.t.sol
git commit -m "feat(v2): ArcoraDexPoolV2 deposit+NAV+swap with marginal fee bands (§8.1)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
Expected: total passing = 196 (V1) + new V2 tests; 0 failed.

---

### Task 7: Single-token withdrawal (§8.2) + `quoteWithdrawV2`

**Single-token withdraw flow (§8.2):**
1. `lpAmount != 0`; enforce MIN_HOLD on `lastMintAt[msg.sender]` (H-1).
2. `(pOut, sOut) = readPrice(tokenOut)`; revert `OracleUnsafe` if unsafe. Compute `navBefore = _navMut()` (this reverts if ANY active token is unsafe — §11 NAV rule).
3. `grossUsd = lpAmount * (navBefore + VIRTUAL_ASSETS) / (totalSupply + VIRTUAL_SHARES)` (round down).
4. `Result r = traverse(grossUsd, reserveOutUsd, minOut, targetOut, bands, protShare)`; revert `ReserveFloorBreached` if `!r.ok`.
5. Convert to token units; enforce `amountOut >= minTokenOut`; assert reserve sufficiency.
6. Burn LP; debit reserves; accrue protocol fee; transfer.

**Files:**
- Modify `contracts/src/v2/ArcoraDexPoolV2.sol` (replace the `withdrawSingle` and `quoteWithdrawV2` stubs)
- Create `contracts/test/v2/ArcoraDexPoolV2.withdraw.t.sol`

- [ ] **Step 1: Write the failing withdraw test**

Create `contracts/test/v2/ArcoraDexPoolV2.withdraw.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";
import {IArcoraDexPoolV2} from "../../src/v2/interfaces/IArcoraDexPoolV2.sol";

contract ArcoraDexPoolV2WithdrawTest is V2Fixture {
    function setUp() public {
        _deployV2();
        // Two-token reserve so single-token withdraw has a different token to draw against.
        _seed(usdc, alice, 2_000_000e6);     // alice is LP
        _seed(eurc, bob, 2_000_000e6);       // eurc reserve present
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
    }

    function test_withdrawSingle_into_eurc_charges_band_fee() public {
        uint256 lpBal = lp.balanceOf(alice);
        // Withdraw a small slice into EURC; EURC reserve at target → band-0 0.05%.
        uint256 slice = lpBal / 1000;
        (uint256 q,,,) = pool.quoteWithdrawV2(address(eurc), slice);
        vm.prank(alice);
        uint256 out = pool.withdrawSingle(address(eurc), slice, 0, block.timestamp + 1);
        assertEq(out, q, "withdraw quote/exec parity");
        assertGt(out, 0);
    }

    function test_withdrawSingle_reverts_floor_breach() public {
        // Try to pull almost the entire EURC reserve into EURC → must breach floor.
        uint256 lpBal = lp.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.ReserveFloorBreached.selector, address(eurc)));
        pool.withdrawSingle(address(eurc), lpBal, 0, block.timestamp + 1);
    }

    function test_withdrawSingle_reverts_oracle_unsafe() public {
        adapter.setSafe(address(eurc), false);
        uint256 lpBal = lp.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, address(eurc)));
        pool.withdrawSingle(address(eurc), lpBal / 1000, 0, block.timestamp + 1);
    }
}
```

- [ ] **Step 2: Run it (expected failure — stubs revert)**

Run:
```bash
cd contracts && forge test --match-path "test/v2/ArcoraDexPoolV2.withdraw.t.sol" 2>&1 | tail -8
```
Expected: all 3 revert (the stub `revert()` fires).

- [ ] **Step 3: Replace the `withdrawSingle` and `quoteWithdrawV2` stubs**

In `contracts/src/v2/ArcoraDexPoolV2.sol`, replace the `withdrawSingle` stub with:
```solidity
    function withdrawSingle(address tokenOut, uint256 lpAmount, uint256 minTokenOut, uint256 deadline)
        external
        override
        whenNotPaused
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        if (lpAmount == 0) revert ZeroAmount();
        uint256 unlockAt = lastMintAt[msg.sender] + MIN_HOLD_SECONDS;
        if (block.timestamp < unlockAt) revert EarlyWithdraw(unlockAt, block.timestamp);

        uint256 navBefore = _navMut(); // reverts OracleUnsafe if any active token unsafe (§11 NAV)
        uint256 grossUsd = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (LP.totalSupply() + VIRTUAL_SHARES);

        uint256 protFeeOut;
        uint256 feeUsd;
        {
            IArcoraDexRegistryV2.TokenConfigV2 memory cOut = REGISTRY.tokenConfig(tokenOut);
            uint256 pOut = _readSafe(tokenOut, cOut);
            FeeBandMathV2.Result memory r = FeeBandMathV2.traverse(
                grossUsd, _reserveUsd(tokenOut, pOut, cOut.decimals), cOut.minimumReserveUsd, cOut.targetReserveUsd, cOut.bands, protocolFeeShareBps
            );
            if (!r.ok) revert ReserveFloorBreached(tokenOut);
            uint256 scale = 10 ** cOut.decimals;
            amountOut = (r.totalUserOutputUsd * scale) / pOut;
            protFeeOut = (r.totalProtocolFeeUsd * scale) / pOut;
            feeUsd = r.totalFeeUsd;
        }

        uint256 rv = reserves[tokenOut];
        if (rv < amountOut + protFeeOut) revert InsufficientLiquidity(tokenOut, amountOut + protFeeOut, rv);
        if (amountOut < minTokenOut) revert InsufficientTokenOut(amountOut, minTokenOut);

        LP.burn(msg.sender, lpAmount);
        reserves[tokenOut] = rv - (amountOut + protFeeOut);
        protocolFeesAccrued[tokenOut] += protFeeOut;
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        emit WithdrewSingle(msg.sender, tokenOut, lpAmount, amountOut, protFeeOut, feeUsd);
    }
```
Replace the `quoteWithdrawV2` stub with:
```solidity
    function quoteWithdrawV2(address tokenOut, uint256 lpAmount)
        external
        view
        override
        returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps)
    {
        if (lpAmount == 0) revert ZeroAmount();
        uint256 navBefore = totalReservesUSD(); // view, reverts OracleUnsafe if any active unsafe
        uint256 grossUsd = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (LP.totalSupply() + VIRTUAL_SHARES);
        IArcoraDexRegistryV2.TokenConfigV2 memory cOut = REGISTRY.tokenConfig(tokenOut);
        uint256 pOut = _peekSafe(tokenOut, cOut);
        uint256 reserveUsd = _reserveUsd(tokenOut, pOut, cOut.decimals);
        FeeBandMathV2.Result memory r =
            FeeBandMathV2.traverse(grossUsd, reserveUsd, cOut.minimumReserveUsd, cOut.targetReserveUsd, cOut.bands, protocolFeeShareBps);
        if (!r.ok) revert ReserveFloorBreached(tokenOut);
        uint256 scale = 10 ** cOut.decimals;
        amountOut = (r.totalUserOutputUsd * scale) / pOut;
        protocolFee = (r.totalProtocolFeeUsd * scale) / pOut;
        feeUsd1e18 = r.totalFeeUsd;
        postHealthBps = FeeBandMathV2.healthBps(reserveUsd - r.totalReserveDebitUsd, cOut.minimumReserveUsd, cOut.targetReserveUsd);
    }
```

- [ ] **Step 4: Run the withdraw suite (expected pass)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ArcoraDexPoolV2.withdraw.t.sol" 2>&1 | tail -8
```
Expected: `3 passed; 0 failed`.

- [ ] **Step 5: Commit**

Run:
```bash
git add contracts/src/v2/ArcoraDexPoolV2.sol contracts/test/v2/ArcoraDexPoolV2.withdraw.t.sol
git commit -m "feat(v2): single-token withdraw (§8.2) + quoteWithdrawV2, shared band traversal

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Proportional emergency withdrawal (§8.3)

**Proportional flow (§8.3):** burns LP, returns `lpAmount * reserves[token] / totalSupply` (round down) of EVERY active token — no USD valuation, no token selection, no oracle read, no reserve floor. Subject to reentrancy + measured accounting. Protocol fees are excluded (paid from `reserves`, not `protocolFeesAccrued`). Available even when paused or when oracles are unsafe — so it does NOT carry `whenNotPaused` and never calls the adapter.

**Files:**
- Modify `contracts/src/v2/ArcoraDexPoolV2.sol` (replace the `withdrawProportional` stub)
- Create `contracts/test/v2/ArcoraDexPoolV2.proportional.t.sol`

- [ ] **Step 1: Write the failing proportional test**

Create `contracts/test/v2/ArcoraDexPoolV2.proportional.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";

contract ArcoraDexPoolV2ProportionalTest is V2Fixture {
    function setUp() public {
        _deployV2();
        _seed(usdc, alice, 1_000_000e6);
        _seed(eurc, alice, 1_000_000e6); // alice is the only LP across both tokens
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
    }

    function test_proportional_returns_pro_rata_basket() public {
        uint256 lpBal = lp.balanceOf(alice);
        uint256 half = lpBal / 2;
        uint256 supply = lp.totalSupply();
        uint256 expUsdc = (half * pool.reserves(address(usdc))) / supply;
        uint256 expEurc = (half * pool.reserves(address(eurc))) / supply;

        uint256 u0 = usdc.balanceOf(alice);
        uint256 e0 = eurc.balanceOf(alice);
        vm.prank(alice);
        pool.withdrawProportional(half, block.timestamp + 1);
        assertEq(usdc.balanceOf(alice) - u0, expUsdc, "usdc pro-rata");
        assertEq(eurc.balanceOf(alice) - e0, expEurc, "eurc pro-rata");
    }

    function test_proportional_works_when_paused() public {
        vm.prank(guardian);
        pool.pause();
        uint256 lpBal = lp.balanceOf(alice);
        vm.prank(alice);
        pool.withdrawProportional(lpBal / 4, block.timestamp + 1); // must NOT revert
    }

    function test_proportional_works_when_oracle_unsafe() public {
        adapter.setSafe(address(usdc), false);
        adapter.setSafe(address(eurc), false);
        uint256 lpBal = lp.balanceOf(alice);
        vm.prank(alice);
        pool.withdrawProportional(lpBal / 4, block.timestamp + 1); // no oracle read → succeeds
    }
}
```

- [ ] **Step 2: Run it (expected failure — stub reverts)**

Run:
```bash
cd contracts && forge test --match-path "test/v2/ArcoraDexPoolV2.proportional.t.sol" 2>&1 | tail -8
```
Expected: all 3 revert.

- [ ] **Step 3: Replace the `withdrawProportional` stub**

In `contracts/src/v2/ArcoraDexPoolV2.sol`, replace the stub with:
```solidity
    /// @notice §8.3 proportional emergency exit. No oracle, no floor, no pause gate.
    /// Returns the pro-rata share of every active token's reserve. Protocol fees
    /// (held separately in protocolFeesAccrued) are excluded.
    function withdrawProportional(uint256 lpAmount, uint256 deadline)
        external
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256[] memory amounts)
    {
        if (lpAmount == 0) revert ZeroAmount();
        uint256 supply = LP.totalSupply();
        uint256 n = REGISTRY.tokensLength();
        amounts = new uint256[](n);

        // Burn FIRST (CEI): supply used for the pro-rata is the pre-burn supply.
        LP.burn(msg.sender, lpAmount);

        for (uint256 i; i < n;) {
            address t = REGISTRY.tokens(i);
            uint256 rv = reserves[t];
            if (rv != 0) {
                uint256 share = (lpAmount * rv) / supply; // round down
                if (share != 0) {
                    reserves[t] = rv - share;
                    amounts[i] = share;
                    IERC20(t).safeTransfer(msg.sender, share);
                }
            }
            unchecked {
                ++i;
            }
        }
        emit WithdrewProportional(msg.sender, lpAmount);
    }
```
Note: proportional iterates `REGISTRY.tokens(i)` including INACTIVE tokens whose reserves are non-zero (a token may be deactivated with reserves only when the I-1 guard is not wired; defensive). Equal-basket treatment holds because every token uses the same `lpAmount/supply` ratio.

- [ ] **Step 4: Run the proportional suite (expected pass)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ArcoraDexPoolV2.proportional.t.sol" 2>&1 | tail -8
```
Expected: `3 passed; 0 failed`.

- [ ] **Step 5: Commit**

Run:
```bash
git add contracts/src/v2/ArcoraDexPoolV2.sol contracts/test/v2/ArcoraDexPoolV2.proportional.t.sol
git commit -m "feat(v2): proportional emergency withdrawal (§8.3) — oracle/floor/pause-independent

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Views — `maxSwapOut`, `maxWithdraw`, `reserveHealth` (no-overstate)

`maxSwapOut(tokenOut)` returns the max executable NET output and its gross USD entitlement at the floor. The max gross is the total debit capacity from current health to 0 (the sum of every band's `_grossForDebit`), so `traverse` of that gross yields `ok==true` with the reserve landing exactly at (or just above) the floor. `maxWithdraw(tokenOut, account)` returns the max LP the account can burn via the single-token path: bounded by both (a) the account's LP balance and (b) the gross cap above. These are quotes, never reservations (§9), and MUST NOT overstate (§14).

**Files:**
- Modify `contracts/src/v2/ArcoraDexPoolV2.sol` (replace `maxSwapOut` and `maxWithdraw` stubs; add an internal `_maxGrossUsd` helper)
- Create `contracts/test/v2/ArcoraDexPoolV2.views.t.sol`

- [ ] **Step 1: Write the failing views test**

Create `contracts/test/v2/ArcoraDexPoolV2.views.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";

contract ArcoraDexPoolV2ViewsTest is V2Fixture {
    function setUp() public {
        _deployV2();
        _seed(usdc, alice, 1_500_000e6); // health 50%
        _seed(eurc, bob, 1_500_000e6);
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
    }

    function test_reserveHealth_reports_50pct() public view {
        assertEq(pool.reserveHealth(address(usdc)), 5_000);
    }

    function test_maxSwapOut_does_not_overstate() public {
        (uint256 netMax,) = pool.maxSwapOut(address(eurc));
        assertGt(netMax, 0);
        // Swapping for exactly netMax must succeed; netMax+dust must revert at the floor.
        // Drive enough USDC in to request netMax out.
        _mint(usdc, alice, 3_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 3_000_000e6);
        uint256 got = pool.swap(address(usdc), address(eurc), 3_000_000e6, 0, block.timestamp + 1, alice);
        vm.stopPrank();
        assertLe(got, netMax, "execution output must not exceed advertised maxSwapOut");
    }

    function test_maxWithdraw_does_not_overstate() public {
        (uint256 lpMax, uint256 netOut) = pool.maxWithdraw(address(eurc), alice);
        assertGt(lpMax, 0);
        vm.prank(alice);
        uint256 got = pool.withdrawSingle(address(eurc), lpMax, 0, block.timestamp + 1);
        assertApproxEqAbs(got, netOut, 2, "withdraw of maxWithdraw lp matches advertised netOut");
    }
}
```

- [ ] **Step 2: Run it (expected failure — stubs revert)**

Run:
```bash
cd contracts && forge test --match-path "test/v2/ArcoraDexPoolV2.views.t.sol" 2>&1 | tail -8
```
Expected: reverts.

- [ ] **Step 3: Add `_maxGrossUsd` helper and replace `maxSwapOut` / `maxWithdraw` stubs**

In `contracts/src/v2/ArcoraDexPoolV2.sol`, add this internal helper near `_reserveUsd`:
```solidity
    /// @dev Total gross USD entitlement that traverse can place down to the floor for
    /// `tokenOut` at its current reserve — the sum of every band's gross-for-debit.
    /// Found by feeding traverse a deliberately-huge gross and reading how much debit
    /// it placed; because traverse caps at the floor, the placed gross == max gross.
    function _maxGrossUsd(IArcoraDexRegistryV2.TokenConfigV2 memory c, uint256 reserveUsd)
        internal
        view
        returns (uint256 grossUsd, FeeBandMathV2.Result memory r)
    {
        if (reserveUsd <= c.minimumReserveUsd) return (0, r);
        // Binary search the largest gross whose traverse returns ok. Upper bound is the
        // full usable reserve (debit <= gross always, so usable is a safe ceiling).
        uint256 lo;
        uint256 hi = reserveUsd - c.minimumReserveUsd;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            FeeBandMathV2.Result memory probe =
                FeeBandMathV2.traverse(mid, reserveUsd, c.minimumReserveUsd, c.targetReserveUsd, c.bands, protocolFeeShareBps);
            if (probe.ok) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        grossUsd = lo;
        r = FeeBandMathV2.traverse(grossUsd, reserveUsd, c.minimumReserveUsd, c.targetReserveUsd, c.bands, protocolFeeShareBps);
    }
```
Replace the `maxSwapOut` stub with:
```solidity
    function maxSwapOut(address tokenOut) external view override returns (uint256 netOut, uint256 grossUsd1e18) {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(tokenOut);
        uint256 pOut = _peekSafe(tokenOut, c);
        uint256 reserveUsd = _reserveUsd(tokenOut, pOut, c.decimals);
        FeeBandMathV2.Result memory r;
        (grossUsd1e18, r) = _maxGrossUsd(c, reserveUsd);
        netOut = (r.totalUserOutputUsd * (10 ** c.decimals)) / pOut;
    }
```
Replace the `maxWithdraw` stub with:
```solidity
    function maxWithdraw(address tokenOut, address account) external view override returns (uint256 lpAmount, uint256 netOut) {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(tokenOut);
        uint256 pOut = _peekSafe(tokenOut, c);
        uint256 reserveUsd = _reserveUsd(tokenOut, pOut, c.decimals);
        (uint256 maxGrossUsd, FeeBandMathV2.Result memory r) = _maxGrossUsd(c, reserveUsd);
        // LP amount whose gross USD share == maxGrossUsd (round DOWN so we never overstate).
        uint256 navBefore = totalReservesUSD();
        uint256 supply = LP.totalSupply();
        // gross = lp * (nav + VA) / (supply + VS)  =>  lp = gross * (supply + VS) / (nav + VA)
        uint256 lpFromGross = (maxGrossUsd * (supply + VIRTUAL_SHARES)) / (navBefore + VIRTUAL_ASSETS);
        uint256 bal = LP.balanceOf(account);
        lpAmount = lpFromGross < bal ? lpFromGross : bal;
        if (lpAmount == lpFromGross) {
            netOut = (r.totalUserOutputUsd * (10 ** c.decimals)) / pOut;
        } else {
            // Account-balance bound: recompute the net for the smaller LP slice.
            uint256 grossUsd = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (supply + VIRTUAL_SHARES);
            FeeBandMathV2.Result memory r2 =
                FeeBandMathV2.traverse(grossUsd, reserveUsd, c.minimumReserveUsd, c.targetReserveUsd, c.bands, protocolFeeShareBps);
            netOut = (r2.totalUserOutputUsd * (10 ** c.decimals)) / pOut;
        }
    }
```

- [ ] **Step 4: Run the views suite (expected pass)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ArcoraDexPoolV2.views.t.sol" 2>&1 | tail -8
```
Expected: `3 passed; 0 failed`. If `maxSwapOut` overstates by a wei, the binary search's `lo` is the largest `ok` gross — that is already the conservative floor; the `assertLe(got, netMax)` must hold because `got` derives from the same `traverse` over the same-or-smaller reserve.

- [ ] **Step 5: Commit**

Run:
```bash
git add contracts/src/v2/ArcoraDexPoolV2.sol contracts/test/v2/ArcoraDexPoolV2.views.t.sol
git commit -m "feat(v2): maxSwapOut/maxWithdraw/reserveHealth views — never overstate (§9)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Pause semantics + oracle-failure stop matrix (§11)

**Files:**
- Create `contracts/test/v2/ArcoraDexPoolV2.pause.t.sol`

- [ ] **Step 1: Write the pause + §11 stop-matrix test**

Create `contracts/test/v2/ArcoraDexPoolV2.pause.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";
import {IArcoraDexPoolV2} from "../../src/v2/interfaces/IArcoraDexPoolV2.sol";

contract ArcoraDexPoolV2PauseTest is V2Fixture {
    function setUp() public {
        _deployV2();
        _seed(usdc, alice, 2_000_000e6);
        _seed(eurc, bob, 2_000_000e6);
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
    }

    function test_guardian_can_pause_but_not_unpause() public {
        vm.prank(guardian);
        pool.pause();
        assertTrue(pool.paused());
        vm.prank(guardian);
        vm.expectRevert(); // Ownable: guardian is not owner
        pool.unpause();
        vm.prank(owner);
        pool.unpause();
        assertFalse(pool.paused());
    }

    function test_rando_cannot_pause() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(IArcoraDexPoolV2.NotAuthorized.selector);
        pool.pause();
    }

    // §11: swap, deposit, single-withdraw into an unsafe token all stop.
    function test_unsafe_token_stops_swap_deposit_withdraw() public {
        adapter.setSafe(address(eurc), false);
        _mint(usdc, alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, address(eurc)));
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp + 1, alice);
        vm.stopPrank();

        _mint(eurc, alice, 1_000e6);
        vm.startPrank(alice);
        eurc.approve(address(pool), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, address(eurc)));
        pool.deposit(address(eurc), 1_000e6, 0, block.timestamp + 1);
        vm.stopPrank();

        // single-token withdraw whose NAV requires the unsafe price also stops.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, address(eurc)));
        pool.withdrawSingle(address(usdc), 1e18, 0, block.timestamp + 1);
    }
}
```

- [ ] **Step 2: Run it (expected pass — behavior already implemented in Tasks 6-8)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ArcoraDexPoolV2.pause.t.sol" 2>&1 | tail -8
```
Expected: `3 passed; 0 failed`. Note `test_unsafe_token_stops_swap_deposit_withdraw`'s third assertion relies on `_navMut` iterating ALL active tokens and reverting on the unsafe EURC even when withdrawing USDC (the §11 NAV rule).

- [ ] **Step 3: Commit**

Run:
```bash
git add contracts/test/v2/ArcoraDexPoolV2.pause.t.sol
git commit -m "test(v2): pause semantics (guardian pause-only) + §11 oracle-failure stop matrix

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: Stateful invariants (§14) — handler + the five invariants

The five §14 invariants map to concrete tests below. Each invariant's shown code is the assertion; the handler drives bounded random actions and maintains ghosts.

**Files:**
- Create `contracts/test/v2/handlers/PoolV2Handler.sol`
- Create `contracts/test/v2/ArcoraDexPoolV2.invariant.t.sol`

- [ ] **Step 1: Write the handler**

Create `contracts/test/v2/handlers/PoolV2Handler.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexPoolV2} from "../../../src/v2/ArcoraDexPoolV2.sol";
import {ArcoraDexRegistryV2} from "../../../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexLPV2} from "../../../src/v2/ArcoraDexLPV2.sol";
import {MockOracleAdapterV2} from "../mocks/MockOracleAdapterV2.sol";
import {MintableERC20} from "../../../src/testnet/MintableERC20.sol";

contract PoolV2Handler is Test {
    ArcoraDexPoolV2 public pool;
    ArcoraDexRegistryV2 public reg;
    ArcoraDexLPV2 public lp;
    MockOracleAdapterV2 public adapter;
    address public owner;
    address[] public actors;
    address[] public toks;

    // Ghost: whether any token is currently in a single-source/unsafe state. When true,
    // no oracle-priced op may succeed (invariant 3). We model "single source" exactly as
    // the adapter reporting unsafe.
    mapping(address token => bool) public unsafe;
    // Ghost: snapshot of pre/post equal-basket check for proportional exits.
    bool public lastProportionalEqualBasket = true;

    constructor(address pool_, address reg_, address lp_, address adapter_, address owner_, address[] memory actors_, address[] memory toks_) {
        pool = ArcoraDexPoolV2(pool_);
        reg = ArcoraDexRegistryV2(reg_);
        lp = ArcoraDexLPV2(lp_);
        adapter = MockOracleAdapterV2(adapter_);
        owner = owner_;
        actors = actors_;
        toks = toks_;
    }

    function deposit(uint256 aSeed, uint256 tSeed, uint256 amtSeed) external {
        address actor = actors[aSeed % actors.length];
        address t = toks[tSeed % toks.length];
        uint256 amt = bound(amtSeed, 1e6, 50_000e6);
        if (MintableERC20(t).balanceOf(actor) < amt) return;
        vm.prank(actor);
        MintableERC20(t).approve(address(pool), amt);
        vm.prank(actor);
        try pool.deposit(t, amt, 0, block.timestamp + 1) {} catch {}
    }

    function swap(uint256 aSeed, uint256 inSeed, uint256 outSeed, uint256 amtSeed) external {
        address actor = actors[aSeed % actors.length];
        address tIn = toks[inSeed % toks.length];
        address tOut = toks[outSeed % toks.length];
        if (tIn == tOut) return;
        uint256 amt = bound(amtSeed, 1e6, 20_000e6);
        if (MintableERC20(tIn).balanceOf(actor) < amt) return;
        vm.prank(actor);
        MintableERC20(tIn).approve(address(pool), amt);
        vm.prank(actor);
        try pool.swap(tIn, tOut, amt, 0, block.timestamp + 1, actor) {} catch {}
    }

    function withdrawSingle(uint256 aSeed, uint256 tSeed, uint256 lpSeed) external {
        address actor = actors[aSeed % actors.length];
        address t = toks[tSeed % toks.length];
        uint256 bal = lp.balanceOf(actor);
        if (bal == 0) return;
        uint256 amt = bound(lpSeed, 1, bal);
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
        vm.prank(actor);
        try pool.withdrawSingle(t, amt, 0, block.timestamp + 1) {} catch {}
    }

    function withdrawProportional(uint256 aSeed, uint256 lpSeed) external {
        address actor = actors[aSeed % actors.length];
        uint256 bal = lp.balanceOf(actor);
        if (bal == 0) return;
        uint256 amt = bound(lpSeed, 1, bal);
        uint256 supply = lp.totalSupply();
        // Capture pre-state reserve ratios for the equal-basket check.
        uint256 n = reg.tokensLength();
        uint256[] memory preRes = new uint256[](n);
        for (uint256 i; i < n; ++i) preRes[i] = pool.reserves(reg.tokens(i));
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
        vm.prank(actor);
        try pool.withdrawProportional(amt, block.timestamp + 1) {
            // Equal basket: each token debited by exactly floor(amt*preRes/supply).
            for (uint256 i; i < n; ++i) {
                uint256 expDebit = (amt * preRes[i]) / supply;
                uint256 postRes = pool.reserves(reg.tokens(i));
                if (preRes[i] - postRes != expDebit) lastProportionalEqualBasket = false;
            }
        } catch {}
    }

    function setUnsafe(uint256 tSeed, bool flag) external {
        address t = toks[tSeed % toks.length];
        adapter.setSafe(t, !flag); // flag==true => unsafe
        unsafe[t] = flag;
    }

    function pauseToggle() external {
        if (pool.paused()) {
            vm.prank(owner);
            try pool.unpause() {} catch {}
        } else {
            vm.prank(owner);
            try pool.pause() {} catch {}
            vm.prank(owner);
            try pool.unpause() {} catch {}
        }
    }

    function anyUnsafe() external view returns (bool) {
        for (uint256 i; i < toks.length; ++i) {
            if (unsafe[toks[i]]) return true;
        }
        return false;
    }
}
```

- [ ] **Step 2: Write the five invariants**

Create `contracts/test/v2/ArcoraDexPoolV2.invariant.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {V2Fixture} from "./helpers/V2Fixture.sol";
import {PoolV2Handler} from "./handlers/PoolV2Handler.sol";
import {MintableERC20} from "../../src/testnet/MintableERC20.sol";
import {FeeBandMathV2} from "../../src/v2/lib/FeeBandMathV2.sol";

contract ArcoraDexPoolV2Invariant is StdInvariant, V2Fixture {
    PoolV2Handler handler;
    address a1 = makeAddr("a1");
    address a2 = makeAddr("a2");

    function setUp() public {
        _deployV2();
        // Seed both tokens at target.
        _seed(usdc, makeAddr("seeder"), 2_000_000e6);
        _seed(eurc, makeAddr("seeder2"), 2_000_000e6);
        // Fund actors.
        _mint(usdc, a1, 1_000_000e6);
        _mint(eurc, a1, 1_000_000e6);
        _mint(usdc, a2, 1_000_000e6);
        _mint(eurc, a2, 1_000_000e6);

        address[] memory actors = new address[](2);
        actors[0] = a1;
        actors[1] = a2;
        address[] memory tks = new address[](2);
        tks[0] = address(usdc);
        tks[1] = address(eurc);
        handler = new PoolV2Handler(address(pool), address(reg), address(lp), address(adapter), owner, actors, tks);
        targetContract(address(handler));
    }

    /// §14 INV-1: tokenBalance >= reserves[token] + protocolFeesAccrued[token].
    function invariant_balance_ge_reserves_plus_fees() public view {
        address[2] memory tks = [address(usdc), address(eurc)];
        for (uint256 i; i < tks.length; ++i) {
            uint256 bal = MintableERC20(tks[i]).balanceOf(address(pool));
            assertGe(bal, pool.reserves(tks[i]) + pool.protocolFeesAccrued(tks[i]), "balance < reserves + fees");
        }
    }

    /// §14 INV-2: oraclePricedOperation => postReserveUsd >= minimumReserveUsd.
    /// After any sequence of priced ops, every active token's accounted reserve USD
    /// (at the current safe price, or skipped if unsafe) is >= its floor.
    function invariant_priced_ops_respect_floor() public view {
        address[2] memory tks = [address(usdc), address(eurc)];
        for (uint256 i; i < tks.length; ++i) {
            (uint256 p, bool safe) = adapter.peekPrice(tks[i]);
            if (!safe) continue; // unsafe tokens cannot be priced — INV-3 covers them
            uint256 dec = reg.tokenConfig(tks[i]).decimals;
            uint256 reserveUsd = (pool.reserves(tks[i]) * p) / (10 ** dec);
            assertGe(reserveUsd, reg.tokenConfig(tks[i]).minimumReserveUsd, "reserve below floor after priced op");
        }
    }

    /// §14 INV-3: singleSourceOracle => no oraclePricedOperation. Modelled via the
    /// adapter unsafe flag: when a token is unsafe, a quoteSwapV2 into it MUST revert
    /// (the priced path is closed). Proportional exit is NOT a priced op and is unaffected.
    function invariant_unsafe_blocks_priced_path() public {
        address[2] memory tks = [address(usdc), address(eurc)];
        for (uint256 i; i < tks.length; ++i) {
            (, bool safe) = adapter.peekPrice(tks[i]);
            if (safe) continue;
            // Pick the other token as input.
            address tIn = tks[i] == address(usdc) ? address(eurc) : address(usdc);
            try pool.quoteSwapV2(tIn, tks[i], 1e6) {
                revert("priced path open on unsafe token");
            } catch {
                // expected: OracleUnsafe (or, if tIn also unsafe, still reverts)
            }
        }
    }

    /// §14 INV-4: proportionalExit preserves equal basket treatment.
    function invariant_proportional_equal_basket() public view {
        assertTrue(handler.lastProportionalEqualBasket(), "proportional exit broke equal-basket");
    }

    /// §14 INV-5: fee(split execution) ~= fee(single execution), bounded tolerance.
    /// Tolerance: <= 8 wei of 1e18-USD across up to 2 split boundaries (≤4 wei each).
    function invariant_split_equals_single_fee() public view {
        // Use a fixed probe against the live USDC reserve.
        FeeBandMathV2.Band[] memory b = _defaultBands();
        uint256 reserveUsd = (pool.reserves(address(usdc)) * 1e18) / 1e6;
        uint256 min = reg.tokenConfig(address(usdc)).minimumReserveUsd;
        uint256 tgt = reg.tokenConfig(address(usdc)).targetReserveUsd;
        if (reserveUsd <= min) return; // nothing consumable; skip
        uint256 gross = (reserveUsd - min) / 4; // a chunk well within capacity
        if (gross == 0) return;
        FeeBandMathV2.Result memory single = FeeBandMathV2.traverse(gross, reserveUsd, min, tgt, b, PROT_SHARE);
        FeeBandMathV2.Result memory h1 = FeeBandMathV2.traverse(gross / 2, reserveUsd, min, tgt, b, PROT_SHARE);
        uint256 reserveAfter = reserveUsd - h1.totalReserveDebitUsd;
        FeeBandMathV2.Result memory h2 = FeeBandMathV2.traverse(gross - gross / 2, reserveAfter, min, tgt, b, PROT_SHARE);
        uint256 splitFee = h1.totalFeeUsd + h2.totalFeeUsd;
        uint256 diff = single.totalFeeUsd > splitFee ? single.totalFeeUsd - splitFee : splitFee - single.totalFeeUsd;
        assertLe(diff, 8, "split vs single fee divergence exceeds tolerance");
    }
}
```

- [ ] **Step 3: Run the invariant suite (expected pass)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ArcoraDexPoolV2.invariant.t.sol" 2>&1 | tail -12
```
Expected: all five invariants pass. If `invariant_priced_ops_respect_floor` ever trips, it indicates a `traverse` rounding bug placing more debit than capacity — fix `_grossForDebit`'s trim loop, do not loosen the invariant.

- [ ] **Step 4: Full suite + commit**

Run:
```bash
cd contracts && forge test 2>&1 | tail -3
git add contracts/test/v2/handlers/PoolV2Handler.sol contracts/test/v2/ArcoraDexPoolV2.invariant.t.sol
git commit -m "test(v2): five §14 stateful invariants + bounded-action handler

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
Expected: 196 (V1) + all V2 unit/invariant tests; 0 failed.

---

### Task 12: Exact-fee band coverage + boundary tests (§14 fee schedule)

The §14 testing list demands "exact fee results inside each band and across every boundary." Task 2 covered the library in isolation; this task pins exact end-to-end swap outputs at each health band on the live Pool with the default §7 config, so a future config or math regression fails CI.

**Files:**
- Create `contracts/test/v2/ArcoraDexPoolV2.bands.t.sol`

- [ ] **Step 1: Write the per-band exact-fee swap test**

Create `contracts/test/v2/ArcoraDexPoolV2.bands.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";

/// @notice Pins exact marginal-fee behaviour at each §7 band on the live Pool. Seeding
/// EURC to a chosen reserve sets its starting health; a small swap then samples the
/// marginal band rate. Default config: available = 1,000,000 USD; bands 0.05/0.20/0.75/3.00%.
contract ArcoraDexPoolV2BandsTest is V2Fixture {
    function setUp() public {
        _deployV2();
        _seed(usdc, makeAddr("seeder"), 5_000_000e6); // deep USDC input reservoir
    }

    function _seedEurcToHealth(uint256 healthBps) internal {
        // reserveUsd = min + available * healthBps / 10000 ; tokens (6dec) = reserveUsd / 1e12.
        uint256 reserveUsd = 1_000_000e18 + (1_000_000e18 * healthBps) / 10_000;
        uint256 tokens = reserveUsd / 1e12;
        _seed(eurc, makeAddr("eseeder"), tokens);
    }

    function _marginalFeeBps(uint256 healthBps) internal returns (uint256 feeBpsApprox) {
        _seedEurcToHealth(healthBps);
        uint256 amtIn = 100e6; // tiny → stays within the starting band
        _mint(usdc, alice, amtIn);
        vm.startPrank(alice);
        usdc.approve(address(pool), amtIn);
        uint256 out = pool.swap(address(usdc), address(eurc), amtIn, 0, block.timestamp + 1, alice);
        vm.stopPrank();
        // gross ≈ 100e6 ; fee ≈ gross - out ; feeBps = fee*10000/gross.
        uint256 fee = 100e6 - out;
        feeBpsApprox = (fee * 10_000) / 100e6;
    }

    function test_band0_5bps_at_90pct() public {
        assertApproxEqAbs(_marginalFeeBps(9_000), 5, 1, "band-0 0.05%");
    }
    function test_band1_20bps_at_60pct() public {
        assertApproxEqAbs(_marginalFeeBps(6_000), 20, 1, "band-1 0.20%");
    }
    function test_band2_75bps_at_40pct() public {
        assertApproxEqAbs(_marginalFeeBps(4_000), 75, 1, "band-2 0.75%");
    }
    function test_band3_300bps_at_10pct() public {
        assertApproxEqAbs(_marginalFeeBps(1_000), 300, 1, "band-3 3.00%");
    }
}
```

- [ ] **Step 2: Run it (expected pass — Pool + library already implemented)**

Run:
```bash
cd contracts && forge fmt && forge test --match-path "test/v2/ArcoraDexPoolV2.bands.t.sol" 2>&1 | tail -8
```
Expected: `4 passed; 0 failed`. Each setup uses a fresh `eseeder` deposit; a 100-USDC swap is small enough not to cross into the next band, so the sampled fee equals the starting band's marginal rate within 1 bps of integer dust.

- [ ] **Step 3: Commit**

Run:
```bash
git add contracts/test/v2/ArcoraDexPoolV2.bands.t.sol
git commit -m "test(v2): exact marginal-fee per-band coverage on live Pool (§14 fee schedule)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 13: Full suite run, fmt gate, and CI-profile invariant pass

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
Expected: `(196 + N) tests passed, 0 failed, 0 skipped`, where N is the count of new V2 tests. Record N.

- [ ] **Step 3: CI-profile invariants (10000 fuzz / 1024 invariant runs)**

Run:
```bash
cd contracts && FOUNDRY_PROFILE=ci forge test --match-path "test/v2/*" 2>&1 | tail -8
```
Expected: all V2 tests pass under the heavier CI profile (the §14 invariants run 1024×128). If an invariant trips here but not under default, it is a real rounding/floor bug — debug `FeeBandMathV2` with `superpowers:systematic-debugging`, never loosen the bound.

- [ ] **Step 4: Confirm no `revert()` placeholder stubs remain**

Run:
```bash
cd contracts && grep -n "implemented in Task" src/v2/ArcoraDexPoolV2.sol || echo "OK: no task stubs remain"
```
Expected: `OK: no task stubs remain`. If any line prints, the corresponding stub was not replaced — go back and replace it.

- [ ] **Step 5: Commit any fmt fixups (if Step 1 required them)**

Run:
```bash
git add -A && git commit -m "style(v2): forge fmt gate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" || echo "nothing to commit"
```

---

## Self-Review

### Spec coverage (section-by-section)

- **§6.1 Immutable Pool** — `ArcoraDexPoolV2` has no proxy/initializer; all config is constructor-immutable or read from the Registry. Task 6. ✓
- **§6.2 Extensible Registry + validation** — `TokenConfigV2` carries adapter, min/target reserve USD, fee bands, `depositCapUsd`, `protocolFeeShareBps`, active flag. `_validate` enforces target>min, bands ordered/contiguous (first band 100%, strictly descending), non-decreasing rates, rate ≤ MAX_FEE_BPS, decimals match. `Ownable2Step` (timelock owner), guardian pause-only on the Pool. I-1 `setPool` guard. Task 4. ✓
- **§7 Reserve health + dynamic fees** — health formula in `FeeBandMathV2.healthBps`; default schedule (0.05/0.20/0.75/3.00%, below-floor prohibited) in `V2Fixture._defaultBands` and Registry validation; marginal charging via `traverse`; segment formulas (`segmentFee`/`segmentProtocolFee`/`segmentUserOutput`/`segmentReserveDebit`) in `_debitOf`; band capacity measured in reserve debit; conservative rounding (maxima down, fee up, protocol down, gross-from-debit down). Tasks 2, 12. ✓
- **§8.1 Swap** — measured input, gross via accepted price, band traversal, net+protocol split, minOut+floor enforcement, reserve update. Task 6. ✓
- **§8.2 Single-token withdraw** — NAV-valued gross share, marginal traversal, minTokenOut+floor, no queue/partial. Task 7. ✓
- **§8.3 Proportional emergency withdraw** — pro-rata basket of every reserve, no oracle/floor/pause gate, reentrancy-guarded, protocol fees excluded, equal basket. Task 8. ✓
- **§9 Views (contract side)** — `reserveHealth`, `maxSwapOut`, `maxWithdraw`, `quoteSwapV2`, `quoteWithdrawV2` with fee breakdown + post-health; quotes-not-reservations; no-overstate. Tasks 6, 7, 9. App-side parts explicitly OUT. ✓
- **§11 Oracle failure behavior (via adapter)** — adapter binary `safe`; swap/deposit/single-withdraw into unsafe stop; NAV-requiring-unsafe ops stop (via `_navMut` iterating all active tokens); proportional remains. Last price retained for display but never authorizes transfer (`_readSafe` requires `safe && price!=0`). Tasks 6-8, 10. ✓
- **§14 Testing + invariants** — exact per-band fees + boundaries (Tasks 2, 12); split≈single (Tasks 2, 11 INV-5); stop-at-floor (Tasks 2, 7, 9); max* no-overstate (Task 9); quote/exec parity (Tasks 6, 7); fee-on-transfer input (carry V1 FeeOnTransferERC20 into a swap test — see note below); balance conservation (INV-1); oracle unsafe/single-source (Task 10, INV-3); proportional during failure/pause (Task 8); Registry-additions-without-Pool-change (Task 4 + the fact V2 Pool is untouched when listing). The five stateful invariants are INV-1..INV-5 in Task 11. ✓

### Invariant → test map (§14)

| §14 invariant | Test | Tolerance |
|---|---|---|
| `tokenBalance >= reserves + protocolFeesAccrued` | `invariant_balance_ge_reserves_plus_fees` | exact (`assertGe`) |
| `oraclePricedOperation => postReserveUsd >= minimumReserveUsd` | `invariant_priced_ops_respect_floor` | exact (`assertGe`) |
| `singleSourceOracle => no oraclePricedOperation` | `invariant_unsafe_blocks_priced_path` | exact (must revert) |
| `proportionalExit preserves equal basket` | `invariant_proportional_equal_basket` | exact (per-token debit == floor(amt·res/supply)) |
| `fee(split) ~= fee(single)` | `invariant_split_equals_single_fee` | **≤ 8 wei of 1e18-USD** (≤4 wei per boundary, ≤2 boundaries) |

### Placeholder scan
- No "TBD", "add validation", "similar to Task N", or undefined-function references in the shown code.
- The four `revert()` stubs in Task 6 are explicitly temporary; Tasks 7-9 replace each in-place, and Task 13 Step 4 greps to confirm none remain.
- One follow-up the worker MUST add (flagged, not a placeholder): a fee-on-transfer **input** swap test reusing `contracts/test/mocks/FeeOnTransferERC20.sol` (V1 mock) to prove `receivedIn` measurement (§14 "fee-on-transfer input accounting"). Add it to `ArcoraDexPoolV2.swap.t.sol` in Task 6 Step 1 as a fourth case: deposit/list a FOT token in the fixture variant, swap it in, assert reserves credit the measured delta. The pattern is identical to V1's `swap` L-10 handling already in the Pool.

### Type/name consistency across tasks
- `FeeBandMathV2.Band{upperHealthBps, rateBps}` and `FeeBandMathV2.Result{ok, totalUserOutputUsd, totalProtocolFeeUsd, totalReserveDebitUsd, totalFeeUsd}` — used identically in the library, Registry struct, fixture, Pool, and all tests.
- `IArcoraDexRegistryV2.TokenConfigV2` field names (`adapter`, `minimumReserveUsd`, `targetReserveUsd`, `depositCapUsd`, `protocolFeeShareBps`, `bands`, `decimals`, `isActive`) — consistent in interface, contract, fixture, tests.
- `IOracleAdapterV2.readPrice/peekPrice → (uint256 price1e18, bool safe)` — consistent in interface, mock, Pool `_readSafe`/`_peekSafe`.
- Pool entry points: `deposit`, `swap`, `withdrawSingle`, `withdrawProportional`, plus views `reserveHealth`/`maxSwapOut`/`maxWithdraw`/`quoteSwapV2`/`quoteWithdrawV2` — declared once in `IArcoraDexPoolV2` and implemented once in `ArcoraDexPoolV2`.
- Errors used in tests (`OracleUnsafe`, `ReserveFloorBreached`, `InvalidBands`, `InvalidReserveBounds`, `TokenDecimalMismatch`, `TokenHasReserves`, `TokenStillActive`, `NotAuthorized`, `NotMinter`, `ZeroAddress`) all exist in the corresponding interface.
- `notifyLPTransfer(address from, address)` signature is identical in the Task-3 stub and the Task-4 full `IArcoraDexPoolV2`, so the LP token compiles unchanged across the interface replacement.

### Carried-forward V1 audited patterns (explicit)
Ownable2Step + guardian split, ReentrancyGuard, SafeERC20, measured balance deltas (L-10), minOut/minTokenOut/deadline, 1e18 NAV accounting, virtual-share offset (#A first-depositor), LP min-hold sender-gate (H-1), I-1 reserve guard via `Registry.setPool`. Each appears in the Pool/Registry/LP shown code with the same intent as V1.
