# ArcoraDEX — Spinoff Design Spec

**Date:** 2026-05-06
**Status:** Approved (brainstorming complete) — pending implementation plan
**Authors:** Hüseyin Arslan + Claude
**Supersedes / branches from:** `Kubudak90/arcora-v0.7-shared-vault-pool` (Arcora v0.7 multi-stablecoin pool)

---

## 1. Context & Motivation

The Arcora v0.7 codebase contains two cleanly separable concerns:

1. **A multi-stable, oracle-priced shared-vault swap primitive** (`StablePool` + `StablecoinRegistry`).
2. **A merchant checkout / invoice / FX-settlement layer** (`ArcFXGateway`) that consumes the primitive.

Arcora's payment product (now branded **ArcoraPay**) has migrated to Circle App Kit and no longer needs the on-chain gateway. The pool/registry primitives, however, are valuable as a standalone product — an oracle-priced stable-DEX with public LP support.

This spec documents the spinoff: extract the pool/registry, redesign them as a proper LP-based DEX (currently the pool is owner-funded with no LP token), drop the gateway, and rebrand under **ArcoraLabs** as **ArcoraDEX**.

The umbrella brand is **ArcoraLabs**:
- **ArcoraPay** — payment product (existing, Circle App Kit-based, separate repo).
- **ArcoraDEX** — this project: oracle-priced multi-stable DEX with public liquidity.

The end-state goal is **Phase D** (full product: contracts + UI + SDK + analytics + docs), but v1 ships **Phase A** (contracts + minimal UI). Phases B/C/D/E roadmap is included at the end of this spec.

## 2. Product Decisions (frozen)

| Decision | Choice |
|---|---|
| Liquidity model | Public LP, single USD-denominated `ADEX-LP` ERC20 |
| Initial LP price | 1 LP = $1 (first deposit sets parity) |
| Inflation-attack guard | First deposit burns 1000 LP to `address(0xdead)` (Uniswap V2 pattern) |
| Withdrawal mechanic | Single-token, swap-fee bps charged on every withdraw |
| Fee split | 90% LP / 10% protocol (default), on-chain adjustable |
| Protocol fee cap | `MAX_PROTOCOL_FEE_SHARE_BPS = 2500` (LPs always keep ≥75%) |
| Protocol fee asset | `tokenOut` cinsinden, both for swap and withdraw (symmetric) |
| Swap fee default | 30 bps (0.30%), `MAX_SWAP_FEE_BPS = 100` (1%) |
| Active stables (testnet) | USDC, USDT, PYUSD, DAI, EURC, TRYC, BRLC (existing 7) |
| Chain target | Arc testnet (chainId 5042002); mainnet path open |
| Gateway disposition | Dropped entirely — Arcora moved to Circle App Kit |
| Repo strategy | Rename `Kubudak90/arcora-v0.7-shared-vault-pool` → `Kubudak90/arcoradex`. Frozen `legacy/v0.7-arc-fx-gateway` branch preserves prior state. Later transfer to `arcoralabs/` org. |
| Frontend stack | Next.js 16 (App Router) + Tailwind v4 + shadcn/ui + wagmi v2 + viem |
| Default language | English (no i18n in v1) |
| Token logos | Public CDN (CoinGecko / Trust Wallet asset list); fallback to first-letter gradient circle |

## 3. Repo Structure

### 3.1 Files removed (clean break)
```
contracts/src/ArcFXGateway.sol
contracts/src/pool/StablePool.sol
contracts/src/pool/IStablePool.sol
contracts/src/registry/StablecoinRegistry.sol
contracts/src/registry/IStablecoinRegistry.sol
contracts/src/libraries/PriceGuard.sol            (already unused)
contracts/test/ArcFXGateway.t.sol
contracts/test/ArcFXGateway.fuzz.t.sol
contracts/test/ArcFXGateway.invariant.t.sol
contracts/test/StablePool.t.sol
contracts/test/StablecoinRegistry.t.sol
contracts/test/handlers/GatewayHandler.sol
contracts/script/DeployV07.s.sol
contracts/script/SmokeV07.s.sol
contracts/script/StressV07.s.sol
README.md                                          (rewritten from scratch)
```

