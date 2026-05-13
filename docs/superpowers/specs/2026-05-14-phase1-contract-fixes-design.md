# Phase 1 — Smart Contract Critical Fixes Design Spec

**Date:** 2026-05-14
**Status:** Brainstorming complete — pending user review, then writing-plans
**Authors:** Hüseyin Arslan + Claude
**Roadmap parent:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §3
**Audit context:** Closes four findings from the 2026-05-12 review + 2026-05-13 economic-attack follow-up: #A (inflation attack, CRITICAL), #B (JIT/MEV sandwich, HIGH), #C (quote↔execute gap, MEDIUM), #4 (per-token staleness + graceful fallback, MEDIUM).

**Duration:** 2–2.5 weeks; ships as 4–5 PRs.

---

## 1. Context & Motivation

The ArcoraDEX pool currently has four mainnet-blocking weaknesses, three on the economic-security boundary and one on the operational-availability boundary:

- **#A Inflation attack:** `MINIMUM_LIQUIDITY = 1000` (USD-1e18 wei, i.e. effectively zero) gives the first depositor near-total control of the first LP unit. A pre-empted first deposit followed by a direct token transfer can cause every subsequent deposit under ~$10 to round to zero LP minted. This is the Uniswap V2 inflation attack class; mainnet-deploying without a fix invites first-day exploitation.

- **#B JIT/MEV sandwich:** Atomic deposit-then-withdraw across an oracle update lets an MEV bot capture the NAV delta. `_readAndGuardPrice` only ratchets per-token, but `totalReservesUSD()` always reads current oracle. A bot deposits before the keeper's `setAnswer`, then withdraws after — earning the price delta on capital they never bore the risk for.

- **#C Quote↔execute gap:** `quote()` uses `_readUsdPrice1e18` (no ratchet check); `swap()` uses `_readAndGuardPrice` (ratchet check). Users see optimistic quotes that revert at execute time when the deviation guard catches up — broken UX and broken integrator promises.

- **#4 Stale-feed availability lock:** A single stale active feed reverts `totalReservesUSD()`, which reverts every deposit and withdraw. Swaps not involving the stale token still work, but LPs cannot exit during outages. Combined with the global `MAX_STALE_SECONDS = 1 hour` constant, an exotic-FX feed that legitimately has a 24h heartbeat would lock the pool every day.

This phase delivers four contract-level fixes. P2 (governance) runs in parallel; P3 (oracle hardening) starts mid-phase after the storage layout for #4 is committed.

---

## 2. Goals & Non-Goals

**Goals**
- Close #A: virtual-shares math eliminates inflation-attack profit (attacker loses money instead of gaining).
- Close #B: 1-hour LP min-hold defeats the JIT sandwich across at least one oracle cycle.
- Close #C: `quote()` and `swap()` revert under identical conditions.
- Close #4: per-token staleness budgets, cached fallback price keeps LP exit available during feed outages.
- Maintain `forge test` green and add ≥4 PoC tests covering each finding.

**Non-Goals**
- Oracle aggregation (Chainlink + secondary source) — P3.
- Tightening per-token `maxOracleDeviationBps` — P3.
- Governance multisig migration — P2.
- Gas optimization beyond what's natural in the rewrite.
- Mainnet deploy runbook — P5.
- Litepaper update — deferred until P1 ships (mechanics need to settle before re-documentation).

---

## 3. Fixes

### 3.1 #A Inflation Attack — Virtual Shares (ERC4626 Offset)

**Approach:** Adapt OpenZeppelin's ERC4626 virtual-offset pattern to the custom pool math.

**New constants:**
```solidity
uint256 internal constant VIRTUAL_SHARES = 1e6;
uint256 internal constant VIRTUAL_ASSETS = 1; // USD-1e18 wei
```

**Math changes:**

In `deposit()`, replace:
```solidity
lpMinted = (usdIn * supply) / navBefore;
```
with:
```solidity
lpMinted = (usdIn * (supply + VIRTUAL_SHARES)) / (navBefore + VIRTUAL_ASSETS);
```

