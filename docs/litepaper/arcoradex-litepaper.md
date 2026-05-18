# ArcoraDEX — Technical Litepaper

**Version:** draft — Phase 4 (pre-audit)
**Date:** 2026-05-18
**Status:** ArcoraDEX is deployed on the Arc testnet (chainId 5042002) and is undergoing a Spearbit private security review ahead of mainnet. This document describes the protocol as of the `audit/spearbit-p4` baseline.

---

## 1. Abstract

ArcoraDEX is an oracle-priced, multi-stablecoin vault AMM deployed on the Arc testnet. It presents a single shared liquidity pool that simultaneously serves every trading pair across seven listed stablecoins (USDC, USDT, PYUSD, DAI, EURC, TRYC, and BRLC). Liquidity providers deposit any listed token and receive a single fungible receipt token, `ADEX-LP`, whose price tracks the net asset value (NAV) of the entire pool.

The core problem ArcoraDEX addresses is the fragmentation and slippage inherent in constant-product AMMs when applied to pegged assets. A typical x·y=k design requires a separate pair contract per token combination, splitting liquidity across many pools and imposing price impact proportional to the depth of each individual pair. For stablecoins — whose fair-value exchange rate is always close to the oracle price — this slippage is a structural cost with no compensating benefit. ArcoraDEX instead prices every swap from external oracle feeds: the output amount is calculated from the ratio of the two tokens' oracle prices, not from an invariant curve. All reserves are pooled into a single vault, so liquidity deposited once is available to every pair simultaneously.

The LP token represents a proportional claim on the pool's NAV. Fees collected from swaps and withdrawals accrue directly inside the reserves, increasing NAV and therefore increasing the value of all outstanding LP shares. There is no separate fee-distribution mechanism and no protocol-native token.

ArcoraDEX is pre-mainnet software. It is currently deployed on the Arc testnet (chainId 5042002) and is undergoing a private security review by Spearbit ahead of any mainnet deployment. This document reflects the protocol at the `audit/spearbit-p4` codebase baseline and is intended for developers, auditors, and sophisticated liquidity providers evaluating the protocol.

## 2. Protocol Overview

### Vault model

ArcoraDEX operates as a multi-asset vault rather than a collection of pair pools. A single `ArcoraDexPool` contract holds all token reserves and is the sole entry point for deposits, withdrawals, and swaps. The pool references an `ArcoraDexRegistry` for per-token configuration, and deploys a single `ArcoraDexLP` (ERC20 ticker: `ADEX-LP`) in its constructor as the LP receipt token. All three contracts are immutably bound at deployment.

### Listed stablecoins

The pool lists seven stablecoins, each with its own oracle and configuration registered in `ArcoraDexRegistry`:

| Symbol | Description |
|--------|-------------|
| USDC   | USD Coin |
| USDT   | Tether USD |
| PYUSD  | PayPal USD |
| DAI    | Dai Stablecoin |
| EURC   | Circle Euro Coin |
| TRYC   | Circle Turkish Lira Coin |
| BRLC   | Circle Brazilian Real Coin |

EURC, TRYC, and BRLC are non-USD pegs; their oracle prices are expressed in USD, so the pool treats them identically to USD-pegged assets at the contract level while their oracle prices naturally reflect the prevailing exchange rate.

### Shared LP token (`ADEX-LP`)

All liquidity providers receive shares of the same `ArcoraDexLP` ERC20 token regardless of which stablecoin they deposit. There is no per-pair LP token. A single `ADEX-LP` balance represents a proportional claim on the pool's entire NAV.

`ArcoraDexLP` is a minimal ERC20 whose `mint()` and `burn()` functions are restricted to the immutable `MINTER` address — the pool itself. The LP contract has no owner or admin. The `_update()` override propagates the pool's minimum-hold lock through secondary transfers (see §5 for the JIT-sandwich defence).

### NAV accounting

The pool's net asset value (`totalReservesUSD`) is the USD sum of its reserves across all active tokens:

```
NAV = Σ ( reserves[token] × price1e18[token] / 10^decimals[token] )
```

`reserves[token]` is an explicit storage mapping in `ArcoraDexPool` — it is updated on every `deposit`, `withdraw`, and `swap` call. The pool does **not** read `token.balanceOf(address(this))` for accounting. This architectural choice makes the pool immune to donation-inflation attacks: tokens sent to the pool address outside of a `deposit` call land in the contract's token balance but do not affect `reserves[]`, so NAV is unchanged and no attacker can inflate it by donating tokens.

LP share minting and redemption use virtual offsets (`VIRTUAL_SHARES = 1e6`, `VIRTUAL_ASSETS = 1` — both declared `internal constant` in `ArcoraDexPool`, fixed at compile time and not exposed in the ABI) in an ERC4626-style formula. These offsets guarantee that any non-zero deposit mints at least one LP share (preventing round-down-to-zero on small follow-up deposits) and provide belt-and-suspenders defence against inflation attacks on the LP math, independently of the `reserves[]` structural protection above.

### Registry configuration

`ArcoraDexRegistry` stores a `TokenInfo` struct for each listed token containing:

| Field | Purpose |
|-------|---------|
| `decimals` | Token decimal count (verified against `IERC20Metadata.decimals()` at `listToken` time) |
| `isActive` | Whether the token is eligible for operations |
| `usdOracle` | Address of the `IChainlinkAggregator`-compatible oracle for this token |
| `maxOracleDeviationBps` | Per-operation price-change cap (in basis points); enforced by the pool's deviation ratchet |
| `maxStaleSeconds` | Maximum age of an accepted oracle round (enforced in `_readOracle`) |

All registry mutators (`listToken`, `setOracle`, `setDeviation`, `setMaxStaleSeconds`, `deactivateToken`, `reactivateToken`) are `onlyOwner`, with the owner set to the 48-hour governance Timelock (see §6).

## 3. Mechanism Design

### 3.1 Oracle pricing vs. constant-product

A constant-product AMM (x·y=k) prices assets by the ratio of reserves. When two assets are near-perfectly pegged to the same value, the fair exchange rate is always approximately 1:1 (or at a known oracle-derived ratio for cross-currency stablecoins). A bonding curve forces a trader to move the pool's internal price across a range to complete a swap, incurring slippage even when the on-chain reserve ratio happens to diverge from the true market price.

ArcoraDEX bypasses this by pricing directly from oracle feeds. The output of a swap is determined by the ratio of the two tokens' oracle-reported USD prices — not by the shape of any curve. For $1 USD-equivalent in, the pool returns $1 USD-equivalent out (minus fees), regardless of the current reserve composition. This eliminates curve-induced slippage for trades within the oracle's price precision.