### 3.2 Files preserved
- `contracts/foundry.toml`, `remappings.txt`, `lib/` (OpenZeppelin + forge-std)
- `contracts/src/interfaces/IChainlinkAggregator.sol`
- `contracts/src/testnet/MintableERC20.sol`
- `contracts/src/testnet/MockChainlinkFeed.sol`
- `contracts/test/helpers/MockERC20.sol`
- `ops/keepalive/` (multi-feed-push.mjs adapted; gateway has no reference inside)
- `docs/2026-04-29-*.md`, `docs/2026-04-30-*.md` (historical, linked from new README)
- `docs/rollouts/` (v0.7 rollout note kept as historical record)

### 3.3 Files added
```
contracts/src/
  ArcoraDexPool.sol
  ArcoraDexRegistry.sol
  ArcoraDexLP.sol
  interfaces/
    IArcoraDexPool.sol
    IArcoraDexRegistry.sol
    IArcoraDexLP.sol
contracts/test/
  ArcoraDexPool.t.sol
  ArcoraDexPool.fuzz.t.sol
  ArcoraDexPool.invariant.t.sol
  ArcoraDexRegistry.t.sol
  ArcoraDexLP.t.sol
  handlers/PoolHandler.sol
contracts/script/
  DeployArcoraDex.s.sol
  SmokeArcoraDex.s.sol
app/                                # Next.js 16 frontend
  package.json, tsconfig.json, next.config.ts, tailwind.config.ts
  app/
    page.tsx                        # /  — Swap
    liquidity/page.tsx              # /liquidity — Deposit/Withdraw
    pool/page.tsx                   # /pool — Reserves & stats
    layout.tsx, globals.css
  components/
    ui/                             # shadcn primitives
    swap/SwapCard.tsx
    liquidity/{DepositTab,WithdrawTab}.tsx
    pool/{ReservesTable,SwapHistory}.tsx
    wallet/ConnectButton.tsx
    layout/{Header,Footer}.tsx
  lib/
    wagmi.ts, contracts.ts, oracle.ts, format.ts, slippage.ts
  public/brand/                     # imported from existing assets/
    arcora-dex-logo.svg
    arcora-dex-logo-mono.svg
    arcora-dex-icon.svg
    arcora-dex-symbol.svg
    arcora-dex-symbol-mono.svg
  .env.example
docs/superpowers/specs/
  2026-05-06-arcoradex-spinoff-design.md   # this file
docs/rollouts/
  2026-05-XX-arcoradex-deploy.md           # written during T15
```

### 3.4 Legacy backup
Before any deletion, a **frozen branch** `legacy/v0.7-arc-fx-gateway` is cut from current `main` HEAD and pushed to remote. This branch is never merged or modified — it serves as a permanent snapshot of the v0.7 multi-stablecoin pool + gateway state. No git tag or tarball is needed; the branch alone provides indefinite access.

## 4. Contract Architecture

```
ArcoraDexRegistry  ─────────┐
                            ↓
                    ArcoraDexPool ─────► ArcoraDexLP (ERC20)
                            ↑               (minter = Pool, immutable)
              Chainlink/Mock feeds resolved via Registry
```

### 4.1 ArcoraDexRegistry (Ownable2Step)

Same shape as the previous `StablecoinRegistry`, renamed for branding consistency.

```solidity
struct TokenInfo {
    address oracle;        // Chainlink-compatible aggregator (8 decimals)
    uint8   decimals;      // ERC20 decimals
    uint16  deviationBps;  // PriceGuard deviation cap (e.g. 50 for stables, 150 for FX)
    bool    isActive;
}

function addToken(address token, address oracle, uint8 decimals, uint16 deviationBps) external onlyOwner;
function setOracle(address token, address newOracle) external onlyOwner;
function setDeviation(address token, uint16 newBps) external onlyOwner;
function deactivate(address token) external onlyOwner;
function reactivate(address token) external onlyOwner;

function tokens() external view returns (address[] memory);
function tokenInfo(address token) external view returns (TokenInfo memory);
function isActive(address token) external view returns (bool);
function count() external view returns (uint256);

// Events
event TokenAdded     (address indexed token, address oracle, uint8 decimals, uint16 deviationBps);
event OracleUpdated  (address indexed token, address oldOracle, address newOracle);
event DeviationUpdated(address indexed token, uint16 oldBps, uint16 newBps);
event Deactivated    (address indexed token);
event Reactivated    (address indexed token);
```

