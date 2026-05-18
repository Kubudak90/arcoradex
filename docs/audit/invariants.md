# ArcoraDEX — Protocol Invariants

The following invariants are properties the ArcoraDEX protocol is designed to enforce at all times. Every statement below has been verified against the production source code before being written. Conditions, exceptions, and known limitations are stated explicitly. Auditors should treat these as attack targets: an input sequence that violates any invariant is a valid finding.

---

## INV-1: Token balance equals reserves plus protocol fees (the balance identity)

**Formal statement.** For every active token `t`:

```
IERC20(t).balanceOf(pool) == reserves[t] + protocolFeesAccrued[t]
```

**Rationale.** `reserves[t]` records LP-attributed pool assets. `protocolFeesAccrued[t]` records accrued protocol fees that have not yet been swept. Every token entry into the pool goes through `deposit` or `swap` (which add to `reserves[t]`) or is captured as protocol fees during `withdraw` / `swap` (which subtract from `reserves[t]` by exactly `amountOut + protFee`, then add `protFee` back into `protocolFeesAccrued[t]`, and transfer `amountOut` out). A direct `IERC20.transfer` to the pool address bypasses `reserves[]` and sits as an orphan in the ERC20 balance that no LP holds a claim against; the identity still holds because neither `reserves[t]` nor `protocolFeesAccrued[t]` changes. `withdrawProtocolFees` decrements `protocolFeesAccrued[t]` and transfers the tokens out in lockstep, preserving the identity.

**Condition / exception.** The identity can be momentarily broken mid-transaction by a reentrant call, but `nonReentrant` on all mutating public functions structurally prevents reentrancy. External ERC20 tokens with fee-on-transfer or deflationary mechanisms would break this identity on the deposit side; ArcoraDEX does not whitelist such tokens on testnet but has no on-chain enforcement preventing their listing.

**Test coverage.** `contracts/test/ArcoraDexPool.invariant.t.sol` — `invariant_balance_equals_reserves_plus_fees` (Foundry invariant, runs across random `deposit` / `withdraw` / `swap` sequences via `PoolHandler`).

---

## INV-2: Protocol fees do not exceed contract token balance

**Formal statement.** For every token `t`:

```
protocolFeesAccrued[t] <= IERC20(t).balanceOf(pool)
```

**Rationale.** By INV-1, `balanceOf(pool) = reserves[t] + protocolFeesAccrued[t]`. Since `reserves[t] >= 0`, fees can never exceed the balance. The `withdrawProtocolFees` function enforces `amount <= protocolFeesAccrued[t]` before releasing any tokens, keeping the decrement and the transfer in sync.

**Note.** The stronger claim `protocolFeesAccrued[t] <= reserves[t]` is NOT enforced and can be false. Protocol fees accumulate in `protocolFeesAccrued[t]` while `reserves[t]` can be drawn down independently (e.g. after heavy withdrawals that drain one token). Auditors should not assume parity between the two mappings.

**Test coverage.** `contracts/test/ArcoraDexPool.invariant.t.sol` — `invariant_fees_le_balance`.

---

## INV-3: LP total supply and NAV are jointly zero or jointly nonzero

**Formal statement.**

```
LP.totalSupply() == 0  <=>  totalReservesUSD() == 0
```

**Rationale.** Before the first deposit, both sides are zero. On the first deposit, the pool mints `MINIMUM_LIQUIDITY` LP to `0xdead` and then mints the depositor's share, so `totalSupply > 0`; simultaneously `reserves[token] += amount` and `totalReservesUSD() > 0`. Because every deposit adds both LP and NAV, and every withdrawal burns LP proportional to the NAV it redeems, the two sides can only reach zero together. A withdrawal that burns all LP would also drain all reserves (subject to rounding and the protocol-fee residual), but the `MINIMUM_LIQUIDITY` locked in `0xdead` can never be burned, so in practice `totalSupply >= MINIMUM_LIQUIDITY` and `totalReservesUSD > 0` after the first deposit are both permanent.

**Condition.** Oracle pricing is required to compute `totalReservesUSD()`; if all prices revert and no cache is seeded, the view reverts rather than returning 0, so the bi-conditional is observable only when prices are resolvable.

**Test coverage.** `contracts/test/ArcoraDexPool.invariant.t.sol` — `invariant_supply_nav_link`.

---