The trade-off is oracle dependence: if an oracle is compromised or goes stale, the pool cannot price correctly. ArcoraDEX addresses this with a multi-layer oracle defence — a two-source aggregation layer, a per-block price ratchet (`lastAcceptedPrice`), and a price cache with a deviation guard — described in §4.

### 3.2 Deposits and LP shares

Function: `deposit(address token, uint256 amount, uint256 minLpOut, uint256 deadline)`

A depositor transfers `amount` of `token` to the pool. The pool prices the deposit in USD using `_readAndGuardPrice(token)` (the guarded oracle price: a live oracle reading resolved through a cache-fallback / deviation guard and then a per-operation ratchet against `lastAcceptedPrice` — the full mechanism is described in §4). The USD value is:

```
usdIn = amount × price1e18[token] / 10^decimals[token]
```

LP shares minted are proportional to the NAV increase the deposit represents. The formula uses virtual offsets to prevent round-down-to-zero for small deposits and to provide inflation-attack defence:

```
-- follow-on deposit (supply > 0) --
lpMinted = usdIn × (totalSupply + VIRTUAL_SHARES) / (NAV + VIRTUAL_ASSETS)
```

where `VIRTUAL_SHARES = 1e6` and `VIRTUAL_ASSETS = 1` (both `internal constant` in `ArcoraDexPool` — compile-time fixed, not ABI-exposed).

**First deposit.** When `LP.totalSupply() == 0`, the formula simplifies to `usdIn × VIRTUAL_SHARES / VIRTUAL_ASSETS`. The first deposit must exceed `MINIMUM_LIQUIDITY` (1000 USD-units); on success, `MINIMUM_LIQUIDITY` LP shares are permanently burned to `DEAD_ADDRESS` (`0x000…dead`) to prevent the pool from returning to a zero-supply state (see §5 for the inflation-attack defence rationale).

After minting, `reserves[token]` is incremented and `lastMintAt[msg.sender]` is set to `block.timestamp`, initiating the minimum hold period (§5).

### 3.3 Swaps

Function: `swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline, address recipient)`

Both `tokenIn` and `tokenOut` are independently oracle-priced via `_readAndGuardPrice`. The gross output is computed by USD-normalised cross-token pricing:

```
usdValue = amountIn × pIn / 10^dIn
gross     = usdValue × 10^dOut / pOut
```

The swap fee is deducted from `gross`:

```
fee       = gross × swapFeeBps / BPS
amountOut = gross - fee
protFee   = fee × protocolFeeShareBps / BPS
```

The pool checks that `reserves[tokenOut] >= amountOut + protFee` before executing any token transfer (liquidity guard). The output is then transferred to `recipient`. The protocol's share of the fee (`protFee`) is credited to `protocolFeesAccrued[tokenOut]` and excluded from `reserves[tokenOut]`; the LP-retained portion of the fee (fee − protFee) implicitly increases NAV because the reserves net of `amountOut` are larger relative to outstanding LP supply.

The pool enforces a slippage parameter: if `amountOut < minOut`, the call reverts `InsufficientOutput`. A `deadline` parameter causes reversion after the specified timestamp.

### 3.4 Withdrawals

Function: `withdraw(address tokenOut, uint256 lpAmount, uint256 minTokenOut, uint256 deadline)`

LP shares are burned for a proportional share of reserves, denominated in a single chosen output token. The redemption value in USD is:

```
usdRedeemed = lpAmount × (NAV + VIRTUAL_ASSETS) / (totalSupply + VIRTUAL_SHARES)
```

A withdrawal fee is applied using the same `swapFeeBps` and `protocolFeeShareBps` parameters as swaps. The fee is taken from `usdRedeemed`; the remaining USD value is converted to `tokenOut` at the oracle price:

```
usdNet    = usdRedeemed × (BPS - swapFeeBps) / BPS
amountOut = usdNet × 10^dOut / priceOut
```

The LP-retained fee share again stays in reserves, growing NAV for remaining holders. The protocol's fee share is moved to `protocolFeesAccrued[tokenOut]`.

**Minimum hold.** Withdrawals are gated by a `MIN_HOLD_SECONDS` (`1 hours`) lock. The pool reverts `EarlyWithdraw` if `block.timestamp < lastMintAt[msg.sender] + MIN_HOLD_SECONDS`. This lock is propagated through LP transfers via `ArcoraDexLP._update()` → `ArcoraDexPool.notifyLPTransfer()`, so secondary recipients inherit the stricter of the two senders' unexpired holds (see §5).

### 3.5 Fee model

ArcoraDEX applies a single swap fee rate (`swapFeeBps`) expressed in basis points. The fee is split into two shares:

| Share | Variable | Destination |
|-------|----------|-------------|
| Protocol share | `protocolFeeShareBps` | Credited to `protocolFeesAccrued[tokenOut]`; withdrawn by governance via `withdrawProtocolFees` |
| LP share | `swapFeeBps - protocol portion` | Remains in `reserves[]`; accrues to all LP holders as NAV growth |

Fee caps enforced in the contract prevent governance from setting rates above safe bounds:

| Constant | Value | Meaning |
|----------|-------|---------|
| `MAX_SWAP_FEE_BPS` | `100` | Maximum swap fee: 1% of the gross output |
| `MAX_PROTOCOL_FEE_SHARE_BPS` | `2500` | Maximum protocol cut of the collected swap fee: 25% |

Both caps are hard-coded `uint16 public constant` values in `ArcoraDexPool`. Fee changes require an `onlyOwner` call (`setSwapFeeBps` / `setProtocolFeeShareBps`) routed through the 48-hour governance Timelock, providing advance notice before any rate change takes effect.

The only LP yield is the retained share of swap fees and withdrawal fees accruing as NAV growth. There is no additional token reward, no emission schedule, and no liquidity-mining programme.

## 4. Oracle Architecture

Oracle pricing is the core architectural bet in ArcoraDEX — and the largest attack surface. The oracle layer is a stack of four independent controls, each targeting a distinct failure mode: aggregator-level source divergence, pool-level cache poisoning, per-operation price movement, and rolling-window observability. This section describes each layer in precise contract terms.

### 4.1 Per-token `OracleAggregator`