### 4.2 ArcoraDexLP (ERC20, minter-restricted)

```solidity
contract ArcoraDexLP is ERC20 {
    address public immutable MINTER;   // = Pool

    constructor(address minter) ERC20("Arcora DEX LP", "ADEX-LP") {
        MINTER = minter;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == MINTER, "ADEX-LP: not minter");
        _mint(to, amount);
    }
    function burn(address from, uint256 amount) external {
        require(msg.sender == MINTER, "ADEX-LP: not minter");
        _burn(from, amount);
    }
    // decimals() = 18 (ERC20 default) — 1 LP token == 1 USD at parity
}
```

The Pool **deploys** the LP token in its constructor (`new ArcoraDexLP(address(this))`) so the minter binding is atomic and immutable. Deploy scripts read `pool.LP()` to learn the LP address.

### 4.3 ArcoraDexPool (Ownable2Step + Pausable + ReentrancyGuard)

```solidity
contract ArcoraDexPool {
    // Immutables
    IArcoraDexRegistry public immutable REGISTRY;
    IArcoraDexLP       public immutable LP;

    // Constants
    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_SWAP_FEE_BPS = 100;             // 1%
    uint16 public constant MAX_PROTOCOL_FEE_SHARE_BPS = 2500;  // 25%
    uint256 public constant MINIMUM_LIQUIDITY = 1000;          // burned on first deposit
    uint256 public constant ORACLE_STALE_AFTER = 1 hours;

    // Storage
    mapping(address token => uint256) public reserves;
    mapping(address token => uint256) public protocolFeesAccrued;
    mapping(address token => uint256) public lastAcceptedPrice;
    uint16 public swapFeeBps;          // default 30
    uint16 public protocolFeeShareBps; // default 1000
    bool   public paused;

    constructor(IArcoraDexRegistry registry) Ownable2Step() {
        REGISTRY = registry;
        LP = new ArcoraDexLP(address(this));
        swapFeeBps = 30;
        protocolFeeShareBps = 1000;
    }
}
```

#### Public surface (anyone)
```solidity
function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minOut,
    address recipient,
    uint256 deadline
) external whenNotPaused nonReentrant returns (uint256 amountOut);

function deposit(
    address token,
    uint256 amount,
    uint256 minLpOut,
    uint256 deadline
) external whenNotPaused nonReentrant returns (uint256 lpMinted);

function withdraw(
    address tokenOut,
    uint256 lpAmount,
    uint256 minTokenOut,
    uint256 deadline
) external whenNotPaused nonReentrant returns (uint256 amountOut);

// Views
function quoteSwap(address tokenIn, address tokenOut, uint256 amountIn)
    external view returns (uint256 amountOut, uint256 fee);

function quoteDeposit(address token, uint256 amount)
    external view returns (uint256 lpOut);

function quoteWithdraw(address tokenOut, uint256 lpAmount)
    external view returns (uint256 amountOut, uint256 fee);

function totalReservesUSD() external view returns (uint256 navE18);
```

#### Owner-only surface
```solidity
function setSwapFeeBps(uint16 newBps) external onlyOwner;            // ≤ 100
function setProtocolFeeShareBps(uint16 newBps) external onlyOwner;   // ≤ 2500
function withdrawProtocolFees(address token, uint256 amount, address to) external onlyOwner;
function pause() external onlyOwner;
function unpause() external onlyOwner;
function syncAcceptedPrice(address token) external onlyOwner returns (uint256 price1e18);
```

#### Events
```solidity
event Deposited(address indexed user, address indexed token, uint256 amountIn, uint256 lpMinted, uint256 navBefore, uint256 navAfter);
event Withdrew (address indexed user, address indexed tokenOut, uint256 lpBurned, uint256 amountOut, uint256 protocolFee, uint256 navBefore, uint256 navAfter);
event Swapped  (address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 lpFeeUsd, uint256 protocolFeeAmtOut, address recipient);
event SwapFeeUpdated(uint16 oldBps, uint16 newBps);
event ProtocolFeeShareUpdated(uint16 oldBps, uint16 newBps);
event ProtocolFeesWithdrawn(address indexed token, uint256 amount, address indexed to);
event Paused(); event Unpaused();
event AcceptedPriceSynced(address indexed token, uint256 oldPrice1e18, uint256 newPrice1e18);
```