In `withdraw()`, replace:
```solidity
uint256 usdRedeemed = (lpAmount * navBefore) / LP.totalSupply();
```
with:
```solidity
uint256 usdRedeemed = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (LP.totalSupply() + VIRTUAL_SHARES);
```

In `quoteDeposit()` and `quoteWithdraw()`: mirror the changes.

**First-deposit branch:**

The existing branch:
```solidity
if (supply == 0) {
    if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
    lpMinted  = usdIn - MINIMUM_LIQUIDITY;
    ...
}
```

**Decision: keep MINIMUM_LIQUIDITY = 1000 and the DEAD-address mint** for defense-in-depth and to preserve existing audit/test semantics. Virtual shares alone close the attack mathematically, but keeping the DEAD lock means a saturating attacker also has to forfeit 1000 USD-1e18 wei worth of LP — a small but non-zero additional friction.

The `supply == 0` branch becomes simpler: still mint `MINIMUM_LIQUIDITY` to DEAD on first deposit, but the depositor's LP amount uses the same unified virtual-shares formula:

```solidity
if (supply == 0) {
    if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
    lpMinted = (usdIn * (0 + VIRTUAL_SHARES)) / (0 + VIRTUAL_ASSETS); // = usdIn * 1e6
    LP.mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
} else {
    lpMinted = (usdIn * (supply + VIRTUAL_SHARES)) / (navBefore + VIRTUAL_ASSETS);
}
```

Audit-grade tests verify both paths.

**Storage impact:** None. Two new `internal constant` values.

**Effect on attack:**
- Attacker first-deposits 1 USD-wei (usdIn = 1, lpMinted = 1 × 1e6 / 1 = 1e6)
- Attacker direct-transfers 10,000 × 1e18 USD-units to the pool
- Real user deposits 1e18 USD-units (1 USD):
  - `lpMinted = 1e18 × (1e6 + 1e6) / (10000e18 + 1) ≈ 2e24 / 1e22 = 200`
  - Real user owns 200 / 1,000,200 ≈ 0.02% of supply
  - Real user contributed 1e18 / 10001e18 ≈ 0.01% of NAV
  - User is FAVORED (over-receives) — attacker dilutes themselves
- Attacker withdrawing their 1e6 LP gets back less than the 10,000 USD they donated. Attack is economically negative.

**Audit-grade PoC test** (`test_inflation_attack_fails_after_fix`):
1. Setup: deploy fresh pool, list 1 token, no deposits.
2. Attacker deposits minimum amount.
3. Attacker direct-transfers (via low-level `transfer`) a large amount of the token.
4. Real user deposits a small amount.
5. Real user immediately withdraws their LP.
6. Assert: real user receives ≥99% of their deposit value back.
7. Assert: attacker withdrawing their LP receives ≤ 50% of their inflated-balance value back (net loss).

### 3.2 #B JIT/MEV Sandwich — 1-Hour LP Min-Hold

**New storage:**
```solidity
mapping(address => uint256) public lastMintAt;
uint256 public constant MIN_HOLD_SECONDS = 1 hours;
```

**`deposit()` change:**

At the end of the function, after the mint emits:
```solidity
lastMintAt[msg.sender] = block.timestamp;
```

This overwrites on each deposit — semantics: "earliest withdrawable time = last deposit + 1h". If an LP deposits a second time during hold, the hold extends. This is conservative but predictable.

**`withdraw()` change:**

At the top, after the `lpAmount == 0` check:
```solidity
if (block.timestamp < lastMintAt[msg.sender] + MIN_HOLD_SECONDS) {
    revert EarlyWithdraw(lastMintAt[msg.sender] + MIN_HOLD_SECONDS, block.timestamp);
}
```

**New error type** (in IArcoraDexPool):
```solidity
error EarlyWithdraw(uint256 unlockAt, uint256 nowAt);
```