Each of the seven listed tokens has its own `OracleAggregator` contract (`contracts/src/oracle/OracleAggregator.sol`) deployed and registered as the token's `usdOracle` in `ArcoraDexRegistry`. The aggregator wraps an immutable `PRIMARY` and an immutable `SECONDARY` feed, both `IChainlinkAggregator`-compatible, with a matching `DECIMALS` verified at construction (`DecimalsMismatch` reverts if they differ). The pool interacts with `OracleAggregator` identically to a direct Chainlink feed — it calls `latestRoundData()` and `decimals()` on the `usdOracle` address obtained from the registry.

**Normal mode (both sources live).** `latestRoundData()` calls `_tryRead(PRIMARY)` and `_tryRead(SECONDARY)`. Each `_tryRead` wraps the underlying feed in a `try`/`catch` and validates the returned tuple: positive `answer`, non-zero `updatedAt`, non-zero `roundId`, and `answeredInRound >= roundId` (round-completeness check). A revert or any validation failure returns `(false, 0, 0)`. When both sources return a valid reading, the aggregator checks divergence:

```
absDiff * 10_000 > minAns * maxDivergenceBps  →  revert SourcesDiverge(primary, secondary, capBps)
```

If the check passes, the aggregator returns the integer midpoint `(pAns + sAns) / 2` and the more-recent of the two `updatedAt` timestamps. The `mid` computation (sum of two positive `int256` values) cannot overflow in practice.

**Single-source degraded mode.** If exactly one source passes `_tryRead`, the aggregator returns that source's answer directly. No divergence cross-check is possible in this state — the second-opinion guard is inactive. The off-chain monitoring hook `sourceHealth()` returns `(primaryOk, secondaryOk)` so keepers can detect and alert on degraded-mode operation.

**Full failure.** If both sources fail `_tryRead`, the aggregator reverts `AllSourcesUnavailable`. This revert propagates upward until it is caught by the pool's `_readOracle` try/catch (see §4.2).

**Staleness enforcement.** The aggregator itself does not enforce a maximum answer age — it only validates round completeness and non-negativity. Per-token staleness bounds (`maxStaleSeconds`) are enforced downstream by the pool's `_readOracle`, using the value stored in `ArcoraDexRegistry.TokenInfo`.

### 4.2 Pool oracle read path: `_readOracle` and `lastValidPrice` cache

`_readOracle(address token)` (`ArcoraDexPool.sol` lines 98–135) is an `internal view` function — it reads state but never writes it. Its responsibilities are:

1. Fetch `TokenInfo` from `REGISTRY.tokenInfo(token)` to obtain `usdOracle`, `decimals`, `isActive`, and `maxStaleSeconds`. Revert `TokenNotActive` if `!info.isActive`.
2. Wrap `info.usdOracle.latestRoundData()` in a `try`/`catch`. A revert from any cause — `AllSourcesUnavailable`, `SourcesDiverge`, ABI mismatch, or a deactivated Chainlink feed — is caught and produces `isFresh = false`.
3. When the call succeeds, apply additional validation: `roundId != 0`, `answeredInRound >= roundId`, `updatedAt != 0`, `updatedAt <= block.timestamp`, `(block.timestamp - updatedAt) <= maxStaleSeconds`, and `answer > 0`. Any failure sets `isFresh = false`.
4. When all validations pass, wrap `info.usdOracle.decimals()` in a `try`/`catch` and normalise to a 1e18-scaled USD price. A revert from `decimals()` also sets `isFresh = false`.
5. Return `(price1e18, tokenDecimals, isFresh)` — no storage writes.

The `lastValidPrice[token]` cache is written by `_readUsdPrice1e18Mut(token)` (lines 142–179), the stateful wrapper used in every deposit, withdrawal, and swap execution. The cache is updated when `isFresh = true` and the cache-deviation guard (see §4.3) accepts the reading. When the oracle is stale, reverts, or the reading is rejected by the cache-deviation guard, `_readUsdPrice1e18Mut` returns the existing cache value rather than reverting. A `NoValidPrice(token)` revert fires only if the cache has never been seeded for that token (i.e., `lastValidPrice[token] == 0`, which can only occur before the first successful price read for a token). This architecture ensures that a reverting or stale oracle cannot brick the pool for an already-active token (see also INV-6 in `docs/audit/invariants.md`).

The companion `lastValidPriceAt[token]` timestamp records when the cache was last written; it is stored for off-chain diagnostics and is not used in any on-chain control path.

### 4.3 Cache-deviation guard

A fresh oracle reading is accepted by the cache only if it does not diverge from the existing cache by more than `maxOracleDeviationBps`. The check (inside `_readUsdPrice1e18Mut`, lines 150–164) is:

```
diff = |price1e18 - cached|
if diff * BPS > cached * maxOracleDeviationBps  →  isFresh = false
```

When the guard fires, the fresh reading is silently demoted to stale and the existing cache value is returned. This prevents a single compromised oracle push from poisoning the cache in one block, even if it passes all the per-round checks in `_readOracle`. The same guard logic is applied identically in `_readUsdPrice1e18View` (the view-only NAV reader) and inlined in `_readUsdPrice1e18WithGuard` (the quote path reader).

### 4.4 `lastAcceptedPrice` per-operation ratchet

`_readAndGuardPrice(address token)` (lines 310–328) is the function called by every mutating user operation (`deposit`, `withdraw`, `swap`). After obtaining the cache-guarded price from `_readUsdPrice1e18Mut`, it applies a second check against `lastAcceptedPrice[token]` — the price at which the previous user operation on this token executed:

```
diff = |price1e18 - prev|
if diff * BPS > prev * maxOracleDeviationBps  →  revert PriceDeviation(token, price1e18, prev, maxDevBps)
```

On success, `lastAcceptedPrice[token]` is overwritten with the accepted price (line 327), advancing the ratchet forward. This ratchet limits how far the executing price can move per user operation, regardless of how far the oracle has moved in the interim. An attacker attempting a slow-walk price-manipulation drain must therefore execute at least `100% / maxOracleDeviationBps` separate transactions to walk `lastAcceptedPrice` 100% from its initial value — providing off-chain monitoring time to detect and respond.

The ratchet can be bypassed by the owner via `syncAcceptedPrice(address token)` (`onlyOwner`, Timelock-gated, 48 h delay). This escape hatch is necessary for legitimate large market moves (e.g., TRYC or BRLC after a central-bank repricing) but requires a 48-hour governance proposal to execute.

### 4.5 `CumulativeDeviationGuard` — event-only rolling observability

`CumulativeDeviationGuard` (`contracts/src/oracle/CumulativeDeviationGuard.sol`) is a separate, standalone contract. It is **not** wired into any pool call path. Its purpose is to provide off-chain monitoring with a deterministic, on-chain record of cumulative price deviation.