## 5. Core Mechanics

All USD math is in `1e18` scale. Token amounts are in their native decimals.

### 5.1 NAV (Net Asset Value)
```
nav = Σ_{token ∈ Registry.tokens(), isActive(token)} (reserves[token] * price[token]) / 10^decimals[token]
```
`price` is the oracle reading (post-PriceGuard) normalized to 1e18. **Only active tokens contribute to NAV.** This means deactivating a token immediately removes its reserves from the LP value pool; LPs effectively lose claim on those reserves until the token is re-activated. This is intentional: deactivation is a governance action that should be reversible, not a way to silently dilute claims. NAV decreases on deactivation, NAV increases on re-activation; both events MUST be logged so LPs can monitor governance impact (see §4.3 events — `Deactivated`/`Reactivated` events emitted by the Registry, and `setSwapFeeBps`-style admin events on the Pool).

### 5.2 Deposit
```
1. Require Registry.isActive(token), block.timestamp <= deadline
2. priceIn = _readAndGuardPrice(token)
3. usdIn = amount * priceIn / 10^decimals
4. lpTotal = LP.totalSupply()
5. if lpTotal == 0:
       require usdIn > MINIMUM_LIQUIDITY, "first deposit too small"
       lpMinted = usdIn - MINIMUM_LIQUIDITY
       LP.mint(0xdead, MINIMUM_LIQUIDITY)
   else:
       navBefore = totalReservesUSD()      // before transferFrom
       lpMinted  = usdIn * lpTotal / navBefore
6. require lpMinted >= minLpOut, "slippage"
7. SafeERC20.transferFrom(user, this, amount)
8. reserves[token] += amount
9. LP.mint(user, lpMinted)
10. emit Deposited(...)
```

### 5.3 Withdraw (single-token, fee in tokenOut)
```
1. Require Registry.isActive(tokenOut), block.timestamp <= deadline
2. priceOut  = _readAndGuardPrice(tokenOut)
3. lpTotal   = LP.totalSupply()
4. navBefore = totalReservesUSD()
5. usdRedeemed   = lpAmount * navBefore / lpTotal
6. usdNet        = usdRedeemed * (BPS - swapFeeBps) / BPS
7. amountOut     = usdNet * 10^decOut / priceOut
8. feeUsd        = usdRedeemed - usdNet
9. protocolFeeUsd = feeUsd * protocolFeeShareBps / BPS
10. protocolFeeAmt = protocolFeeUsd * 10^decOut / priceOut
11. require reserves[tokenOut] >= amountOut + protocolFeeAmt, "insufficient reserves"
12. require amountOut >= minTokenOut, "slippage"
13. LP.burn(user, lpAmount)
14. reserves[tokenOut] -= (amountOut + protocolFeeAmt)
15. protocolFeesAccrued[tokenOut] += protocolFeeAmt
16. SafeERC20.transfer(user, amountOut)
17. emit Withdrew(...)
```
LP-side fee share remains in `reserves[tokenOut]` → NAV ↑ → all remaining LPs' per-share value rises.

### 5.4 Swap (fee in tokenOut)
```
1. Require Registry.isActive(tokenIn) && isActive(tokenOut), tokenIn != tokenOut, deadline ok
2. priceIn  = _readAndGuardPrice(tokenIn)
3. priceOut = _readAndGuardPrice(tokenOut)
4. usdGross      = amountIn * priceIn / 10^decIn
5. usdNet        = usdGross * (BPS - swapFeeBps) / BPS
6. amountOut     = usdNet * 10^decOut / priceOut
7. feeUsd        = usdGross - usdNet
8. protocolFeeUsd = feeUsd * protocolFeeShareBps / BPS
9. protocolFeeAmt = protocolFeeUsd * 10^decOut / priceOut
10. require reserves[tokenOut] >= amountOut + protocolFeeAmt, "insufficient reserves"
11. require amountOut >= minOut, "slippage"
12. SafeERC20.transferFrom(user, this, amountIn)
13. reserves[tokenIn]  += amountIn
    reserves[tokenOut] -= (amountOut + protocolFeeAmt)
    protocolFeesAccrued[tokenOut] += protocolFeeAmt
14. SafeERC20.transfer(recipient, amountOut)
15. emit Swapped(...)
```