## INV-4: MINIMUM_LIQUIDITY is permanently locked after first deposit

**Formal statement.** After any first deposit has occurred:

```
LP.balanceOf(0xdead) >= MINIMUM_LIQUIDITY   (i.e. >= 1000)
```

where `MINIMUM_LIQUIDITY = 1000` (defined in `ArcoraDexPool`).

**Rationale.** On the first deposit (`LP.totalSupply() == 0` at entry), the pool calls `LP.mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY)` sending exactly 1000 LP units to `address(0xdead)`. `ArcoraDexLP.burn` requires `msg.sender == MINTER` (the pool), and the pool's `withdraw` function calls `LP.burn(msg.sender, lpAmount)` — it burns from the withdrawer, not from `0xdead`. There is no code path that reduces `0xdead`'s balance, so the 1000-unit floor is permanent once set.

**Test coverage.** `contracts/test/ArcoraDexPool.invariant.t.sol` — `invariant_lp_minimum_liquidity_burned`.

---

## INV-5: totalReservesUSD equals the sum of reserve-weighted oracle prices (explicit accounting, no balanceOf drift)

**Formal statement.** For the set of active tokens `T`:

```
totalReservesUSD() == sum over t in T of:
    (reserves[t] * price1e18[t]) / (10 ** decimals[t])
```

where `price1e18[t]` is the value returned by `_readUsdPrice1e18View(t)` (fresh oracle or cached fallback, 1e18-scaled USD).

**Rationale.** `totalReservesUSD` (both the view shim and the stateful internal) iterates the registry token list, calling `_readUsdPrice1e18View` / `_readUsdPrice1e18Mut` per token, and accumulates `reserves[t] * p / 10^d`. There is no `balanceOf`-derived NAV path anywhere in the contract. Direct ERC20 transfers to the pool (donations) do not update `reserves[t]` and therefore do not affect NAV — they become permanently orphaned. This is verified explicitly in the security test suite.

**Condition.** The summation excludes inactive tokens (tokens for which `REGISTRY.isActive(t)` returns false at the time of the call). If a token is delisted mid-life, its `reserves[t]` contribution disappears from the NAV view even though real tokens may still be held.

**Test coverage.** `contracts/test/ArcoraDexPool.security.t.sol` — `test_donation_does_not_inflate_nav` (unit test confirming NAV is insensitive to direct ERC20 transfers). No direct Foundry invariant sum-checks the formula across arbitrary prices. **Suggested target for Spearbit**: a parameterized invariant that asserts `totalReservesUSD()` equals the explicit sum across all tokens for arbitrary price updates.

---

## INV-6: A reverting or stale oracle never permanently bricks deposit, withdraw, or swap

**Formal statement.** Provided that at least one prior successful price read has seeded `lastValidPrice[t]` for every active token `t`, any subsequent call to `deposit`, `withdraw`, or `swap` succeeds regardless of the current oracle liveness state (reverts from `latestRoundData`, stale timestamps, or bad round IDs).

**Rationale.** Every oracle read in mutating paths goes through `_readUsdPrice1e18Mut`, which calls `_readOracle` inside a `try`/`catch`. All oracle failure modes — revert, negative answer, stale timestamp, bad round completeness — collapse to `isFresh = false`. When `isFresh` is false, the function falls back to `lastValidPrice[token]`. The call only reverts via `NoValidPrice(token)` if and only if the cache is still zero (i.e. no prior successful read has ever occurred for that token). The cache is written on the first fresh read (typically the first deposit involving that token) and is never cleared.

**Additionally**, a fresh oracle reading that diverges from the existing cache by more than `maxOracleDeviationBps` is demoted to `isFresh = false` (cache-deviation guard) and falls back to the cache, so a single-block price spike from a compromised oracle also cannot poison the pool.

**Condition.** The fallback guarantee applies only after the cache has been seeded. A token whose oracle has never returned a fresh reading (and `lastValidPrice[t] == 0`) will cause any NAV computation involving it to revert with `NoValidPrice`. This state can arise if a token is listed in the registry but no deposit has ever been made.

**Test coverage.** `contracts/test/ArcoraDexPool.security.t.sol` — `test_stale_feed_falls_back_to_cache` (confirms NAV is queryable after EURC oracle goes stale) and `test_no_valid_price_reverts_when_never_seeded` (confirms the unseeded-cache revert path). `contracts/test/ArcoraDexPool.invariant.t.sol` — seeds the cache in `setUp` so invariant runs cover the post-seed guarantee.