Anyone — an off-chain keeper, a monitoring script, or an EOA — calls `record(address token, uint256 price1e18)` after an oracle update. The contract maintains a per-token tumbling-window state `(startPrice1e18, startTimestamp)`:

- If the window has expired (configurable via `setConfig`, `onlyOwner`; default 86 400 s / 24 h) or has not been initialised, the window is reset to the current observation.
- Within an active window, the deviation from the window anchor is computed as `|price1e18 - startPrice1e18| * 10_000 / startPrice1e18`. If this exceeds `maxCumulativeBps`, `CircuitBreakerTripped(token, deviationBps, timestamp)` is emitted. `PriceObserved(token, price1e18, timestamp)` is emitted on every call.

**There is no on-chain auto-pause in the current phase (P3).** An emitted `CircuitBreakerTripped` event is a signal to an off-chain monitor, which then decides whether to submit a transaction through the Pause Guardian Safe to call `pool.pause()`. The monitoring layer — not the contract — is the decision maker.

`record` is permissionless: any caller can invoke it with any price. This is intentional for P3 because the contract has no on-chain effect beyond emitting events. However, it means `CircuitBreakerTripped` events must be treated as untrusted hints by the off-chain monitor, which must re-validate the price against its own trusted feed before paging the Pause Guardian (per the NatSpec at `CumulativeDeviationGuard.sol` lines 26–30). If a future phase wires on-chain auto-pause to this contract, `record` must first be made keeper-only (tracked in `docs/audit/p5-tracking.md`).

The tumbling-window design is an explicit P3 MVP trade-off: it is cheaper to operate than a true rolling window but does not detect slow drift that stays just under the cap within each window and accumulates across window boundaries. A rolling multi-window detector is deferred to P5.

### 4.6 The three distinct deviation controls

Three separate parameters govern oracle deviation in ArcoraDEX. They are not redundant — each measures a different quantity at a different layer:

| Parameter | Location | What it measures | When it fires |
|-----------|----------|------------------|---------------|
| `OracleAggregator.maxDivergenceBps` | `OracleAggregator.sol` | Spread between **primary and secondary source prices** at the moment of the aggregator read | `revert SourcesDiverge` during `latestRoundData()` — before any price reaches the pool |
| `ArcoraDexRegistry.maxOracleDeviationBps` (per token) | `IArcoraDexRegistry.TokenInfo` | Jump from the **aggregator's output vs. the pool's `lastValidPrice` cache** (cache-deviation guard) and vs. **`lastAcceptedPrice`** (ratchet guard) per user operation | Cache-deviation guard: demotes the fresh price to stale (silent fallback to cache). Ratchet guard: `revert PriceDeviation` in `_readAndGuardPrice` and in `_readUsdPrice1e18WithGuard` |
| `CumulativeDeviationGuard.maxCumulativeBps` (per token) | `CumulativeDeviationGuard.sol Config` | Absolute deviation from the **tumbling-window anchor** over the configured window period | Event-only: `emit CircuitBreakerTripped` — no on-chain revert or pause |

`maxDivergenceBps` is a feed-spread control: it answers "are both of my oracle sources telling the same story right now?" `maxOracleDeviationBps` is a pool-state control: it answers "is the current oracle output too far from the price the pool last accepted?" `maxCumulativeBps` is a monitoring control: it answers "has cumulative drift over the window exceeded the threshold an operator cares about?"

**Deployed configuration** (post-P3 Timelock batch):

| Token | Aggregator `maxDivergenceBps` | Registry `maxOracleDeviationBps` | Guard `maxCumulativeBps` | Guard window |
|-------|-------------------------------|----------------------------------|--------------------------|--------------|
| USDC  | 50  | 200  | 200 | 86 400 s (24 h) |
| USDT  | 50  | 200  | 200 | 86 400 s (24 h) |
| PYUSD | 50  | 200  | 200 | 86 400 s (24 h) |
| DAI   | 50  | 200  | 200 | 86 400 s (24 h) |
| EURC  | 100 | 200  | 300 | 86 400 s (24 h) |
| TRYC  | 200 | 200  | 500 | 86 400 s (24 h) |
| BRLC  | 200 | 200  | 500 | 86 400 s (24 h) |

TRYC and BRLC carry wider divergence caps (200 bps vs. 50 bps for USD stables) to accommodate the higher natural volatility of their reference currencies. Their Registry `maxOracleDeviationBps` was reduced from 5 000 bps to 200 bps by the P3 Timelock batch (operations 8–9 of that batch) to close finding #1.

## 5. Security Model

The P1–P3 hardening programme addressed eleven findings (eight from an external audit plus three economic-attack vectors identified in a follow-up internal pass). This section describes the specific mitigations deployed against the two highest-impact attack classes: economic attacks on LP accounting and oracle-manipulation attacks on pricing. Residual risks that persist after these mitigations are documented separately in §7.

### 5.1 Economic-attack defences

#### First-depositor inflation attack (finding #A, CRITICAL → Fixed, P1)

**The attack.** Classic ERC4626-style inflation: the first depositor receives a minimal number of LP shares, then donates a large token balance directly to the pool contract, inflating the NAV without minting LP. Any subsequent depositor's calculated LP share rounds to zero due to the low `totalSupply / NAV` ratio, causing their tokens to be permanently locked in the pool with no corresponding LP receipt.

**Why it does not apply to ArcoraDEX.**

Two independent defences are active simultaneously:

1. **Structural donation immunity via `reserves[]`.** The pool does not read `token.balanceOf(address(this))` anywhere in its accounting. NAV is computed solely from the explicit `reserves[token]` mapping, which is incremented only by `deposit` and `swap` calls. Tokens transferred directly to the pool address — a "donation" — update the ERC20 balance of the pool contract but do not update `reserves[token]`, so NAV is unchanged and no LP inflation is possible from this vector (see INV-5 in `docs/audit/invariants.md`).

2. **Virtual-shares offset.** The LP mint formula uses `VIRTUAL_SHARES = 1e6` and `VIRTUAL_ASSETS = 1` (`internal constant` in `ArcoraDexPool`, compile-time fixed):

   ```
   lpMinted = usdIn × (totalSupply + VIRTUAL_SHARES) / (NAV + VIRTUAL_ASSETS)
   ```

   The `VIRTUAL_SHARES` term (10⁶) dominates the numerator when `totalSupply` is small, preventing round-down-to-zero for any positive `usdIn` regardless of the `totalSupply / NAV` ratio. The symmetric formula is applied in `withdraw`. This ERC4626-style offset is an independent defence against LP-math inflation attacks, operating correctly even if the `reserves[]` architecture is somehow bypassed.