### 5.5 PriceGuard (per-token)
- Read oracle aggregator: `(answer, updatedAt) = aggregator.latestRoundData()`
- Require `updatedAt + ORACLE_STALE_AFTER > block.timestamp`, else revert "stale oracle"
- Normalize answer to 1e18 via aggregator decimals (typically 8)
- If `lastAcceptedPrice[token] == 0`, set `lastAcceptedPrice[token] = price` and return
- Else: `delta = abs(price - lastAcceptedPrice[token]) * BPS / lastAcceptedPrice[token]`
- Require `delta <= deviationBps[token]` (Registry); else revert "deviation cap"
- On accepted read: `lastAcceptedPrice[token] = price`
- Owner can `syncAcceptedPrice(token)` to bypass the guard once and reset baseline (e.g. after a legitimate large peg movement)

### 5.6 Edge cases & invariants
- `totalSupply == 0 ↔ nav == 0` (both zero before first deposit; both nonzero after)
- `reserves[t] == 0` while token is active → swap-from / withdraw-to revert (insufficient reserves); deposit allowed
- Token deactivated → deposit, swap-from, swap-to, withdraw-to all revert. Reserves of the deactivated token stop contributing to NAV (§5.1) — LPs lose claim on them while inactive. Re-activation restores claim. Owner cannot drain the deactivated reserves directly (no admin "rescue" function); recovery requires re-activation followed by normal LP withdrawals (which may be the LPs themselves draining via swap or single-token withdraw). This is a deliberate trust-minimization choice: deactivation is a pause, not a confiscation.
- Contract token balance == `reserves[t] + protocolFeesAccrued[t]` (accounting ↔ ERC20 balance equality, modulo donations which are ignored — `reserves[t]` is incremented only on transferFrom)

## 6. Frontend (v1, Phase A)

