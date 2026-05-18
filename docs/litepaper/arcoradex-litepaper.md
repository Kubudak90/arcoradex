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

3. **`MINIMUM_LIQUIDITY` permanent burn.** On the first deposit, `MINIMUM_LIQUIDITY = 1000` LP shares are minted to `DEAD_ADDRESS` (`address(0xdead)`) and can never be burned (the pool's `withdraw` burns only from `msg.sender`, never from `0xdead`). This creates a permanent non-zero LP floor that, combined with the virtual-shares offset, makes the first-deposit branch economically self-defeating for an attacker: the attacker must sacrifice at least 1 000 USD-wei of LP to initiate any inflation attempt, and the virtual-shares formula removes the incentive regardless.

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

<!-- section 6 content — Task 4 -->

## 7. Risk Disclosures

<!-- section 7 content — Task 4 -->

## 8. Audit & Roadmap

<!-- section 8 content — Task 5 -->

## 9. Parameters & Addresses

<!-- section 9 content — Task 5 -->

## 10. References

<!-- section 10 content — Task 5 -->