As additional defense-in-depth, **`MINIMUM_LIQUIDITY` permanent burn** is applied on the first deposit: `MINIMUM_LIQUIDITY = 1000` LP shares are minted to `DEAD_ADDRESS` (`address(0xdead)`) and can never be burned (the pool's `withdraw` burns only from `msg.sender`, never from `0xdead`). This creates a permanent non-zero LP floor that, combined with the virtual-shares offset, makes the first-deposit branch economically self-defeating for an attacker: the attacker must sacrifice at least 1 000 USD-wei of LP to initiate any inflation attempt, and the virtual-shares formula removes the incentive regardless.

#### JIT/MEV sandwich attack (finding #B, HIGH → Fixed, P1)

**The attack.** A block builder or searcher can observe a pending keeper oracle update, deposit just before it, and withdraw immediately after, capturing the NAV delta (the difference between the pre-update and post-update pool valuation) with effectively zero capital at risk. Because `totalReservesUSD()` always reads the current oracle, a deposit and an immediate withdrawal in adjacent transactions within a single MEV bundle would perfectly straddle the oracle price move.

**Fix — two layers:**

1. **1-hour minimum hold (`MIN_HOLD_SECONDS = 1 hours`).** `deposit` writes `lastMintAt[msg.sender] = block.timestamp` at line 405 of `ArcoraDexPool.sol`. `withdraw` enforces `block.timestamp >= lastMintAt[msg.sender] + MIN_HOLD_SECONDS`, reverting `EarlyWithdraw(unlockAt, block.timestamp)` on violation. One hour covers at least two keeper cycles (the oracle keeper fires every ~30 minutes), making an atomic same-block deposit-withdraw impossible and multi-bundle sandwiching economically unattractive.

2. **LP transfer hook — closing the bypass.** Without additional protection, an attacker could deposit to wallet A (starting the hold clock on A), transfer the LP tokens to wallet B (which has `lastMintAt[B] == 0`), and withdraw immediately from B — bypassing A's hold. This bypass is closed by `ArcoraDexLP._update`, which calls `IArcoraDexPool(MINTER).notifyLPTransfer(from, to)` on every non-mint, non-burn transfer. `notifyLPTransfer` (lines 636–644 of `ArcoraDexPool.sol`) propagates the sender's lock to the recipient:

   ```
   if (lastMintAt[from] > lastMintAt[to]) {
       lastMintAt[to] = lastMintAt[from];
   }
   ```

   The recipient inherits the stricter (later) of the two timestamps. A fresh wallet receiving LP from a recent depositor cannot withdraw until the original depositor's 1-hour window has elapsed. The hold clock is reset forward on a new deposit: if the receiving wallet subsequently makes its own deposit, `lastMintAt[to]` is overwritten with the new `block.timestamp`, starting a fresh 1-hour window from that point.

### 5.2 Oracle-attack defences

The oracle layer's four-control architecture (described in detail in §4) provides the following specific defences against oracle manipulation:

**Staleness bounds (`maxStaleSeconds` per token).** `_readOracle` validates `(block.timestamp - updatedAt) <= info.maxStaleSeconds` as part of its per-round validation. A feed that has not been updated within the staleness window produces `isFresh = false` and the pool falls back to `lastValidPrice[token]`. Default staleness limits: 3 600 s for USDC/USDT/PYUSD/DAI, 14 400 s for EURC, 86 400 s for TRYC/BRLC — calibrated to the expected heartbeat of each feed.

**Source diversity and divergence cap.** Each token's oracle is an `OracleAggregator` backed by two independent feeds. `maxDivergenceBps` (50 bps for USD stables, up to 200 bps for TRYC/BRLC) constrains how far the primary and secondary sources can disagree before the aggregator reverts `SourcesDiverge` rather than returning an average. A single compromised oracle key can control only one source; the divergence check catches a unilateral price push and prevents it from reaching the pool.

**Revert tolerance (finding #P3-R, Fixed, P3).** Both `info.usdOracle.latestRoundData()` and `info.usdOracle.decimals()` are wrapped in `try`/`catch` inside `_readOracle`. Any revert — from `AllSourcesUnavailable`, `SourcesDiverge`, ABI mismatch, or a deactivated feed — collapses to `isFresh = false` and the pool falls back to the last cached price. A reverting oracle cannot brick the pool for an already-active token.

**Cache-deviation guard.** Even when a fresh oracle reading passes all per-round checks, a single-block price spike from a compromised aggregator is blocked by the cache-deviation guard in `_readUsdPrice1e18Mut`: a fresh reading that deviates more than `maxOracleDeviationBps` from `lastValidPrice[token]` is demoted to stale. The cache cannot be poisoned in a single block, regardless of what the aggregator returns.

**Per-operation ratchet (`lastAcceptedPrice`).** `_readAndGuardPrice` enforces that each user operation executes at a price within `maxOracleDeviationBps` (200 bps for all tokens post-P3) of the previous accepted price. An attacker attempting to walk the accepted price toward a manipulated target must submit many sequential transactions, each within the cap, giving off-chain monitoring time to detect abnormal behaviour and invoke the Pause Guardian Safe.

**Cumulative monitoring (`CumulativeDeviationGuard`).** The off-chain keeper calls `record` after each oracle update. Exceeding `maxCumulativeBps` cumulative deviation within the 24-hour tumbling window emits `CircuitBreakerTripped`, which the monitoring layer treats as a signal to evaluate a pause. This is human-in-the-loop for P3; on-chain auto-pause is deferred to P5 (and will require making `record` keeper-only before wiring).

These mitigations are designed to reduce the attack surface of oracle manipulation to a class of multi-transaction, colluding-source attacks that require sustained cooperation between at least two compromised oracle keys and provide meaningful detection windows. They do not eliminate oracle risk entirely; §7 carries the residual risk disclosures.

## 6. Governance & Operations

### 6.1 Ownership model

`ArcoraDexPool` and `ArcoraDexRegistry` both inherit OpenZeppelin's `Ownable2Step`. Their owner is the `TimelockController` (`0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83`, `getMinDelay() = 172800 s = 48 hours`), which is in turn administered by the Governance Safe (`0x715f669D79Cc72d6685F8724c0B86f7B53d7e624`, 3/5 multisig).

This means every `onlyOwner` function on the Pool and the Registry — fee mutations, oracle changes, token listing, `unpause`, and fee withdrawal — requires a Governance Safe proposal to be scheduled through the Timelock and then survive the 48-hour delay before any address can execute it. The executor role on the Timelock is open: once the delay has elapsed, any EOA may call `execute`.

The Governance Safe may also cancel a scheduled proposal at any time before execution, via `TimelockController.cancel()`.

### 6.2 Pause Guardian

A second multisig, the Pause Guardian Safe (`0x39500e45935f36CfcEb826590aaE97226Ac6640D`, 2/3 threshold), holds the `pauseGuardian` address in `ArcoraDexPool.pauseGuardian`. It operates on a separate, smaller key set from the Governance Safe.

The Pool defines the modifier used by `pause()` at lines 83–86 of `ArcoraDexPool.sol`:

```solidity
modifier onlyOwnerOrGuardian() {
    if (msg.sender != owner() && msg.sender != pauseGuardian) revert NotAuthorized();
    _;
}
```

`pause()` (`ArcoraDexPool.sol` line 616) is gated by `onlyOwnerOrGuardian`, meaning either the Timelock (via a Governance Safe proposal) or the Pause Guardian Safe can freeze the pool. Because the Pause Guardian Safe bypasses the Timelock, an emergency pause takes effect within a single block — no 48-hour delay.

`unpause()` (`ArcoraDexPool.sol` line 626) is gated by `onlyOwner` only, as noted in the NatSpec:

> Intentionally owner-only (the governance Timelock). The Pause Guardian Safe keeps its fail-safe pause() capability, but a compromised guardian must not be able to un-protect a pool the owner deliberately paused during an incident. Only the governance Timelock — after deliberate proposal + delay — may restart.

The **pause/unpause asymmetry** is a deliberate security property: a compromised Pause Guardian Safe (2 of 3 keys) can halt deposits and withdrawals instantly but cannot restart the pool. Restarting requires a full 48-hour Governance Timelock cycle, which gives the community and remaining governance keyholders a full response window.

Changing the `pauseGuardian` address (`setPauseGuardian`) is `onlyOwner` and therefore also Timelock-gated.

### 6.3 Oracle feed and aggregator ownership

The seven primary `MockChainlinkFeedV2` instances, the seven `OracleAggregator` contracts, the seven secondary feeds, and the `CumulativeDeviationGuard` are all owned directly by the Governance Safe — **without** an intermediate Timelock.

This deliberate exception enables a compromised oracle keeper EOA to be rotated out in a single Safe multisig transaction, without the 48-hour delay that governs all Pool and Registry actions. The accepted trade-off is described in R4 (§7): a compromised 3/5 Governance Safe can rotate feed writers instantly. The compensating bound is that `Registry.setOracle` — which governs whether the Pool actually uses any given oracle address — remains Timelock-gated with a 48-hour delay.

> **Current testnet deployment note.** On the Arc testnet deployment as of this writing, the secondary-feed `writer` migration is a pending downstream operational task (see `docs/rollouts/2026-05-14-phase3-oracle.md`, "Downstream tasks"). The seven secondary feeds were deployed with the deployer EOA as their initial writer; the Governance Safe has not yet called `setWriter(keeperEOA)` on each feed. Until those calls are made, the secondary feeds hold their deploy-time prices and are not being driven by the keeper. As a result, the `OracleAggregator` instances on the current testnet are not yet operating on two independently-updated sources — the two-source divergence cross-check is architecturally present but not yet exercised on live keeper data. This is a known pending operational step, not an architectural change; the design is two-source and the migration will complete before any mainnet deployment.

### 6.4 Parameter-change process

A standard governance action follows this path:

1. Three of the five Governance Safe signers sign a Safe transaction calling `TimelockController.schedule(target, value, calldata, predecessor, salt, minDelay)`.
2. The proposal is publicly visible on-chain for at least 48 hours.
3. After the delay, any address calls `TimelockController.execute(target, value, calldata, predecessor, salt)`.

The Governance Safe may cancel the scheduled operation at any time before execution.

For oracle rotation (`setOracle`), token listing (`listToken`), or deviation-cap changes (`setDeviation`), the same flow applies with a 48-hour delay. The off-chain operations plan recommends a seven-day public announcement period before scheduling `setOracle` or `listToken` on mainnet, on top of the 48-hour on-chain delay.

### 6.5 Emergency-pause path

When the off-chain monitor detects a `CircuitBreakerTripped` event or observes abnormal price behaviour, the Pause Guardian Safe signs `pool.pause()` — bypassing the Timelock — and the pool is frozen within one block. All deposits, withdrawals, and swaps revert with `PoolPaused` while frozen; oracle state and reserves remain intact.

After the incident is diagnosed, the Governance Safe proposes `pool.unpause()` through the Timelock. The pool can resume operation once the 48-hour delay elapses and the proposal is executed. This gives the team a minimum 48-hour window to investigate before re-opening the pool.

### 6.6 Role and permission table

| Action | Callable by | Path | Effective delay |
|--------|-------------|------|-----------------|
| `setSwapFeeBps` | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `setProtocolFeeShareBps` | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `withdrawProtocolFees` | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `setPauseGuardian` | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `syncAcceptedPrice` | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `listToken` | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `setOracle` | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `setDeviation` | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `setMaxStaleSeconds` | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `deactivateToken` / `reactivateToken` | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `transferOwnership` / `acceptOwnership` | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `pause()` — via Timelock | Owner (Timelock) | Governance Safe → Timelock | 48 h |
| `pause()` — emergency | Pause Guardian Safe | Direct Safe tx | Instant (< 1 block) |
| `unpause()` | Owner (Timelock) only | Governance Safe → Timelock | 48 h |
| `setWriter` (feeds) | Governance Safe direct | Direct Safe tx | Instant |
| `setMaxDivergenceBps` (aggregators) | Governance Safe direct | Direct Safe tx | Instant |
| `setConfig` (guard) | Governance Safe direct | Direct Safe tx | Instant |

### 6.7 Deployed addresses

| Contract | Address |
|----------|---------|
| ArcoraDexPool V3 | `0x1ce1ef94e7ebe70727bd69003d61a3f0c9a331bc` |
| ArcoraDexRegistry V3 | `0x9914436e5245bf3c0d4d4338e0a8b8f5ab5505ab` |
| ArcoraDexLP V3 | `0x17B47173C457069E53B3B75Ef42773041B79523e` |
| TimelockController | `0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83` |
| Governance Safe (3/5) | `0x715f669D79Cc72d6685F8724c0B86f7B53d7e624` |
| Pause Guardian Safe (2/3) | `0x39500e45935f36CfcEb826590aaE97226Ac6640D` |

All addresses verified on Arc testnet (chainId 5042002). Mainnet addresses are not yet assigned.

## 7. Risk Disclosures

This section discloses the risks that the ArcoraDEX team has reviewed and consciously accepts for the v1 mainnet launch. The authoritative source is `docs/audit/known-acceptable-risks.md`. For each risk the disclosure states: what the risk is, why it is accepted for v1, and the compensating control that bounds its impact.

Developers, auditors, and liquidity providers should treat this section as the accurate picture of where the protocol depends on trusted parties, off-chain processes, or design trade-offs, rather than purely on code.

### R1 — Oracle dependence (protocol correctness rests on the feeds)

**Risk.** ArcoraDEX prices every swap from external oracle feeds rather than from an on-chain reserve ratio. If a feed delivers incorrect prices — whether through compromise, staleness, or a diverging primary/secondary pair — the pool will execute swaps at wrong rates, potentially draining reserves toward the token with the inflated price. This is not a marginal concern: oracle accuracy is the foundational assumption on which the entire pricing model rests.

**Why accepted for v1.** There is no oracle-free design that delivers the pool's stated goal — eliminating curve-induced slippage for pegged assets. The choice of an oracle-priced model is a deliberate trade-off: it eliminates slippage at the cost of introducing oracle-dependence. Accepting oracle risk is the product design.

**Compensating controls.** Four independent controls are deployed (described in detail in §4): dual-source `OracleAggregator` with a divergence check (`SourcesDiverge` revert at `maxDivergenceBps`); a `lastValidPrice` cache with a per-block deviation guard that prevents cache poisoning in a single block; a `lastAcceptedPrice` per-operation ratchet that limits how far the executed price can advance per transaction (`maxOracleDeviationBps = 200 bps` for all tokens post-P3); and the `CumulativeDeviationGuard` event stream, which gives off-chain monitors an on-chain record of cumulative drift. Together these controls reduce the worst-case oracle manipulation from a single-transaction drain to a slow multi-transaction walk requiring sustained cooperation between at least two compromised oracle keys, providing meaningful detection windows.

**Residual exposure.** In the current testnet configuration, the same keeper EOA pushes both the primary and secondary feed for each token. A single compromised key therefore bypasses the two-source divergence check. On mainnet, primary and secondary are intended to be independent (Chainlink primary, Pyth/DEX TWAP secondary with a different key), but that independence is deferred to P5. Until then, the oracle layer provides defence-in-depth but not two-party compromise resistance.

---

### R2 — Liquidity-thin behaviour at very low TVL

**Risk.** When the pool has very low total NAV, the LP minting formula can round small deposits to zero shares. If `usdIn` is small relative to the current NAV-to-supply ratio, `lpMinted` truncates to zero in integer arithmetic, and the depositor's tokens are accepted but zero LP is issued, locking a trivially small token amount. A near-empty pool is a poor experience for small follow-on depositors.

**Why accepted for v1.** The virtual-offset pattern (`VIRTUAL_SHARES = 1e6`, `VIRTUAL_ASSETS = 1`) deployed in P1 to fix the first-depositor inflation attack also addresses rounding as a side-effect. The residual risk is confined to deposits where `usdIn` is below a few wei of USD value — economically negligible for any real depositor. Fully eliminating rounding in fixed-point math would require a different accounting model.

**Compensating controls.** With `VIRTUAL_SHARES = 1e6`, any deposit where `usdIn >= 1` is guaranteed to mint at least one LP unit. The `FirstDepositTooSmall` revert enforces a minimum bootstrap deposit of `MINIMUM_LIQUIDITY` USD-units. Combined with the `MINIMUM_LIQUIDITY` permanent burn to `DEAD_ADDRESS` on the first deposit, the pool cannot return to a zero-supply state that would make follow-on deposits susceptible to zero-share rounding.

---

### R3 — Centralized initial liquidity

**Risk.** At mainnet launch the founding LP(s) will hold most or all of the `ADEX-LP` supply. A single large LP exiting rapidly could drain the pool, leaving smaller LPs with a thin market and materially higher slippage on withdrawal. This is a centralization risk at the liquidity layer, not a smart-contract vulnerability.

**Why accepted for v1.** A trust-minimized bootstrapping mechanism — such as a bonding curve or a vesting lock on founding LP tokens — would add non-trivial audit surface before the initial deployment. The standard industry approach is to start with committed founding LPs under off-chain commercial terms and migrate toward a more decentralized LP incentive model as TVL grows.

**Compensating controls.** Founding LPs are subject to the same `MIN_HOLD_SECONDS = 1 hours` lock as all other depositors — a mass exit cannot be atomic. The LP transfer hook (`ArcoraDexLP._update` → `ArcoraDexPool.notifyLPTransfer`) propagates the lock to any LP token recipient, preventing a rapid exit via an intermediary fresh wallet. The P5 mainnet-operations plan calls for founding LP commitments, a TVL-floor agreement, and a decentralized LP incentive program to dilute initial concentration over time.

---

### R4 — Governance-trust assumptions (3/5 Safe compromise, bounded by 48-hour Timelock)

**Risk.** The Governance Safe is a 3/5 Safe multisig. An attacker who compromises three of the five signing keys can schedule any `onlyOwner` action on `ArcoraDexPool` and `ArcoraDexRegistry`: rotating oracles to attacker-controlled feeds, changing deviation caps, withdrawing protocol fees, or transferring ownership. Additionally, the Governance Safe holds direct (non-Timelock) ownership of the seven oracle feeds and seven `OracleAggregator` contracts, so a compromised Governance Safe can rotate feed writers instantly.

**Why accepted for v1.** The 3/5 threshold is a deliberate trade-off between operational liveness and security. A higher threshold (4/5 or 5/5) would make coordinated governance impractical for frequent, low-stakes operations. Timelock-fronted multisig governance is the standard approach at this scale. Key procurement requirements (hardware wallets per signer) are specified in the P2 governance spec.

**Compensating controls.** Every `onlyOwner` function on the Pool and Registry passes through the `TimelockController` with `getMinDelay() = 48 hours`. A malicious proposal is publicly visible on-chain for 48 hours before it can execute; any watcher can alert the community and the remaining keyholders can cancel via `TimelockController.cancel()`. The Pause Guardian Safe (2/3, separate key set) can freeze the pool instantly while the community organises a response. On mainnet, the off-chain governance commitment includes off-chain announcement periods for high-impact actions such as `setOracle` and `listToken`.

---

### R5 — Permissionless `CumulativeDeviationGuard.record`

**Risk.** `CumulativeDeviationGuard.record(address token, uint256 price1e18)` is unauthenticated — any caller may invoke it with any price value. An adversary can therefore: anchor the tumbling window at a favourable or unfavourable price; spam calls to force window resets; or emit spurious `CircuitBreakerTripped` events to cause alert fatigue in the off-chain monitor. If the off-chain monitor were wired to auto-pause on trip events, a griever could pause the pool at will.

**Why accepted for v1.** `record` has no on-chain state effect beyond updating the per-token window state and emitting events. Nothing on-chain — no pause, no price change, no reserve mutation — is gated on the guard's output. Adding a keeper allowlist now would introduce a new failure mode (a stuck allowlist that prevents legitimate keepers from recording) with no functional benefit in the current implementation. Making `record` keeper-only is a P5 task, conditional on on-chain auto-pause being wired to the guard at that time.

**Compensating controls.** The contract NatSpec explicitly documents the trust boundary: the off-chain monitor must treat `PriceObserved` and `CircuitBreakerTripped` as untrusted hints and re-validate the price against its own trusted feed before paging the Pause Guardian. No on-chain action can be triggered by `record` alone. When on-chain auto-pause is wired in P5, `record` must be made keeper-only at that time (tracked in `docs/audit/p5-tracking.md`).

---

### R6 — Tumbling (not rolling) deviation window

**Risk.** `CumulativeDeviationGuard` measures deviation against the first observation of each 24-hour tumbling window. A slow, sustained price drift that stays just below `maxCumulativeBps` within each window is not detected across window boundaries. A compromised keeper could push `maxCumulativeBps − 1` bps of drift per window, indefinitely, without ever tripping the circuit breaker.

**Why accepted for v1.** The tumbling-window approach was deliberately chosen as a P3 MVP: it catches acute intra-window spikes — the dominant attack vector — while keeping the implementation simple and cheap. A true rolling-window detector requires either a circular buffer (expensive storage) or a two-pass checkpoint scheme (more complex and more audit surface). A rolling or multi-window detector is a P5 enhancement.

**Compensating controls.** The `maxOracleDeviationBps = 200 bps` per-transaction cap on `lastAcceptedPrice` limits how far the accepted price can drift in a single oracle update, regardless of the tumbling window. A cross-window drift is also a cross-transaction drift, giving the off-chain monitor many opportunities to observe and alert. The `OracleAggregator`'s two-source divergence check (`maxDivergenceBps = 200 bps` for TRYC/BRLC) means a single compromised keeper cannot push the primary source more than 200 bps without the honest secondary source triggering `SourcesDiverge`.

---

### R7 — Fee-collector role not separated from governance ownership

**Risk.** `withdrawProtocolFees(address token, uint256 amount, address to)` in `ArcoraDexPool` is `onlyOwner`, and the owner is the `TimelockController`. The protocol-fee recipient role is not separated from governance ownership. A malicious governance majority could pass a proposal to redirect accrued protocol fees to an attacker-controlled address.

**Why accepted for v1.** Separating the fee-collector into a distinct multisig was explicitly called out as out-of-scope for P2 in the governance design spec and the mainnet-readiness roadmap. The separation would require a dedicated fee-withdrawal module and adds governance surface before the Spearbit review. This is a tracked P5 item.

**Compensating controls.** `withdrawProtocolFees` is `onlyOwner`; the owner is the Timelock with `getMinDelay() = 48 hours`. Any proposal to withdraw fees to an attacker-controlled address is publicly visible on-chain for 48 hours before it executes, and any `TimelockController.cancel()` call from the Governance Safe can stop it. The affected funds are accrued protocol revenue only (bounded by `protocolFeeShareBps ≤ 2500 bps` of the `swapFeeBps ≤ 100 bps` fee); they do not represent LP principal or user deposits.

---

### R8 — Pre-bug-bounty exposure window

**Risk.** ArcoraDEX v1 will not have an active Immunefi bug-bounty program at the time of mainnet launch. Researchers who discover post-audit vulnerabilities before the bounty program launches have no formal, incentivized channel for responsible disclosure. This creates a window between mainnet deployment and Immunefi program launch during which a researcher might choose exploit-over-disclose.

**Why accepted for v1.** Setting up an Immunefi program requires a finalized mainnet deployment (contract addresses, TVL commitments, reward-tier funding). The program cannot be meaningfully launched before the Spearbit audit is complete and the code is frozen for mainnet. The unavoidable sequence is: Spearbit audit → mainnet deploy → Immunefi launch. Deploying unaudited code or launching a bounty against an undeployed codebase are both worse outcomes.

**Compensating controls.** The Spearbit audit precedes mainnet deployment; unaudited code does not go live. An informal responsible-disclosure contact is published in the repository and the frontend at mainnet launch. TVL during the pre-bounty window is expected to be low (founding LP bootstrap only), limiting the incentive for exploit-over-disclose. Immunefi program launch is a first-week P5 deliverable, covering Pool, Registry, OracleAggregator, and the governance contracts.

---

**Summary table**

| ID | Risk category | Compensating control | P5 resolution |
|----|---------------|---------------------|---------------|
| R1 | Oracle dependence | 4-layer oracle defence; 200 bps per-op ratchet | Independent primary/secondary sources on mainnet |
| R2 | Liquidity-thin rounding | `VIRTUAL_SHARES = 1e6`; min-liquidity bootstrap | No change needed |
| R3 | Centralized initial liquidity | 1 h min-hold lock; LP transfer hook; founding LP commitments | Decentralized LP incentive program |
| R4 | Governance multisig compromise | 48 h Timelock; Pause Guardian instant freeze | Hardware wallets; mainnet signer onboarding |
| R5 | Permissionless `record` | Events-only; monitor re-validates before paging | Keeper allowlist when auto-pause is wired |
| R6 | Tumbling window blind spot | 200 bps per-op cap; two-source divergence check | Rolling-window or multi-window detector |
| R7 | Fee-collector not separated | 48 h Timelock on `withdrawProtocolFees`; cancel path | Dedicated fee-collector multisig module |
| R8 | Pre-bounty exposure window | Audit precedes launch; informal disclosure channel | Immunefi launch first week post-mainnet |

## 8. Audit & Roadmap

<!-- section 8 content — Task 5 -->

## 9. Parameters & Addresses

<!-- section 9 content — Task 5 -->

## 10. References

<!-- section 10 content — Task 5 -->