---

## INV-7: OracleAggregator output is bounded within the range of its live sources

**Formal statement.** `OracleAggregator.latestRoundData()` returns an `answer` satisfying one of exactly three outcomes:

- **Both live, within divergence cap**: `answer == floor((pAns + sAns) / 2)`, which lies in `[min(pAns, sAns), max(pAns, sAns)]`.
- **Single source alive**: `answer` equals the surviving source's `answer` exactly.
- **Both sources unavailable**: reverts with `AllSourcesUnavailable`.

The aggregator never fabricates a price outside the `[min(pAns, sAns), max(pAns, sAns)]` band of its live sources, and never silently returns a stale or zero answer.

**Rationale.** `_tryRead` rejects zero answers, zero timestamps, and incomplete rounds (`answeredInRound < roundId`). When both sources pass `_tryRead`, the divergence check `absDiff * 10_000 > minAns * maxDivergenceBps` reverts rather than averaging if they disagree beyond the cap. The average `(pAns + sAns) / 2` is an integer floor that is always `<= max(pAns, sAns)` and `>= min(pAns, sAns)`. In single-source mode the surviving answer is returned directly with no averaging. The `maxDivergenceBps` is constrained to `[1, 10_000]` by constructor and `setMaxDivergenceBps`.

**Known limitation (degraded mode).** When exactly one source is down, the aggregator returns the surviving source's price with no second-opinion cross-check. Operators must monitor `sourceHealth()` to detect single-source degradation.

**Test coverage.** `contracts/test/oracle/P3Aggregator.t.sol` — `test_aggregator_returns_average_within_divergence_cap`, `test_aggregator_reverts_on_sources_diverge`, `test_aggregator_returns_primary_when_secondary_reverts`, `test_aggregator_reverts_when_both_sources_revert`, `test_aggregator_falls_back_when_source_returns_zero_answer`, `test_aggregator_divergence_exactly_at_cap_passes`, `test_aggregator_reverts_when_both_sources_return_zero`, `test_sourceHealth_reports_degraded`. **No fuzz coverage over arbitrary answer pairs** — suggested target for Spearbit.

---

## INV-8: Swap fee bounds are enforced at all times

**Formal statement.**

```
swapFeeBps <= MAX_SWAP_FEE_BPS         (i.e. <= 100, meaning <= 1%)
protocolFeeShareBps <= MAX_PROTOCOL_FEE_SHARE_BPS  (i.e. <= 2500, meaning <= 25% of swap fee)
```

**Rationale.** Both bounds are checked in the constructor and in `setSwapFeeBps` / `setProtocolFeeShareBps` respectively, reverting with `InvalidFeeBps` or `InvalidProtocolFeeShareBps` on violation. The storage variables are `uint16`, so they cannot exceed 65535 even without the explicit check, but the explicit ceiling is tighter. There is no other code path that writes to these fields.

**Test coverage.** `contracts/test/ArcoraDexPool.fuzz.t.sol` — `testFuzz_protocol_fee_at_most_25pct` (fuzzes `shareBps` across `[0, 2500]` and confirms the protocol fee delta on a swap is `<= totalFee / 4 + 1`). No direct fuzz test for `swapFeeBps` upper bound. **Suggested target for Spearbit**: a fuzz test verifying that for any `swapFeeBps` in `[0, 100]` the LP-retained fee plus protocol fee plus `amountOut` equals `gross` exactly (conservation of gross output).

---

## INV-9: LP min-hold lock is inherited on transfer (JIT bypass prevention)

**Formal statement.** After any LP token transfer from `from` to `to`:

```
lastMintAt[to] >= lastMintAt[from]
```

meaning the recipient's effective unlock time is no earlier than the sender's.

**Rationale.** `ArcoraDexLP._update` calls `IArcoraDexPool(MINTER).notifyLPTransfer(from, to)` on every non-mint, non-burn transfer. `notifyLPTransfer` sets `lastMintAt[to] = lastMintAt[from]` if `lastMintAt[from] > lastMintAt[to]`, taking the stricter (later) of the two timestamps. `withdraw` enforces `block.timestamp >= lastMintAt[msg.sender] + MIN_HOLD_SECONDS` (`MIN_HOLD_SECONDS = 1 hours`), so a recipient who receives LP from a fresh depositor cannot withdraw until the sender's hold window expires.