**Why 1 hour:** Keeper cadence is 30 minutes. 1 hour guarantees at least one full keeper cycle between deposit and withdraw. JIT bot's edge — atomically capturing an oracle update — requires both legs in the same MEV bundle (~1 block); 1 hour makes this infeasible regardless of bundling.

**Edge cases:**
- LP transfer to a fresh address: the receiving address has `lastMintAt = 0`, so they can withdraw immediately. **Decision:** this is the intended behavior; LP token is freely transferable, and an LP who held >1h on one wallet then transferred is no longer the bot scenario. Document this in the litepaper.
- LP token sent to the pool itself (round-trip): not relevant because pool doesn't own its own LP.
- First deposit (lastMintAt = 0): unlockAt = 0 + 3600, so user must wait. Founding LPs do their first deposit, then wait ≥1h to do anything else. Acceptable.

**Audit-grade PoC test** (`test_jit_mev_blocked_by_min_hold`):
1. Setup: pool with existing liquidity, keeper-style oracle bumper available.
2. Attacker deposits.
3. Attacker bumps an oracle (simulating a keeper push).
4. Attacker attempts withdraw → assert reverts with `EarlyWithdraw`.
5. Advance `block.timestamp` by 1h - 1s → still reverts.
6. Advance `block.timestamp` by 1 more second → withdraw succeeds.

### 3.3 #C Quote↔Execute Gap — `quote()` Applies Ratchet Check

**New internal helper:**
```solidity
function _readUsdPrice1e18WithGuard(address token)
    internal view
    returns (uint256 price1e18, uint8 tokenDecimals)
{
    // Same logic as _readUsdPrice1e18, plus:
    // - reads info.maxOracleDeviationBps
    // - reads lastAcceptedPrice[token]
    // - reverts with PriceDeviation if the simulated ratchet would fail
    // - does NOT mutate state (no write to lastAcceptedPrice)
}
```

**`quote()` change:**

Replace the two `_readUsdPrice1e18` calls with `_readUsdPrice1e18WithGuard`. The function signature stays the same: still `view`, still returns `uint256 amountOut`. But it may now revert with `PriceDeviation` whenever `swap()` would revert.

**`totalReservesUSD()` decision:** keep using `_readUsdPrice1e18` (no guard). NAV computation should reflect *current oracle reality*, not the conservative ratchet view. Otherwise NAV would be artificially stale and unfair to remaining LPs after a long quiet period.

**`quoteDeposit()` and `quoteWithdraw()`:** these are used for LP operations, which use `_readAndGuardPrice` in the stateful path. Same fix applies — switch them to `_readUsdPrice1e18WithGuard`.

**Breaking change:** SDK and frontend consumers that call `quote()` and expect a `uint256` will now sometimes receive a revert. The pool is pre-mainnet; SDK update is part of P5. Document in the litepaper update and tag the breaking change in release notes.

**Audit-grade PoC test** (`test_quote_reverts_when_swap_would_revert`):
1. Setup: pool with a token whose `lastAcceptedPrice` has been "frozen" (manually set via test helper to simulate the EURC scenario).
2. Bump the oracle 7% above lastAccepted (exceeding 150 bps cap).
3. Call `quote()` → assert reverts with `PriceDeviation`.
4. Call `swap()` with same args → assert reverts with same error.
5. Sync via `syncAcceptedPrice` → both succeed.

### 3.4 #4 Per-Token Staleness + Cached Fresh Price Fallback

**Registry schema extension:**

In `IArcoraDexRegistry.TokenInfo`, add:
```solidity
struct TokenInfo {
    uint8 decimals;
    bool isActive;
    IChainlinkAggregator usdOracle;
    uint16 maxOracleDeviationBps;
    uint32 maxStaleSeconds; // NEW
}
```

**`listToken()` change:** add `uint32 maxStaleSeconds` parameter. Validate `maxStaleSeconds >= 60 && maxStaleSeconds <= 7 days`.

**New `setMaxStaleSeconds()` mutator:** owner-only, mirrors `setDeviation()`. Used by governance to retune per-token.

