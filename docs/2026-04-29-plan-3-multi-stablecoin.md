# Plan 3 — Multi-stablecoin pool & gateway v0.7

**Status:** spec; ready to implement in a separate session
**Author:** Hüseyin + Claude Opus 4.7 (1M context)
**Date:** 2026-04-29
**Depends on:** v1.0.2 (gateway v0.6 with refunds + treasury)

---

## Why

Today's gateway is hardcoded to two stables (USDC/EURC). The killer-feature
positioning ("merchant settles in their preferred stablecoin on Arc") is
fictional until we can actually accept and settle in **any of the major
stables**: USDT (highest demand), PYUSD (PayPal-blessed), DAI/USDS
(decentralized), and regional fiat-pegged tokens (TRYC/BRLC/MXNC) where
issued.

This is the v1.x #5 roadmap item, but its true scope is a contract
refactor not a listing exercise — the v0.6 gateway's pay-flow has
hardcoded `USDC_INDEX/EURC_INDEX` and a single immutable pool address.

We are also at a good architectural moment: refactoring once, generically,
costs ~2 days; doing it wrong (e.g. per-pair gateway deployments) creates
permanent operational debt.

---

## Inspiration

**Ekubo** (Starknet DEX) is the reference for one decision specifically:
the **singleton pool contract**. Instead of N contract deployments for N
pairs, one contract holds all liquidity for all pairs and exposes a
generic `swap(tokenIn, tokenOut, amountIn, ...)`.

We do **not** copy Ekubo's other innovations:

| Ekubo feature | Arcora v0.7? | Reason |
|---|---|---|
| Singleton AMM | ✅ adopt | Replaces "deploy per pair" model — main reason for the borrow |
| Token registry | ✅ adopt | Add new stable → governance call, no contract redeploy |
| Concentrated liquidity / tick math | ❌ skip | We use oracle-priced flat-rate swaps, no curve, no ranges |
| Extension hooks | ❌ skip | YAGNI for stablecoin checkout; v0.x has no fee-strategy variation |
| Flash accounting | ❌ skip | Single-tx pay flow doesn't benefit |
| Packed storage slots | ⚠️ partial | Reserves + feeBps in one slot is fine; further packing is over-engineering |

The discipline is "borrow the architectural shape, don't import
mechanisms we don't need."

---

## Architecture

### Three contracts (replacing today's two)

