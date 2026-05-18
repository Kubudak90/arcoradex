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

LP share minting and redemption use virtual offsets (`VIRTUAL_SHARES = 1e6`, `VIRTUAL_ASSETS = 1`) in an ERC4626-style formula. These offsets guarantee that any non-zero deposit mints at least one LP share (preventing round-down-to-zero on small follow-up deposits) and provide belt-and-suspenders defence against inflation attacks on the LP math, independently of the `reserves[]` structural protection above.

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

A depositor transfers `amount` of `token` to the pool. The pool prices the deposit in USD using `_readAndGuardPrice(token)` (the oracle price, after passing the deviation ratchet check — see §4). The USD value is:

```
usdIn = amount × price1e18[token] / 10^decimals[token]
```

LP shares minted are proportional to the NAV increase the deposit represents. The formula uses virtual offsets to prevent round-down-to-zero for small deposits and to provide inflation-attack defence:

```
-- follow-on deposit (supply > 0) --
lpMinted = usdIn × (totalSupply + VIRTUAL_SHARES) / (NAV + VIRTUAL_ASSETS)
```

where `VIRTUAL_SHARES = 1e6` and `VIRTUAL_ASSETS = 1`.

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

<!-- section 4 content — Task 3 -->

## 5. Security Model

<!-- section 5 content — Task 3 -->

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