**Condition.** `notifyLPTransfer` only propagates the lock if `lastMintAt[from] > lastMintAt[to]`. If the recipient already holds a fresher lock, theirs is preserved. A new deposit by any account overwrites their own `lastMintAt` to `block.timestamp`, resetting the clock forward.

**Test coverage.** `contracts/test/ArcoraDexPool.security.t.sol` — `test_jit_mev_blocked_by_min_hold` (base JIT lock) and `test_jit_mev_blocked_by_lp_transfer_hook` (transfer propagation closes the bypass). `test_second_deposit_extends_minhold` verifies that a subsequent deposit resets the clock rather than preserving the earlier timestamp.

---

## INV-10: Virtual shares guarantee non-zero LP minting for any nonzero USD deposit

**Formal statement.** For any call to `deposit` where `usdIn > 0`:

```
lpMinted >= 1
```

regardless of the current `LP.totalSupply()` / `totalReservesUSD()` ratio.

**Rationale.** The LP minting formula is `lpMinted = usdIn * (supply + VIRTUAL_SHARES) / (nav + VIRTUAL_ASSETS)` where `VIRTUAL_SHARES = 1e6` and `VIRTUAL_ASSETS = 1`. For the extreme case where `supply` is tiny relative to `nav`, the `VIRTUAL_SHARES` term (1e6) dominates the numerator and prevents the product from rounding to zero for any positive `usdIn`. Without the offset, `usdIn * supply / nav` could round to zero if `supply << nav`. The virtual-assets offset in the denominator (`nav + 1`) is negligible in practice (NAV is denominated in USD wei at 1e18 scale) but guards against a zero denominator when `nav == 0` on the first deposit branch.

**Condition.** The first-deposit path uses `supply == 0` and `nav == 0`, collapsing to `lpMinted = usdIn * VIRTUAL_SHARES / VIRTUAL_ASSETS = usdIn * 1e6`. For this path a separate guard `usdIn > MINIMUM_LIQUIDITY` is enforced before minting, so `lpMinted >= (MINIMUM_LIQUIDITY + 1) * 1e6`.

**Test coverage.** `contracts/test/ArcoraDexPool.security.t.sol` — `test_virtual_shares_prevent_lp_round_to_zero` (sets up the worst-case supply/NAV ratio and verifies a dust deposit produces nonzero LP).

---

## INV-11: lastAcceptedPrice ratchet limits per-call oracle movement

**Formal statement.** Every call to `deposit`, `withdraw`, or `swap` can only execute at a price within `maxOracleDeviationBps` of the previous accepted price for each token involved:

```
|price1e18 - lastAcceptedPrice[t]| / lastAcceptedPrice[t]  <=  maxOracleDeviationBps / 10_000
```

(checked only when `lastAcceptedPrice[t] != 0`; the first accepted price is unconstrained).

**Rationale.** `_readAndGuardPrice` calls `_readUsdPrice1e18Mut` (which returns the fresh oracle or cache fallback), then checks the resulting price against `lastAcceptedPrice[t]`. If the deviation exceeds `maxOracleDeviationBps`, the call reverts with `PriceDeviation`. On success, `lastAcceptedPrice[t]` is updated to the accepted price, advancing the ratchet. This means a large price move can only enter the system incrementally — each call can advance `lastAcceptedPrice[t]` by at most `maxOracleDeviationBps` of its prior value, regardless of how much the oracle has moved.

**Condition.** `syncAcceptedPrice` is an owner-only escape hatch that bypasses this check and directly overwrites `lastAcceptedPrice[t]`. Operators use it to manually reset the baseline after a large legitimate market move. A compromised owner key can call `syncAcceptedPrice` to force-accept any oracle price.

**Test coverage.** `contracts/test/ArcoraDexPool.security.t.sol` — `test_quote_and_swap_both_revert_when_cache_drifted_past_cap` (verifies that when the cache walks past the ratchet cap both `quote()` and `swap()` revert with `PriceDeviation`) and `test_quote_over_reverts_when_cache_guard_would_shield_swap` (documents the intentional behavioral asymmetry between `quote()` and `swap()` at the cache-deviation boundary). No invariant test covers this property. **Suggested target for Spearbit**.