```
┌──────────────────────────────────────────────────────────────────┐
│  StablecoinRegistry (singleton, owner-gated mutations)            │
│  ─ tokens: address[]                                              │
│  ─ tokenInfo[token] → { decimals, usdOracle, isActive }           │
│  ─ pairAllowed(tokenA, tokenB) → bool   (both active + a pool)    │
│  ─ events: TokenListed, TokenDeactivated, OracleUpdated           │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  UnifiedAMM (singleton, oracle-priced, no curve)                  │
│  ─ pools[bytes32 pairKey] → {                                     │
│       tokenA, tokenB, reserveA, reserveB, feeBps,                 │
│       maxOracleDeviationBps, active                               │
│     }                                                             │
│  ─ pairKey(a, b) = keccak256(min(a,b), max(a,b))                  │
│  ─ deposit(tokenA, tokenB, amountA, amountB) external             │
│  ─ withdraw(tokenA, tokenB, amountA, amountB) external (owner)    │
│  ─ swap(tokenIn, tokenOut, amountIn, minOut, deadline)            │
│  ─ calculateSwap(tokenIn, tokenOut, amountIn) view → amountOut    │
│  ─ rate derived from registry's per-token USD oracles             │
│  ─ events: PoolOpened, Swapped, LiquidityAdded                    │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  ArcFXGateway v0.7 (refactored — token-agnostic)                  │
│  ─ Removes: USDC, EURC, USDC_INDEX, EURC_INDEX immutables         │
│  ─ POOL → address of UnifiedAMM (still immutable)                 │
│  ─ REGISTRY → address of StablecoinRegistry (immutable)           │
│  ─ registerMerchant(payoutAddress, payoutToken)                   │
│       requires registry.tokenInfo[payoutToken].isActive           │
│  ─ createInvoice(...) takes any payIn token; require pairAllowed  │
│  ─ pay(globalId, maxAmountIn) — same shape as v0.6, but routes    │
│       through UnifiedAMM.swap(inv.payIn, payoutToken, ...)        │
│  ─ refundInvoice(globalId) — unchanged from v0.6                  │
│  ─ payments[] mapping — unchanged                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Per-token USD oracles (not per-pair)

```
USDC/USD  = 1.0000  (hardcoded peg-1, or Chainlink USDC/USD)
EURC/USD  = 1.0863  (Chainlink EUR/USD; today's mock value)
USDT/USD  = 1.0001  (Chainlink USDT/USD)
PYUSD/USD = 1.0000  (Chainlink PYUSD/USD)
TRYC/USD  = 0.0291  (TRY/USD via aggregator)

rate(tokenA, tokenB) = (USD-of-A) / (USD-of-B)
```

**Rationale:** N stables → N oracles, not N(N-1)/2. New listing = one new
oracle wired, no other contract changes. Matches how price feeds are
actually published in the wild (Chainlink, Pyth, RedStone all publish
TOKEN/USD, not arbitrary cross-pairs).

For testnet, USDC/USD and PYUSD/USD pegs can be hardcoded as `1e8`
constants in the registry to avoid mock oracle fatigue. Real-stable
deviation (USDT) gets its own mock feed like EUR/USD does today.

### Routing: direct pair only (no multi-hop in v0.7)

For each (payIn, payout) the gateway expects a *direct* pool. If a
merchant lists USDT-payout and a customer pays in PYUSD, the AMM checks
`pools[pairKey(USDT, PYUSD)]` and reverts with `PairNotSupported` if it
doesn't exist.

Multi-hop routing (USDT → USDC → PYUSD) is intentionally **out of scope**:
- Each hop costs gas + slippage; with stable-near-stable rates the win is
  small.
- Choosing the route adds complexity (path-finding, intermediary slippage
  guards).
- Operationally: we're the LP in v0.7 — we just open the pools we need and
  list the pairs we want to support.

Add as v0.8 if real demand surfaces (e.g. a merchant lists TRYC and only
PYUSD is in the customer's wallet).

### Liquidity model: per-pool internal balances

Each pool tracks its own `reserveA / reserveB` balance. There is **no LP
ERC20** in v0.7. Reasons:

1. The protocol is the only LP for the foreseeable future (we bootstrap
   each pool from the deployer wallet).
2. ERC20 LP tokens add complexity (transferable LP positions, fee
   accounting per LP, etc.) we don't need yet.
3. Treasury accounting stays simple — `protocolFeesAccrued[token]` per
   token still works as today.

Add LP tokenization in v1.x or v2 when external LPs are a real ask.

---

## Storage layout

```solidity
// StablecoinRegistry
struct TokenInfo {
    uint8   decimals;        // 6 for USDC/EURC/USDT, 18 for DAI
    bool    isActive;
    address usdOracle;       // Chainlink USD-quoted aggregator (8 decimals)
}
mapping(address token => TokenInfo) public tokenInfo;
address[] public tokens;     // for off-chain enumeration

// UnifiedAMM
struct Pool {
    address tokenA;          // 20 bytes
    address tokenB;          // 20 bytes (slot 1+2 packed loosely)
    uint128 reserveA;        // 16 bytes
    uint128 reserveB;        // 16 bytes
    uint16  feeBps;          // 2 bytes
    uint16  maxOracleDeviationBps;
    bool    active;          // 1 byte
}
mapping(bytes32 pairKey => Pool) public pools;
```

Pool storage is dominated by reserves. Packing reserves into `uint128`
gives us ~340 trillion units (in 6-decimal terms, that's 340 trillion
USDC) — far above any conceivable single-pool size.

---

## Gateway v0.7 changes

### Removed

```solidity
// All of these go away:
IERC20  public immutable USDC;
IERC20  public immutable EURC;
uint8   public immutable USDC_INDEX;
uint8   public immutable EURC_INDEX;

// And the per-token branching in pay():
uint8 iIn  = inv.payIn == address(USDC) ? USDC_INDEX : EURC_INDEX;
uint8 jOut = ...;
```

### Added

```solidity
IUnifiedAMM           public immutable POOL;
IStablecoinRegistry   public immutable REGISTRY;

// pay() now just:
uint256 amountIn = _estimateAmountIn(inv.payIn, payoutToken, inv.amountOut);
if (amountIn > maxAmountIn) revert SlippageExceeded(amountIn, maxAmountIn);
IERC20(inv.payIn).safeTransferFrom(msg.sender, address(this), amountIn);
IERC20(inv.payIn).forceApprove(address(POOL), amountIn);
uint256 received = POOL.swap(inv.payIn, payoutToken, amountIn, inv.amountOut, deadline);
```

### Estimator (carried over from v0.5)

The 1-wei iteration logic from v0.5's `_estimateAmountIn` is preserved
and made generic:

```solidity
function _estimateAmountIn(address tokenIn, address tokenOut, uint256 amountOut)
    internal view returns (uint256 amountIn)
{
    uint256 probeIn  = 10 ** REGISTRY.tokenInfo(tokenIn).decimals;
    uint256 probeOut = POOL.calculateSwap(tokenIn, tokenOut, probeIn);
    if (probeOut == 0) return type(uint256).max;
    amountIn = (amountOut * probeIn + probeOut - 1) / probeOut;
    for (uint256 i = 0; i < ESTIMATE_MAX_STEPS; i++) {
        if (POOL.calculateSwap(tokenIn, tokenOut, amountIn) >= amountOut) return amountIn;
        unchecked { amountIn++; }
    }
}
```

### Same-token branch unchanged

`if (inv.payIn == payoutToken)` — direct transfer, no swap, no oracle
check. Gas-optimal for stable-of-the-house payments.

---

## Migration

### Testnet — re-register everyone

v0.6 gateway stays on chain (existing paid invoices remain queryable, the
indexer no longer listens to it). Merchants run `registerMerchant` again
on v0.7 from the dashboard. New invoice numbers.

### Production-ish path (when there's one)

A scripted migration:
1. Snapshot v0.6 `merchants` mapping for the active set.
2. v0.7 deployer calls `registerMerchant` *for* each merchant via a
   delegated path (or a one-shot owner-only `bulkRegister` helper).
3. Switch DNS / app envs to v0.7.
4. Leave v0.6 read-only for legacy invoice lookup.

Out of scope for this spec — flag as work for the mainnet release.

---

## Database / indexer impact

`invoices.payInToken` and `payoutToken` are already `text` (any address)
— no schema change needed. The indexer's `InvoicePaid` handler stays
identical. Webhook payload shape unchanged.

What does change:
- The dashboard's "Create invoice" dialog needs a payout-token selector
  populated from `registry.tokens`, not a hardcoded `["USDC","EURC"]`.
- The checkout page needs a pay-in token selector (or auto-detect from the
  customer's wallet balance) drawn from the supported pair list for the
  invoice's payout token.

A new `/api/tokens` endpoint reads the registry and returns the active
list with metadata for UI use.

---

## Testing plan

### Foundry

- `StablecoinRegistry`: list/deactivate flows, oracle update events,
  reverts on duplicate listing, owner-only auth.
- `UnifiedAMM`:
  - basic two-token swap matches today's `OracleAMM` behavior
    (regression — must not change USDC/EURC math).
  - 3+ tokens: USDC/EURC, USDC/USDT, USDT/EURC pools coexist.
  - Reverts on inactive token, missing pool, oracle deviation breach.
  - 1-wei estimator regression from v0.5 still passes (inherited from
    `_estimateAmountIn` shape).
- `ArcFXGateway v0.7`:
  - Migrate the existing 110+ tests by removing the immutable USDC/EURC
    setup and substituting a deployed registry + AMM with two tokens
    seeded.
  - All existing happy paths should pass without behavioral change.
  - Refund flow inherited from v0.6 — same tests, different gateway
    constructor args.
  - New tests: pay with a third stable (USDT-mock) end-to-end.

Target: ≥ 130 tests, all passing, before deploy.

### App

- Update `lib/chain/gateway-abi.ts` for v0.7 ABI (mostly subtractive —
  immutable USDC/EURC fields disappear; everything else stable).
- Update `CreateInvoiceDialog` to use registry-driven token list.
- Update `CheckoutClient` to ditto.
- Vitest unit tests for the new `/api/tokens` route + dialog logic.

### Live smoke

The same smoke we do for any deploy:
1. USDC → USDC same-token (regression, must still work)
2. USDC → EURC swap (regression)
3. EURC → USDC swap (regression — v0.5's iteration must still kick in)
4. USDC → USDT swap (new path)
5. USDT → EURC swap (new path; uses derived rate from two USD oracles)

---

## Effort

| Phase | Time |
|---|---|
| Spec review + revisions | 30 min |
| `StablecoinRegistry` contract + tests | 2 h |
| `UnifiedAMM` contract + tests + foundry regression port | 4 h |
| `ArcFXGateway v0.7` refactor + tests | 3 h |
| Deploy script + bootstrap (USDC/EURC carry-over + USDT mock + USDT pools) | 2 h |
| App: token registry hooks, picker components, indexer ABI | 3 h |
| Live deploy + smoke | 1 h |
| **Total** | **~2 days** |

Realistically split across 2–3 sessions: one for the contracts, one for
deploy + integration, one for app + polish.

---

## Open questions to revisit before implementing

1. **Where does USDT-mock come from on Arc testnet?** Either deploy our
   own MockERC20 (consistent with EURC mock pattern) or look for a
   community-deployed USDT testnet token. Prefer our own for control.
2. **What stables ship with v0.7 day-one?** Suggest USDC, EURC, and one
   new addition (USDT) so the pool mechanic is exercised but the rollout
   is small.
3. **`PriceGuard` per-pool or global?** Today's contract uses
   `MAX_ORACLE_DEVIATION_BPS = 50` constant. v0.7 stores it per-pool so a
   thinly-traded pair can run a tighter or looser guard. Default 50.
4. **Owner privileges on the registry**: who can list a token?
   `Ownable.owner()` for v0.7. Add governance later if relevant.

---

## Decision log (settled in 2026-04-29 session)

- ✅ Singleton AMM + token registry (Ekubo-shape, not Ekubo-mechanics).
- ✅ Per-token USD oracles, derive cross-pair rates inside the AMM.
- ❌ Multi-hop routing (deferred to v0.8 if asked for).
- ❌ ERC20 LP tokens (internal accounting only; protocol is the LP).
- ✅ Re-register migration on testnet; mainnet gets a scripted bulk
  helper later.
- ✅ Same-token direct path preserved verbatim from v0.6.
- ✅ v0.5's iterating `_estimateAmountIn` carried into v0.7 verbatim,
  generalized over decimals via `tokenInfo`.

---

## When picking this up

1. Re-read this file end-to-end; check whether any of the four open
   questions above changed since 2026-04-29.
2. Verify v0.6 gateway is still the canonical contract (memory's
   `roadmap_open_items.md` is authoritative).
3. Check `npm view @arcora/sdk version` and whatever the current minor
   tag is — v0.7 will likely ship as `1.1.0` (minor: new payInToken
   surface in the SDK is additive but the supported set changes).
4. Start in `packages/contracts/src/registry/StablecoinRegistry.sol`.
   Keep `OracleAMM.sol` and `ArcFXGateway.sol` intact while building the
   new contracts so the old gateway stays deployable from a clean tree
   if rollback is needed.