**Default values for testnet migration** (P3 will retune for mainnet):
- USDC, USDT, PYUSD, DAI: 3600 (1h)
- EURC: 14,400 (4h)
- TRYC, BRLC: 86,400 (24h)

**Pool storage extension:**
```solidity
mapping(address => uint256) public lastValidPrice;     // 1e18-scaled USD price
mapping(address => uint256) public lastValidPriceAt;   // block.timestamp of cache write
```

**`_readUsdPrice1e18` rewrite:**
```solidity
function _readUsdPrice1e18(address token)
    internal returns (uint256 price1e18, uint8 tokenDecimals)
{
    IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
    if (!info.isActive) revert TokenNotActive(token);
    tokenDecimals = info.decimals;

    (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
        info.usdOracle.latestRoundData();

    bool oracleFresh = (
        roundId != 0 &&
        answeredInRound >= roundId &&
        answer > 0 &&
        updatedAt != 0 &&
        updatedAt <= block.timestamp &&
        (block.timestamp - updatedAt) <= info.maxStaleSeconds
    );

    if (oracleFresh) {
        uint8 oracleDec = info.usdOracle.decimals();
        if (oracleDec == 18)      price1e18 = uint256(answer);
        else if (oracleDec < 18)  price1e18 = uint256(answer) * (10 ** (18 - oracleDec));
        else                      price1e18 = uint256(answer) / (10 ** (oracleDec - 18));

        // Cache fresh read
        lastValidPrice[token]   = price1e18;
        lastValidPriceAt[token] = block.timestamp;
        return (price1e18, tokenDecimals);
    }

    // Oracle stale — fall back to cache
    price1e18 = lastValidPrice[token];
    if (price1e18 == 0) revert NoValidPrice(token);
    return (price1e18, tokenDecimals);
}
```

**Critical:** the function is now `internal` (not `view`) — it mutates `lastValidPrice` and `lastValidPriceAt` on success. `totalReservesUSD()` is no longer `view`. Two callers affected:

1. **`quote()` and `quoteDeposit()` / `quoteWithdraw()`** — these are view functions. They cannot call the mutating version. Solution: split into two functions:
   - `_readUsdPrice1e18Mut` (mutating, fresh-only path updates cache) — used by `swap()`, `deposit()`, `withdraw()`, `totalReservesUSD()` (if called inside a state-mutating ext function)
   - `_readUsdPrice1e18View` (pure view, reads cache without updating) — used by view-only quotes

2. **`totalReservesUSD()`** — currently `public view`. Two callers:
   - `quoteDeposit`, `quoteWithdraw` (view paths) → use a view-equivalent `_totalReservesUSDView`
   - `deposit`, `withdraw` (mutating paths) → use the mutating `_totalReservesUSDMut`

This duplication is acceptable; both helpers share an internal reader.

**Decision: do NOT update cache from view paths.** If a view caller happens to read fresh oracle data, the cache stays where it was. Cache is only refreshed by state-mutating operations (deposit/withdraw/swap). This is conservative — stale cache is preferable to phantom updates.

**Error types added** (in IArcoraDexPool):
```solidity
error NoValidPrice(address token);
```

**Audit-grade PoC test** (`test_stale_feed_falls_back_to_cache`):
1. Setup: pool with 2 active tokens, one swap performed to seed `lastValidPrice` cache for both.
2. Advance `block.timestamp` past `maxStaleSeconds` for token A.
3. Assert: oracle's `latestRoundData` still returns the old (now-stale) value.
4. Call `totalReservesUSD()` → returns NAV using cached price for A.
5. Real user deposits token B → succeeds (oracle B is fresh, A uses cache).
6. Real user withdraws token A → succeeds (A uses cache for valuation, B uses fresh for accounting).

**Auxiliary test** (`test_no_valid_price_reverts_when_never_seeded`):
1. Setup: list a new token, never swap or deposit it.
2. Manipulate oracle to return stale value.
3. Any operation reading that token's price reverts `NoValidPrice`.

---

## 4. Migration Strategy