### 6.1 Pages
- **`/` Swap** — `tokenIn` dropdown, amount input, `tokenOut` dropdown, amount output (read-only). 400ms debounced `quoteSwap`. Slippage tolerance (default 0.5%). Deadline (default 20 min). Two-step: approve (if needed) → swap. Receipt with tx hash + block explorer link.
- **`/liquidity` Deposit / Withdraw** — Tabs.
  - **Deposit**: token dropdown, amount input, "Estimated LP" preview, approve + deposit.
  - **Withdraw**: lpAmount input (max = user's ADEX-LP balance), tokenOut dropdown, "Estimated payout" + "Fee" preview, withdraw.
  - "Your position" panel: ADEX-LP balance, USD value at current NAV, rough APY estimate from last 7d Swapped events.
- **`/pool` Pool Stats** — Active token table (token / oracle price / reserve native / reserve USD / pool share %). Total NAV, total LP supply, 1 LP = $X.XX. Recent 50 swaps (Swapped events from last N blocks via RPC). Total protocol fees per token.

### 6.2 Stack & libraries
- Next.js 16 (App Router, RSC where it helps)
- Tailwind v4
- shadcn/ui primitives (button, input, dialog, dropdown, table, tabs, sonner)
- wagmi v2 + viem (typed contract reads/writes via `parseAbi`)
- Wallet support: injected (MetaMask) + WalletConnect; basic ConnectButton (no RainbowKit dependency)

### 6.3 Branding
- Brand colors imported from existing logo SVGs:
  - `arcora-blue-500: #2563FF`, `arcora-blue-600: #1D4FEA`
  - `arcora-teal-400: #00C2A8`, `arcora-teal-500: #12B9B0`
  - `arcora-ink: #0B1426`
- Wordmark: full logo in header (light mode), mono variant for dark mode
- Favicon: `arcora-dex-icon.svg`
- Token logos: CoinGecko / Trust Wallet asset list CDN; fallback to first-letter gradient circle

### 6.4 Network & deployment
- Single chain: Arc testnet (chainId 5042002). Off-network wallets see "switch network" CTA.
- Hosting: Vercel project under `arcoradex` repo. Preview deployments per PR. Domain v1: `arcoradex.vercel.app`; later `arcoradex.xyz` or `arcoralabs/dex`.

### 6.5 Out of scope (v1)
- Multi-language i18n
- Subgraph / persistent indexer (rough APY from RPC events is enough)
- Mobile-specific layout (responsive but not mobile-first)
- LP APY backfill / charts (Phase C)
- SDK package (Phase B)

## 7. Deployment & Operations

### 7.1 Deploy script (`script/DeployArcoraDex.s.sol`)
```
1. registry = new ArcoraDexRegistry()
2. pool     = new ArcoraDexPool(registry)
   // pool internally deploys ArcoraDexLP(address(this))
3. lp = pool.LP()
4. for each (sym, decimals, deviationBps, initialPrice) in 7-stable config:
       token = new MintableERC20(name, sym, decimals)
       feed  = new MockChainlinkFeed(initialPrice, 8)
       registry.addToken(token, feed, decimals, deviationBps)
5. // Owner seed deposit: $10k worth of each token
   for each token:
       seedAmount = $10_000 * 10^decimals / initialPrice
       token.mint(deployer, seedAmount)
       token.approve(pool, seedAmount)
       pool.deposit(token, seedAmount, 0, type(uint).max)
6. console2.log all addresses
```

### 7.2 Smoke script (`script/SmokeArcoraDex.s.sol`)
Seven-flow smoke run after deploy:
1. Deposit 1000 USDC → check LP minted, NAV updated
2. Deposit 1000 EURC → second token, NAV grows
3. Swap USDC→EURC 100
4. Swap EURC→TRYC 100 (cross-FX)
5. Swap PYUSD→DAI 100 (6 ↔ 18 decimals)
6. Withdraw 500 LP as USDC (single-token withdraw with fee)
7. Withdraw 500 LP as BRLC (cross-FX withdraw with fee)

Each step logs events and `pool.totalReservesUSD()`. Runnable in CI via `--fork-url` without broadcast.

### 7.3 Keeper
`ops/keepalive/multi-feed-push.mjs` is reused unchanged at the script level; only the feeds config (addresses) is replaced. Step-wise capped pushes (50 / 150 bps) and CoinGecko batching from recent commits are preserved.

VPS layout migration:
- `194.163.136.1:/root/arcora-v07-feeds/` → `/root/arcoradex-feeds/`
- systemd: disable `arcora-v07-feeds.timer` & `.service`; create and enable `arcoradex-feeds.timer` & `.service` pointing at the new path
- Logs: `journalctl -u arcoradex-feeds.service`

### 7.4 CI
**`.github/workflows/contracts.yml`**
- `forge fmt --check`
- `forge build --sizes`
- `forge test -vvv`
- `forge snapshot --check` (gas regression)
- `forge coverage` (artifact upload)

**`.github/workflows/app.yml`**
- `pnpm install --frozen-lockfile`
- `pnpm typecheck`
- `pnpm lint`
- `pnpm build`

### 7.5 Mainnet path (out of v1 scope)
The same `DeployArcoraDex.s.sol` runs on Arc mainnet with `MintableERC20`/`MockChainlinkFeed` swapped for real token + Chainlink addresses. No code change required, only config.

## 8. Testing Strategy

### 8.1 Unit (~60 tests across 3 files)
- `ArcoraDexLP.t.sol` (~6): minter-only mint/burn, ERC20 standard behavior, decimals=18
- `ArcoraDexRegistry.t.sol` (~14): adapted from existing StablecoinRegistry suite
- `ArcoraDexPool.t.sol` (~40): PriceGuard / oracle stale, cross-decimal quote/swap, first-deposit 1000 LP burn, subsequent proportional mints, multi-token deposit sequence, single-token withdraw with tokenOut fee, insufficient-reserves revert, 7-stable swap paths, fee split (90/10 with cap=25%), `setSwapFeeBps` and `setProtocolFeeShareBps` cap reverts, pause/unpause behavior, deactivated token revert paths, slippage reverts (`minLpOut`/`minOut`/`minTokenOut`), deadline expired revert, `withdrawProtocolFees` only-owner

### 8.2 Fuzz (`ArcoraDexPool.fuzz.t.sol`)
- `fuzz_deposit_then_withdraw_preserves_value`: round-trip loss ≤ 1× swapFeeBps + small rounding
- `fuzz_swap_monotonic_in_amount`: amountOut non-decreasing in amountIn
- `fuzz_quote_matches_swap`: `quoteSwap` and actual `swap` agree on amountOut
- `fuzz_lp_share_proportional`: two depositors' LP balances ratio == their USD contribution ratio
- `fuzz_protocol_fee_at_most_25pct`: with any valid `protocolFeeShareBps`, protocol's take ≤ 25% of total fee

### 8.3 Invariant (`ArcoraDexPool.invariant.t.sol`)
Handler `handlers/PoolHandler.sol` exercises random users doing random deposit/withdraw/swap calls.

Invariants:
- `nav >= 0` and `(totalSupply == 0) ↔ (nav == 0)`
- `Σ reserves[t] * price[t]` (NAV) covers all outstanding LP claims at current per-share value
- `protocolFeesAccrued[t] <= contract.balanceOf(t) - reserves[t]` (no over-withdraw of protocol fees)
- `contract.balanceOf(t) == reserves[t] + protocolFeesAccrued[t]` (accounting ↔ real balance)

Run config: **1024 runs × 128 calls per run**.

### 8.4 Frontend tests
- `pnpm typecheck` + `pnpm lint` mandatory in CI
- Vitest for pure utilities (`format.ts`, `slippage.ts`, decimals normalization) — ~10 tests
- No E2E in v1. Manual testnet smoke via the live UI.

### 8.5 Coverage targets
- Contracts: line ≥ 95%, branch ≥ 90%
- `forge coverage` artifact archived per CI run

## 9. Build Sequence (Phase A / v1)

### Band 1 — Repo prep (T1–T3)
1. **T1**: Cut `legacy/v0.7-arc-fx-gateway` from current `main` HEAD; push to remote. Rename GitHub repo `arcora-v0.7-shared-vault-pool` → `arcoradex`.
2. **T2**: Delete files per §3.1 in one commit; rewrite `README.md` with new ArcoraDEX product description placeholder.
3. **T3**: Move `assets/` SVGs into `app/public/brand/` (creates `app/` skeleton with `public/` only at this point); commit Tailwind theme placeholder for brand colors.

### Band 2 — Contracts (T4–T11) — TDD red→green per task
4. **T4**: `IArcoraDexRegistry` interface + empty `ArcoraDexRegistry` skeleton
5. **T5**: `ArcoraDexRegistry` implementation + tests (~14, adapted from StablecoinRegistry suite)
6. **T6**: `IArcoraDexLP` + `ArcoraDexLP` implementation + tests (~6)
7. **T7**: `IArcoraDexPool` interface (signatures only)
8. **T8**: `ArcoraDexPool` skeleton — deposit/withdraw/pause + LP child deploy + first-deposit 1000 burn (~10 tests)
9. **T9**: `ArcoraDexPool.quote*` + cross-decimal oracle math (~7 tests)
10. **T10**: `ArcoraDexPool.swap()` + fee split with tokenOut-side fee (~8 tests)
11. **T11**: PriceGuard per-token + `syncAcceptedPrice` + `setSwapFeeBps` / `setProtocolFeeShareBps` cap enforcement (~6 tests)

### Band 3 — Fuzz, invariant, deploy, app, smoke (T12–T16)
12. **T12**: Fuzz suite (5 tests, ≥1000 runs each)
13. **T13**: Invariant suite (`PoolHandler` + 4 invariants, **1024×128 config**)
14. **T14**: `DeployArcoraDex.s.sol` + 7 mocks + 7 feeds + $10k owner seed per token; `SmokeArcoraDex.s.sol` 7-flow runner
15. **T15**: Live Arc-testnet deploy + 7-flow smoke + rollout doc (`docs/rollouts/2026-05-XX-arcoradex-deploy.md`) + VPS keeper systemd rename
16. **T16**: Frontend v1 (`/`, `/liquidity`, `/pool`) + Vercel preview + `.env.example` + brand theme wired

### Dependencies
- T1–T3 fast, can be parallel
- T4 → T5 (interface first, impl second per TDD)
- T6 independent (parallel-safe with T4–T5)
- T7 → T8 → T9 → T10 → T11 (sequential; each adds state to previous)
- T12, T13 after all contract work green
- T14 after contracts green
- T15 after T14 (broadcast)
- T16 can start after T8 once ABIs stabilize

### Definition of Done (v1 release)
- ✅ `forge test` green; line coverage ≥ 95%
- ✅ `forge snapshot --check` no regression
- ✅ Live on Arc testnet; 7-flow smoke logged in rollout doc
- ✅ Vercel preview functional: connect wallet → swap → deposit LP → withdraw LP round-trip works
- ✅ VPS keeper `arcoradex-feeds.timer` active; `journalctl` clean
- ✅ README rewritten as ArcoraDEX product
- ✅ Rollout doc committed
- ✅ Phases B/C/D/E roadmap captured (this spec, §10)

## 10. Future Phases Roadmap

### Phase B — TypeScript SDK (`@arcoradex/sdk`)
NPM-published, monorepo workspace. viem-based, chain-agnostic, tree-shakable.

```ts
const sdk = createArcoraDex({ chain: arcTestnet, rpcUrl, account });
await sdk.quoteSwap({ tokenIn, tokenOut, amountIn });
await sdk.swap({ tokenIn, tokenOut, amountIn, slippageBps, deadline });
await sdk.deposit({ token, amount, slippageBps });
await sdk.withdraw({ tokenOut, lpAmount, slippageBps });
sdk.getPoolStats();
sdk.subscribeSwaps(handler);
```

The frontend (`app/`) is refactored to consume the SDK once it exists, removing duplication.

**Trigger**: v1 stable on testnet for 30 days, or third-party integration demand. **Estimate**: 1–2 weeks.

### Phase C — Analytics & dashboard
`app/dashboard` route — TVL, 24h/7d/30d volume, LP APY chart, fee revenue split, top swap pairs, recent swaps table.

Indexing decision deferred until phase start:
- **C-1**: The Graph subgraph (verify Arc support)
- **C-2**: Custom Postgres indexer (Node worker on Vercel cron / VPS)

**Trigger**: usage signal (≥100 unique LPs or meaningful TVL on mainnet). **Estimate**: 2–3 weeks.

### Phase D — Docs site (`docs.arcoradex.xyz`)
Mintlify or Docusaurus, separate `arcoradex/docs` repo (or subfolder).

Sections: product overview, quickstart, protocol mechanics (distilled from this spec), SDK reference (typedoc), contract reference (`forge doc`), audit report (when available), deployment addresses matrix, FAQ.

Branding: ArcoraLabs umbrella; `docs.arcorapay.xyz` and `docs.arcoradex.xyz` share a header with product switcher.

**Trigger**: starts the moment Phase B (SDK) publishes v1.0. **Estimate**: 1–2 weeks initial, ongoing maintenance.

### Phase E — Audit & Mainnet
Runs in parallel with B/C once v1 testnet stabilizes:
- Third-party audit (Trail of Bits / Spearbit / OpenZeppelin tier; rough scope ~600 lines)
- Audit fix cycle
- Arc mainnet deploy (real Chainlink feeds, real stable token addresses)
- Bug bounty (Immunefi mid tier)

**Trigger**: contracts frozen post-v1; audit budget approved. **Estimate**: 6–10 weeks including audit.

### Roadmap summary

| Phase | Output | Prerequisite | Estimate |
|---|---|---|---|
| **A (v1)** | Contracts + minimal UI | This spec approved | 2–3 weeks |
| **B** | SDK | A + 30-day stable testnet | 1–2 weeks |
| **C** | Analytics dashboard | A + indexer decision | 2–3 weeks |
| **D** | Docs site | B (SDK required) | 1–2 weeks |
| **E** | Audit + mainnet | A frozen, audit budget approved | 6–10 weeks |

## 11. Open Questions / Deferred Decisions

- **Domain & DNS**: `arcoradex.xyz`, `arcoradex.io`, or product subdomain under `arcoralabs.xyz`. Decided at Phase D start.
- **GitHub org migration**: `Kubudak90/arcoradex` → `arcoralabs/arcoradex` timing (post-v1).
- **Public repo flip**: private until v1 stable on testnet, then public.
- **Indexer choice** (Phase C): subgraph vs custom Postgres.
- **Audit vendor & budget** (Phase E).
- **Dynamic-fee-on-oracle-drift mechanism**: explored as a Trader Joe LB analog for toxic-flow protection; not in v1 scope, candidate for v2 if oracle drift becomes an operational issue.

## 12. Out of Scope (explicit non-goals for v1)

- Mobile app
- Multi-chain deployment (Arc only initially)
- Liquidity mining / token incentives
- Concentrated liquidity / range orders
- Limit orders or stop-loss
- Aggregator routing (single-hop oracle pricing only)
- Governance token
- Staking module