Pool and Registry both gain storage extensions, so both require redeploy (no proxy upgradability). For testnet:

1. Deploy new Registry; transfer ownership to deployer EOA initially (governance migration in P2 happens against the new Registry).
2. Re-list all 7 tokens with new `maxStaleSeconds` parameter; oracles point to existing `MockChainlinkFeedV2` instances (no feed redeploy).
3. Deploy new Pool against the new Registry; this also deploys a new LP token (per current constructor).
4. Bootstrap fresh liquidity in the new pool from the deployer's existing balances (faucet → approve → deposit).
5. Freeze the existing testnet pool (deployer calls `pause()`). Document its address as legacy; do not bridge liquidity automatically.
6. Update SDK/frontend addresses to point to new contracts (P5 task).

For mainnet, this is the first deploy — no migration concern.

**Decision: leave old testnet pool paused and abandoned.** The $69k of mock tokens has no economic value; recreating fresh liquidity is faster than writing a one-shot migration script.

---

## 5. Implementation Order

Across the 4 fixes, the order matters for storage layout and testing:

1. **#4 first** — Registry schema extension, Pool cache storage. This is the biggest single change. Lock the storage layout early so P3 can build on it.
2. **#A second** — virtual shares math, removes the `supply == 0` branch. Pure logic change after the staleness work settles.
3. **#B third** — adds `lastMintAt` storage to Pool. Independent of #A and #4 but easier to layer on top of a stable storage layout.
4. **#C last** — refactors `_readUsdPrice1e18` into mut/view split. This builds on the staleness rewrite from #4 and the math from #A.

Each is a separate PR with its own PoC test. PRs land in order on the `phase1/contract-fixes` branch; final merge to main when all four pass internal review.

---

## 6. Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Virtual-shares math has subtle rounding bug | Medium | OZ reference implementation; foundry fuzz tests for `lpMinted == 0` invariant impossibility (with non-zero usdIn) |
| LP min-hold confuses legitimate LPs | Low | Litepaper update with mechanics; frontend countdown UI in P5 |
| `_readUsdPrice1e18` mut/view split introduces inconsistency | Medium | Single internal reader function shared by both wrappers; thorough test coverage including same-block view-then-mut sequence |
| Migration to new testnet pool disrupts SDK/frontend testing | Low | P1 deliverable includes a `docs/rollouts/2026-05-XX-phase1-deploy.md` listing addresses + steps |
| Auditors flag virtual-shares offset as non-standard for non-ERC4626 vault | Medium | Pre-include math derivation + OZ reference link in the Spearbit doc pack |

---

## 7. Acceptance Criteria

P1 is complete when:
- All 4 PoC tests fail before each respective fix, pass after.
- `forge test` count ≥81 (current 77 + 4 new).
- `forge coverage --report summary` shows `contracts/src/` ≥85% lines.
- Slither runs with zero new findings (existing benign warnings suppressed with rationale).
- Litepaper section "Pool Mechanics" updated with virtual-shares note and min-hold note.
- New testnet pool deployed with all 7 tokens listed, feeds wired, ≥$1000 bootstrap liquidity.
- A rollout doc `docs/rollouts/2026-05-XX-phase1-deploy.md` lists new addresses and the freeze-old-pool runbook.

---

## 8. Open Questions Deferred to Plan / Implementation

1. **Virtual shares offset value** — defaulting to 1e6 (`10^6`). Plan can revisit if math suggests a different magnitude.
2. **`MIN_HOLD_SECONDS` exact value** — 1 hour proposed; plan may parameterize this as a constant the auditors can comment on.
3. **`maxStaleSeconds` per-token defaults** — listed above; P3 will retune based on Chainlink mainnet feed heartbeat survey.
4. **Whether `_readUsdPrice1e18Mut` should refresh cache on every successful read or only on "first read per block"** — gas micro-optimization; default to "every successful read" for simplicity, optimize if gas budget bites.
5. **Whether to emit a `PriceCacheUpdated` event** — useful for monitoring but not security-critical. Include for observability.
