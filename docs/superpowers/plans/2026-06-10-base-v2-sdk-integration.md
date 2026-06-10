# Base V2 SDK Integration (Plan 4a — SDK V2 Module) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing `@arcoralabs/dex-sdk` (currently V1/Arc-only) with a **V2 module** that binds the live Base Sepolia V2 ledger (Pool `0x63FD…7820`, Registry `0xae1f…14e2`, LP `0x02aF…c844`, chainId 84532) and exposes the spec §9 user-facing surface in TypeScript: the V2 ABIs, a `baseSepolia` chain + a multi-chain address map that adds 84532 WITHOUT touching Arc 5042002, V2 read/quote/write action wrappers (`reserveHealth`, `maxSwapOut`, `maxWithdraw`, `quoteSwapV2`, `quoteWithdrawV2`, `swap`, `deposit`, `withdrawSingle`, `withdrawProportional`), reserve-health + marginal-fee presentation helpers (so the app can render "75%-100% → 0.05%" bands and an estimated dynamic fee), a `createArcoraDexV2` client factory + a parallel React hook layer (`./react/v2`), V2 errors (`OracleUnsafe`, `ReserveFloorBreached`, `DepositCapExceeded`, `InsufficientLiquidity`), and tests including a **live Base Sepolia integration test that gates on an env RPC and skips cleanly without it** (mirrors `test/integration/addresses-live.test.ts`). The V1/Arc surface — every existing export, action, hook, and test — stays byte-for-byte unchanged and green; V2 is purely additive.

**Architecture:** V2 is a sibling namespace inside the same package, not a fork. New ABIs (`abi/v2/pool.ts`, `abi/v2/registry.ts`) are hand-written `parseAbi` arrays transcribed verbatim from `contracts/src/v2/interfaces/IArcoraDexPoolV2.sol` / `IArcoraDexRegistryV2.sol` — including the FOUR-return quote shape `(amountOut, protocolFee, feeUsd1e18, postHealthBps)`, the `(netOut, grossUsd1e18)`/`(lpAmount, netOut)` max views, `reserveHealth → healthBps`, the V2 events (`Swapped` carries `feeUsd1e18` + `protocolFeeAmtOut`; `WithdrewSingle`/`WithdrewProportional` are distinct), and the V2 custom errors for typed decoding. A second address map `DEFAULT_ADDRESSES_V2: Record<number, ArcoraDexAddresses>` keyed by `baseSepolia.id` lives in `addresses.v2.ts`; the V1 `DEFAULT_ADDRESSES` is never edited so the live Arc test keeps passing. A `createArcoraDexV2` factory mirrors `createArcoraDex` but wires the V2 actions and resolves from `DEFAULT_ADDRESSES_V2`; the two clients coexist (an app holds whichever the connected chain selects). V2 actions reuse the audited cross-cutting machinery unchanged — `ensureAllowance` (LP `MINTER()` anchor check still valid), `minOut`/`deadline`, `assertReceiptOk` typed-revert recovery, and `parseContractError` (extended with a V2 selector table). Presentation helpers are pure functions over the quote tuple + registry config: `feeBandsForToken` (from `TokenConfigV2.bands`), `estimatedFeePct` (feeUsd1e18 ÷ grossUsd1e18 → bps), `healthLabel`/`healthBand` (bps → "Healthy/Caution/…"), and an `applyMaxGuard` that the app's Max button / over-max warning consume. The §9 "refresh quote before submit" and "never submit over-max" requirements are enforced in the V2 write actions themselves (the action re-quotes immediately before the write, exactly as V1 `swap`/`withdraw` already do) so the contract-as-final-enforcement layer is backstopped by an SDK-level guard, while §9's UI obligations (display, Max button, warning) are deferred to Plan 4b, which consumes these helpers.

**Tech Stack:** TypeScript `^5.7`, viem `^2.20`, vitest `^2.1` (forks pool, `singleFork`, `globalSetup` anvil — unchanged), `@tanstack/react-query` + wagmi for the React layer, `@testing-library/react` + happy-dom for hook tests. No new runtime dependency. Package manager is **pnpm workspaces**; the SDK package filter is **`@arcoralabs/dex-sdk`** (NOT the directory name) — every command uses `pnpm --filter @arcoralabs/dex-sdk <script>`. The live integration test uses viem `createPublicClient` + `http(process.env.BASE_SEPOLIA_RPC)` and `describe.skipIf(!process.env.BASE_SEPOLIA_RPC)` so default CI (no RPC) skips cleanly, mirroring the existing `SKIP_LIVE_TESTS` pattern.

**Out of scope (other plans / explicitly OUT):**
- **The app V2 UX (Plan 4b)** — chain-switch UI, V2 swap/deposit/single-withdraw/proportional-withdraw flows, the reserve-health + dynamic-fee DISPLAY, the `Max` button wiring, the over-max WARNING banner, quote-refresh-on-submit UI, and the oracle-unsafe → proportional-exit fallback screen. This plan ships the SDK primitives those screens consume; the final section sketches 4b's tasks at a high level.
- The on-chain V2 contracts, oracle adapters, and the Base Sepolia deploy (done — see `docs/rollouts/2026-06-10-base-sepolia-v2-deploy.md`).
- Off-chain monitoring / the third-reference divergence alert (spec §12).
- **Base mainnet** addresses (spec §13 step 4 — a later plan once the mainnet ledger exists). Only Base Sepolia 84532 is wired here.
- Arc V2 deployment (spec §1, §2 — a later, independent project).

---

## Scope Decision (4a-only vs combined) — DECIDED: 4a-only (SDK), this plan

The combined SDK+app work is too large for one reviewable plan, and the app strictly depends on the SDK V2 bindings (the app cannot render reserve health, an estimated fee, or a floor-safe Max without the SDK's `reserveHealth`/`maxSwapOut`/`maxWithdraw`/`quoteSwapV2` wrappers and the band/health helpers). Per the input's bias, this plan is **Plan 4a = the SDK V2 module only**. Plan 4b (the app V2 UX) is a later, separate plan that imports this module; its tasks are outlined at the end of this document so the controller can spin it up once 4a merges. This ordering also de-risks: the SDK gets a live Base Sepolia integration test proving the bindings work against the real ledger BEFORE any UI is built on top.

---

## File Structure

| File | Responsibility (one each) |
|------|---------------------------|
| `packages/sdk/src/chains/baseSepolia.ts` | The `baseSepolia` viem chain (id 84532, name, native ETH, default + the reliable `publicnode` RPC, BaseScan explorer, `testnet: true`). |
| `packages/sdk/src/abi/v2/pool.ts` | `poolAbiV2` — `parseAbi` transcription of `IArcoraDexPoolV2`: V2 views (`reserveHealth`, `maxSwapOut`, `maxWithdraw`, `quoteSwapV2`, `quoteWithdrawV2`, `reserves`, `protocolFeesAccrued`, `totalReservesUSD`, `paused`, `LP`, `REGISTRY`), writes (`deposit`, `swap`, `withdrawSingle`, `withdrawProportional`), V2 events, V2 custom errors. |
| `packages/sdk/src/abi/v2/registry.ts` | `registryAbiV2` — `TokenConfigV2` struct + `Band` struct + `tokens`/`tokensLength`/`tokenConfig`/`isActive`/`pool` reads. |
| `packages/sdk/src/addresses.v2.ts` | `DEFAULT_ADDRESSES_V2: Record<number, ArcoraDexAddresses>` keyed by `baseSepolia.id` → the live 84532 ledger. Reuses the V1 `ArcoraDexAddresses` shape. V1 `addresses.ts` is NOT edited. |
| `packages/sdk/src/tokens/known.v2.ts` | `KNOWN_TOKENS_V2` — the live Base Sepolia USDC/USDT/EURC token addresses → labels (separate from the Arc `KNOWN_TOKENS`). |
| `packages/sdk/src/types.v2.ts` | V2 result/event/view types: `SwapResultV2`, `WithdrawSingleResult`, `WithdrawProportionalResult`, `SwappedEventV2`, `WithdrewSingleEvent`, `WithdrewProportionalEvent`, `QuoteV2`, `MaxSwapOut`, `MaxWithdraw`, `ReserveHealth`, `TokenConfigV2`, `FeeBand`, `PoolStatsV2`, `TokenInfoV2`. |
| `packages/sdk/src/errors.v2.ts` | V2 error classes (`OracleUnsafeError`, `ReserveFloorBreachedError`, `DepositCapExceededError`) + `parseContractErrorV2` (V1 reuse + V2 selector table). |
| `packages/sdk/src/actions/v2/quoteSwapV2.ts` | `quoteSwapV2` → `QuoteV2 {amountOut, protocolFee, feeUsd1e18, postHealthBps}`. |
| `packages/sdk/src/actions/v2/quoteWithdrawV2.ts` | `quoteWithdrawV2` → `QuoteV2`. |
| `packages/sdk/src/actions/v2/reserveHealth.ts` | `reserveHealth(tokenOut)` → `{ healthBps }`. |
| `packages/sdk/src/actions/v2/maxSwapOut.ts` | `maxSwapOut(tokenOut)` → `{ netOut, grossUsd1e18 }`. |
| `packages/sdk/src/actions/v2/maxWithdraw.ts` | `maxWithdraw(tokenOut, account)` → `{ lpAmount, netOut }`. |
| `packages/sdk/src/actions/v2/getTokensV2.ts` | Registry read → `TokenInfoV2[]` incl. `bands`, `minimumReserveUsd`, `targetReserveUsd`, `depositCapUsd`, `isActive`. |
| `packages/sdk/src/actions/v2/getPoolStatsV2.ts` | `PoolStatsV2 {navUsd1e18, lpSupply, lpPriceUsd1e18, protocolFeeShareBps, paused}`. |
| `packages/sdk/src/actions/v2/swapV2.ts` | V2 `swap` write: re-quote → `minOut` → write → typed-revert recovery → decode `Swapped`. |
| `packages/sdk/src/actions/v2/depositV2.ts` | V2 `deposit` write: ensureAllowance → re-quote (deposit) → write → decode `Deposited`. |
| `packages/sdk/src/actions/v2/withdrawSingleV2.ts` | V2 `withdrawSingle` write: max-guard + re-quote → write → decode `WithdrewSingle`. |
| `packages/sdk/src/actions/v2/withdrawProportionalV2.ts` | V2 `withdrawProportional` write (no oracle/quote — the §11 fallback) → decode `WithdrewProportional` (returns `amounts[]`). |
| `packages/sdk/src/present/index.ts` | Pure presentation helpers: `feeBandsForToken`, `estimatedFeePct`, `healthBand`, `healthLabel`, `applyMaxGuard`, `INITIAL_FEE_SCHEDULE`. |
| `packages/sdk/src/clientV2.ts` | `createArcoraDexV2` factory + `ArcoraDexClientV2` type (wires V2 actions, resolves `DEFAULT_ADDRESSES_V2`). |
| `packages/sdk/src/v2.ts` | The `@arcoralabs/dex-sdk/v2` entrypoint barrel — re-exports the V2 surface (no V1 symbol re-exported, no collision). |
| `packages/sdk/src/react/v2/*` | V2 hooks: `ArcoraDexV2Provider`, `useArcoraDexV2`, `useReserveHealth`, `useQuoteSwapV2`, `useQuoteWithdrawV2`, `useMaxSwapOut`, `useMaxWithdraw`, `useSwapV2`, `useDepositV2`, `useWithdrawSingleV2`, `useWithdrawProportionalV2`, `index.ts` barrel. |
| `packages/sdk/test/unit/v2/*.test.ts` | Unit tests: addresses.v2, abi-v2-shape, present helpers, errors.v2. |
| `packages/sdk/test/integration/v2/*.test.ts` | Anvil integration (against the V2 deploy fixture) + the **live Base Sepolia** test (`addresses-live-v2.test.ts`, env-gated skip). |
| `packages/sdk/test/react/v2/*.test.tsx` | V2 hook tests (mirror the V1 hook test style). |
| `packages/sdk/package.json` | Add the `./v2` and `./react/v2` export conditions (additive; `.` and `./react` unchanged). |
| `docs/superpowers/plans/2026-06-10-base-v2-sdk-integration.md` | This plan. |

All new code is additive under `src/` (V2-suffixed files / `v2/` subdirs) and `test/` (`v2/` subdirs). **No existing V1 file is edited except `package.json` (new export keys only)**; `src/index.ts`, `src/addresses.ts`, `src/client.ts`, and every V1 action/hook/test stay byte-for-byte unchanged so the V1 suite (incl. `addresses-live.test.ts`) stays green.

---

### Task 0: Branch + green baseline + pin the live V2 facts

**Files:** none modified; verification only.

- [ ] **Step 1: Branch from the current SDK tip**

Run:
```bash
git checkout -b feat/base-v2-sdk-integration && git log --oneline -1
```
Expected: a clean branch off the tip that already contains the V1 SDK + the V2 contracts/deploy docs. If a `feat/base-v2-sepolia-deploy` branch is the integration base instead of `main`, branch from there and record which.

- [ ] **Step 2: Establish the SDK baseline (must stay green throughout)**

Run:
```bash
pnpm --filter @arcoralabs/dex-sdk test 2>&1 | tail -5
```
Expected: all existing V1 SDK suites pass (the live Arc test `addresses-live.test.ts` skips only if `SKIP_LIVE_TESTS=1`; otherwise it hits Arc). Record the baseline pass count `<N>`. Then:
```bash
pnpm --filter @arcoralabs/dex-sdk typecheck && pnpm --filter @arcoralabs/dex-sdk lint
```
Expected: both clean. This is the line every later task must keep green.

- [ ] **Step 3: Pin the live Base Sepolia ledger (source of truth for Tasks 2 & 5)**

From `docs/rollouts/2026-06-10-base-sepolia-v2-deploy.md` (chainId 84532), the values this plan hardcodes:
```text
Pool      0x63FD6180dC6Aa5aE2941Bd28D2dc34c54F2b7820
Registry  0xae1f10b007cDC4131797A45232a3D52Ff2C314e2
LP        0x02aFC4c2c72ecE2049725DA2bd9080EF6285c844
Tokens:
  USDC    0x3a98d8adC295d90171e9DA93D411dEa95674c867
  USDT    0x7110315D229C7CE655399703ACbA8E67f1d5C0c0
  EURC    0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7
Reliable read RPC (deploy note: public sepolia.base.org lagged):
  https://base-sepolia-rpc.publicnode.com
Registry lists 3 tokens; pool unpaused; NAV ~ $15,009 at bootstrap.
```
No code in this step. These are checksummed exactly as in the rollout doc; do not let them drift, and store them ONLY here + in `addresses.v2.ts` / `known.v2.ts` (no Arc-testnet hardcoding in the V2 flow — §15).

- [ ] **Step 4: Create the V2 directories**

Run:
```bash
mkdir -p packages/sdk/src/abi/v2 packages/sdk/src/actions/v2 packages/sdk/src/react/v2 packages/sdk/src/present \
         packages/sdk/test/unit/v2 packages/sdk/test/integration/v2 packages/sdk/test/react/v2
git status --short
```
Expected: directories created (empty — nothing staged yet).

---

### Task 1: `baseSepolia` chain definition

**Files:** create `packages/sdk/src/chains/baseSepolia.ts`; create `packages/sdk/test/unit/v2/baseSepolia.test.ts`.

- [ ] **Step 1: Write the failing chain test FIRST (TDD)**

Create `packages/sdk/test/unit/v2/baseSepolia.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { baseSepolia } from "../../../src/chains/baseSepolia";

describe("baseSepolia chain", () => {
  it("is chainId 84532, testnet, ETH-native", () => {
    expect(baseSepolia.id).toBe(84532);
    expect(baseSepolia.testnet).toBe(true);
    expect(baseSepolia.nativeCurrency.symbol).toBe("ETH");
    expect(baseSepolia.rpcUrls.default.http[0]).toMatch(/^https:\/\//);
  });
});
```
Run `pnpm --filter @arcoralabs/dex-sdk test baseSepolia` — expected: FAIL (module not found).

- [ ] **Step 2: Implement the chain (mirror `chains/arcTestnet.ts`)**

Create `packages/sdk/src/chains/baseSepolia.ts`:
```ts
import { defineChain } from "viem";

/**
 * Base Sepolia (chainId 84532) — the live V2 integration target.
 * Default RPC is the reliable publicnode endpoint: the deploy note
 * (docs/rollouts/2026-06-10-base-sepolia-v2-deploy.md) flagged heavy
 * read-after-write lag on the public `sepolia.base.org`, so reads default to
 * `base-sepolia-rpc.publicnode.com`. The app may override via env.
 */
export const baseSepolia = /*#__PURE__*/ defineChain({
  id: 84532,
  name: "Base Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://base-sepolia-rpc.publicnode.com"] },
  },
  blockExplorers: {
    default: { name: "BaseScan", url: "https://sepolia.basescan.org" },
  },
  testnet: true,
});
```
Run `pnpm --filter @arcoralabs/dex-sdk test baseSepolia` — expected: PASS.

---

### Task 2: V2 address map + known tokens (live 84532 ledger)

**Files:** create `packages/sdk/src/addresses.v2.ts`, `packages/sdk/src/tokens/known.v2.ts`; create `packages/sdk/test/unit/v2/addresses.v2.test.ts`.

- [ ] **Step 1: Write the failing address test (checksum-literal assertions, mirror V1 `addresses.test.ts`)**

Create `packages/sdk/test/unit/v2/addresses.v2.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { DEFAULT_ADDRESSES_V2 } from "../../../src/addresses.v2";
import { baseSepolia } from "../../../src/chains/baseSepolia";

describe("DEFAULT_ADDRESSES_V2", () => {
  it("points baseSepolia at the live V2 deployment (checksummed literals)", () => {
    const a = DEFAULT_ADDRESSES_V2[baseSepolia.id]!;
    expect(a.pool).toBe("0x63FD6180dC6Aa5aE2941Bd28D2dc34c54F2b7820");
    expect(a.registry).toBe("0xae1f10b007cDC4131797A45232a3D52Ff2C314e2");
    expect(a.lp).toBe("0x02aFC4c2c72ecE2049725DA2bd9080EF6285c844");
  });

  it("does not collide with the V1 Arc map (separate object)", async () => {
    const { DEFAULT_ADDRESSES } = await import("../../../src/addresses");
    expect(DEFAULT_ADDRESSES_V2[baseSepolia.id]).toBeDefined();
    // 84532 is absent from the V1 map; 5042002 is absent from the V2 map.
    expect(DEFAULT_ADDRESSES[baseSepolia.id]).toBeUndefined();
    expect(DEFAULT_ADDRESSES_V2[5042002]).toBeUndefined();
  });
});
```
Run — expected: FAIL (module not found).

- [ ] **Step 2: Implement the V2 address map (reuse the V1 `ArcoraDexAddresses` shape)**

Create `packages/sdk/src/addresses.v2.ts`:
```ts
import { baseSepolia } from "./chains/baseSepolia";
import type { ArcoraDexAddresses } from "./addresses";

/**
 * Live Base Sepolia V2 ledger (chainId 84532), deployed 2026-06-10
 * (docs/rollouts/2026-06-10-base-sepolia-v2-deploy.md — the SECOND, working
 * broadcast; the abandoned upgraded-Pyth broadcast is NOT this set). Reuses the
 * V1 ArcoraDexAddresses {pool, registry, lp} shape. Kept SEPARATE from the V1
 * DEFAULT_ADDRESSES (Arc 5042002) so the two chains coexist and the V1/Arc live
 * test stays green.
 */
const BASE_SEPOLIA_V2: ArcoraDexAddresses = {
  pool:     "0x63FD6180dC6Aa5aE2941Bd28D2dc34c54F2b7820",
  registry: "0xae1f10b007cDC4131797A45232a3D52Ff2C314e2",
  lp:       "0x02aFC4c2c72ecE2049725DA2bd9080EF6285c844",
};

export const DEFAULT_ADDRESSES_V2: Record<number, ArcoraDexAddresses> = {
  [baseSepolia.id]: BASE_SEPOLIA_V2,
};
```

- [ ] **Step 2b: Implement the V2 known tokens**

Create `packages/sdk/src/tokens/known.v2.ts`:
```ts
import type { KnownTokenMeta } from "./known";

/** Live Base Sepolia (84532) V2 token addresses → labels (deploy 2026-06-10).
 *  Separate from the Arc KNOWN_TOKENS so the maps never cross chains. */
export const KNOWN_TOKENS_V2: Record<`0x${string}`, KnownTokenMeta> = {
  "0x3a98d8adC295d90171e9DA93D411dEa95674c867": { symbol: "USDC", name: "USD Coin" },
  "0x7110315D229C7CE655399703ACbA8E67f1d5C0c0": { symbol: "USDT", name: "Tether USD" },
  "0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7": { symbol: "EURC", name: "Euro Coin" },
};
```
Run `pnpm --filter @arcoralabs/dex-sdk test addresses.v2` — expected: PASS.

---

### Task 3: V2 ABIs (verbatim from the interfaces)

**Files:** create `packages/sdk/src/abi/v2/pool.ts`, `packages/sdk/src/abi/v2/registry.ts`; create `packages/sdk/test/unit/v2/abi.v2.test.ts`.

- [ ] **Step 1: Write the failing ABI-shape test (asserts the 4-return quote tuple + max views decode)**

Create `packages/sdk/test/unit/v2/abi.v2.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import {
  encodeFunctionResult,
  decodeFunctionResult,
  getAbiItem,
} from "viem";
import { poolAbiV2 } from "../../../src/abi/v2/pool";

describe("poolAbiV2", () => {
  it("quoteSwapV2 returns the 4-tuple (amountOut, protocolFee, feeUsd1e18, postHealthBps)", () => {
    const item = getAbiItem({ abi: poolAbiV2, name: "quoteSwapV2" });
    expect(item && "outputs" in item && item.outputs).toHaveLength(4);
    const encoded = encodeFunctionResult({
      abi: poolAbiV2,
      functionName: "quoteSwapV2",
      result: [1n, 2n, 3n, 9000n],
    });
    const decoded = decodeFunctionResult({
      abi: poolAbiV2,
      functionName: "quoteSwapV2",
      data: encoded,
    }) as readonly bigint[];
    expect(decoded).toEqual([1n, 2n, 3n, 9000n]);
  });

  it("maxWithdraw returns (lpAmount, netOut) and reserveHealth returns healthBps", () => {
    expect(getAbiItem({ abi: poolAbiV2, name: "maxWithdraw" })).toBeDefined();
    expect(getAbiItem({ abi: poolAbiV2, name: "maxSwapOut" })).toBeDefined();
    expect(getAbiItem({ abi: poolAbiV2, name: "reserveHealth" })).toBeDefined();
    expect(getAbiItem({ abi: poolAbiV2, name: "withdrawSingle" })).toBeDefined();
    expect(getAbiItem({ abi: poolAbiV2, name: "withdrawProportional" })).toBeDefined();
  });
});
```
Run — expected: FAIL (module not found).

- [ ] **Step 2: Write `poolAbiV2` (transcribe `IArcoraDexPoolV2.sol` exactly)**

Create `packages/sdk/src/abi/v2/pool.ts` — names/types match the interface (note `swap` takes a `recipient`; `quote*V2` return four values; events carry `feeUsd1e18`):
```ts
import { parseAbi } from "viem";

export const poolAbiV2 = parseAbi([
  // ── V2 views ──
  "function reserveHealth(address token) view returns (uint256 healthBps)",
  "function maxSwapOut(address tokenOut) view returns (uint256 netOut, uint256 grossUsd1e18)",
  "function maxWithdraw(address tokenOut, address account) view returns (uint256 lpAmount, uint256 netOut)",
  "function quoteSwapV2(address tokenIn, address tokenOut, uint256 amountIn) view returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps)",
  "function quoteWithdrawV2(address tokenOut, uint256 lpAmount) view returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps)",
  "function reserves(address token) view returns (uint256)",
  "function protocolFeesAccrued(address token) view returns (uint256)",
  "function totalReservesUSD() view returns (uint256)",
  "function protocolFeeShareBps() view returns (uint16)",
  "function paused() view returns (bool)",
  "function pauseGuardian() view returns (address)",
  "function LP() view returns (address)",
  "function REGISTRY() view returns (address)",
  // ── writes ──
  "function deposit(address token, uint256 amount, uint256 minLpOut, uint256 deadline) returns (uint256 lpMinted)",
  "function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline, address recipient) returns (uint256 amountOut)",
  "function withdrawSingle(address tokenOut, uint256 lpAmount, uint256 minTokenOut, uint256 deadline) returns (uint256 amountOut)",
  "function withdrawProportional(uint256 lpAmount, uint256 deadline) returns (uint256[] amounts)",
  // ── events ──
  "event Deposited(address indexed user, address indexed token, uint256 amountIn, uint256 lpMinted, uint256 navBefore1e18, uint256 navAfter1e18)",
  "event Swapped(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 feeUsd1e18, uint256 protocolFeeAmtOut, address recipient)",
  "event WithdrewSingle(address indexed user, address indexed tokenOut, uint256 lpBurned, uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18)",
  "event WithdrewProportional(address indexed user, uint256 lpBurned)",
  // ── V2 custom errors (for typed revert decoding via parseContractErrorV2) ──
  "error ZeroAmount()",
  "error ZeroAddress()",
  "error SameToken(address token)",
  "error DeadlinePassed()",
  "error PoolPaused()",
  "error TokenNotActive(address token)",
  "error OracleUnsafe(address token)",
  "error InsufficientOutput(uint256 actual, uint256 minOut)",
  "error InsufficientLpOut(uint256 actual, uint256 minLpOut)",
  "error InsufficientTokenOut(uint256 actual, uint256 minTokenOut)",
  "error InsufficientLiquidity(address token, uint256 requested, uint256 available)",
  "error ReserveFloorBreached(address token)",
  "error DepositCapExceeded(address token)",
  "error FirstDepositTooSmall(uint256 usdValue, uint256 minimumLiquidity)",
  "error EarlyWithdraw(uint256 unlockAt, uint256 nowAt)",
]);
```

- [ ] **Step 3: Write `registryAbiV2` (transcribe `IArcoraDexRegistryV2.sol` incl. nested `Band`)**

Create `packages/sdk/src/abi/v2/registry.ts`. The `Band` struct field names/types are transcribed VERBATIM from the verified `contracts/src/v2/lib/FeeBandMathV2.sol` — `Band { uint16 upperHealthBps; uint16 rateBps; }` (confirmed: NOT `feeBps`, and both fields are `uint16`, not `uint256`). The `TokenConfigV2` order matches `IArcoraDexRegistryV2.sol` exactly (`decimals, isActive, adapter, minimumReserveUsd, targetReserveUsd, depositCapUsd, bands`):
```ts
import { parseAbi } from "viem";

// Band fields are verbatim from contracts/src/v2/lib/FeeBandMathV2.sol:
//   struct Band { uint16 upperHealthBps; uint16 rateBps; }
export const registryAbiV2 = parseAbi([
  "struct Band { uint16 upperHealthBps; uint16 rateBps; }",
  "struct TokenConfigV2 { uint8 decimals; bool isActive; address adapter; uint256 minimumReserveUsd; uint256 targetReserveUsd; uint256 depositCapUsd; Band[] bands; }",
  "function tokens(uint256 i) view returns (address)",
  "function tokensLength() view returns (uint256)",
  "function tokenConfig(address token) view returns (TokenConfigV2)",
  "function isActive(address token) view returns (bool)",
  "function pool() view returns (address)",
]);
```
Run `pnpm --filter @arcoralabs/dex-sdk test abi.v2` — expected: PASS. (If a future contract change renames a `Band` field, the live `getTokensV2` decode in Task 9 catches the mismatch against the real Registry.)

---

### Task 4: V2 types + V2 errors

**Files:** create `packages/sdk/src/types.v2.ts`, `packages/sdk/src/errors.v2.ts`; create `packages/sdk/test/unit/v2/errors.v2.test.ts`.

- [ ] **Step 1: Write the V2 result/view types**

Create `packages/sdk/src/types.v2.ts`:
```ts
import type { Hash, TransactionReceipt } from "viem";

/** The shared §9 quote shape returned by quoteSwapV2 / quoteWithdrawV2. */
export interface QuoteV2 {
  amountOut: bigint;
  protocolFee: bigint;
  /** Total dynamic fee in USD (1e18), summed across the marginal bands crossed (§7). */
  feeUsd1e18: bigint;
  /** Output reserve health AFTER the transaction, in bps (0..10000). */
  postHealthBps: number;
}

export interface ReserveHealth { healthBps: number }
export interface MaxSwapOut { netOut: bigint; grossUsd1e18: bigint }
export interface MaxWithdraw { lpAmount: bigint; netOut: bigint }

/** Mirrors FeeBandMathV2.Band { uint16 upperHealthBps; uint16 rateBps }. */
export interface FeeBand { upperHealthBps: number; rateBps: number }

export interface TokenConfigV2 {
  decimals: number;
  isActive: boolean;
  adapter: `0x${string}`;
  minimumReserveUsd: bigint;
  targetReserveUsd: bigint;
  depositCapUsd: bigint;
  bands: FeeBand[];
}

export interface TokenInfoV2 extends TokenConfigV2 {
  address: `0x${string}`;
  symbol: string;
  name: string;
}

export interface PoolStatsV2 {
  navUsd1e18: bigint;
  lpSupply: bigint;
  lpPriceUsd1e18: bigint;
  protocolFeeShareBps: number;
  paused: boolean;
}

export interface SwappedEventV2 {
  user: `0x${string}`;
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  amountIn: bigint;
  amountOut: bigint;
  feeUsd1e18: bigint;
  protocolFeeAmtOut: bigint;
  recipient: `0x${string}`;
  blockNumber: bigint;
  txHash: Hash;
  logIndex: number;
}

export interface WithdrewSingleEvent {
  user: `0x${string}`;
  tokenOut: `0x${string}`;
  lpBurned: bigint;
  amountOut: bigint;
  protocolFee: bigint;
  feeUsd1e18: bigint;
  blockNumber: bigint;
  txHash: Hash;
  logIndex: number;
}

export interface WithdrewProportionalEvent {
  user: `0x${string}`;
  lpBurned: bigint;
  blockNumber: bigint;
  txHash: Hash;
  logIndex: number;
}

export interface SwapResultV2 { approveHash?: Hash; hash: Hash; receipt: TransactionReceipt; amountOut: bigint; event: SwappedEventV2 }
export interface DepositResultV2 { approveHash?: Hash; hash: Hash; receipt: TransactionReceipt; lpMinted: bigint }
export interface WithdrawSingleResult { hash: Hash; receipt: TransactionReceipt; amountOut: bigint; event: WithdrewSingleEvent }
export interface WithdrawProportionalResult { hash: Hash; receipt: TransactionReceipt; amounts: bigint[]; event: WithdrewProportionalEvent }
```

- [ ] **Step 2: Write the failing V2 error test**

Create `packages/sdk/test/unit/v2/errors.v2.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import {
  OracleUnsafeError,
  ReserveFloorBreachedError,
  DepositCapExceededError,
  parseContractErrorV2,
} from "../../../src/errors.v2";
import { SlippageExceededError, PoolPausedError } from "../../../src/errors";

const wrap = (errorName: string, args: readonly unknown[]) => ({ data: { errorName, args } });

describe("parseContractErrorV2", () => {
  it("maps V2-only selectors to typed errors", () => {
    const tok = "0x3a98d8adC295d90171e9DA93D411dEa95674c867" as const;
    expect(parseContractErrorV2(wrap("OracleUnsafe", [tok]))).toBeInstanceOf(OracleUnsafeError);
    expect(parseContractErrorV2(wrap("ReserveFloorBreached", [tok]))).toBeInstanceOf(ReserveFloorBreachedError);
    expect(parseContractErrorV2(wrap("DepositCapExceeded", [tok]))).toBeInstanceOf(DepositCapExceededError);
  });

  it("delegates shared selectors to the V1 table", () => {
    expect(parseContractErrorV2(wrap("InsufficientOutput", [1n, 2n]))).toBeInstanceOf(SlippageExceededError);
    expect(parseContractErrorV2(wrap("PoolPaused", []))).toBeInstanceOf(PoolPausedError);
  });
});
```
Run — expected: FAIL.

- [ ] **Step 3: Implement `errors.v2.ts` (new classes + V2 selector table that falls back to V1)**

Create `packages/sdk/src/errors.v2.ts`. Reuse the V1 cause-chain walker by importing `parseContractError` for the fallback, and add the three V2-only classes:
```ts
import {
  ArcoraDexError,
  parseContractError,
} from "./errors";

export class OracleUnsafeError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`) {
    super(`Oracle is unsafe for ${token}: this path is unavailable; use proportional withdrawal.`);
    this.name = "OracleUnsafeError";
  }
}

export class ReserveFloorBreachedError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`) {
    super(`Reserve floor breached for ${token}: amount exceeds the floor-safe maximum.`);
    this.name = "ReserveFloorBreachedError";
  }
}

export class DepositCapExceededError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`) {
    super(`Deposit cap exceeded for ${token}.`);
    this.name = "DepositCapExceededError";
  }
}

interface RevertedShape {
  data?: { errorName?: string; args?: readonly unknown[] };
  cause?: RevertedShape;
}

function extractRevertData(err: unknown, depth = 0): { errorName?: string; args: readonly unknown[] } {
  if (depth > 5 || err == null) return { errorName: undefined, args: [] };
  const r = err as RevertedShape;
  if (r?.data?.errorName != null) return { errorName: r.data.errorName, args: r.data.args ?? [] };
  return extractRevertData(r?.cause, depth + 1);
}

export function parseContractErrorV2(err: unknown): ArcoraDexError {
  const { errorName: name, args } = extractRevertData(err);
  switch (name) {
    case "OracleUnsafe":
      return new OracleUnsafeError(args[0] as `0x${string}`);
    case "ReserveFloorBreached":
      return new ReserveFloorBreachedError(args[0] as `0x${string}`);
    case "DepositCapExceeded":
      return new DepositCapExceededError(args[0] as `0x${string}`);
    default:
      // Shared selectors (InsufficientOutput/PoolPaused/TokenNotActive/…) reuse
      // the audited V1 mapping verbatim.
      return parseContractError(err);
  }
}
```
Run `pnpm --filter @arcoralabs/dex-sdk test errors.v2` — expected: PASS.

---

### Task 5: V2 read/quote actions (`reserveHealth`, `maxSwapOut`, `maxWithdraw`, quotes)

**Files:** create the five read/quote actions under `src/actions/v2/`. (The `ArcoraDexClientV2` type lands in Task 8; type each action against a minimal structural client — `{ publicClient, addresses }` — so they compile before the factory exists.)

- [ ] **Step 1: A shared minimal client shape for read actions**

At the top of each read action, accept a structurally-typed client so the actions don't depend on the not-yet-written factory:
```ts
import type { PublicClient } from "viem";
import type { ArcoraDexAddresses } from "../../addresses";
export interface ReadClientV2 { publicClient: PublicClient; addresses: ArcoraDexAddresses }
```
(Implementations may define this once in `src/actions/v2/_readClient.ts` and import it; the final `ArcoraDexClientV2` will be assignable to it.)

- [ ] **Step 2: `reserveHealth`, `maxSwapOut`, `maxWithdraw`**

Create `packages/sdk/src/actions/v2/reserveHealth.ts`:
```ts
import type { ReadClientV2 } from "./_readClient";
import type { ReserveHealth } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { parseContractErrorV2 } from "../../errors.v2";

export async function reserveHealth(
  client: ReadClientV2,
  tokenOut: `0x${string}`,
): Promise<ReserveHealth> {
  try {
    const bps = await client.publicClient.readContract({
      address: client.addresses.pool,
      abi: poolAbiV2,
      functionName: "reserveHealth",
      args: [tokenOut],
    });
    return { healthBps: Number(bps) };
  } catch (e) {
    throw parseContractErrorV2(e);
  }
}
```
Create `packages/sdk/src/actions/v2/maxSwapOut.ts`:
```ts
import type { ReadClientV2 } from "./_readClient";
import type { MaxSwapOut } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { parseContractErrorV2 } from "../../errors.v2";

export async function maxSwapOut(
  client: ReadClientV2,
  tokenOut: `0x${string}`,
): Promise<MaxSwapOut> {
  try {
    const [netOut, grossUsd1e18] = await client.publicClient.readContract({
      address: client.addresses.pool,
      abi: poolAbiV2,
      functionName: "maxSwapOut",
      args: [tokenOut],
    });
    return { netOut, grossUsd1e18 };
  } catch (e) {
    throw parseContractErrorV2(e);
  }
}
```
Create `packages/sdk/src/actions/v2/maxWithdraw.ts`:
```ts
import type { ReadClientV2 } from "./_readClient";
import type { MaxWithdraw } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { parseContractErrorV2 } from "../../errors.v2";

export async function maxWithdraw(
  client: ReadClientV2,
  tokenOut: `0x${string}`,
  account: `0x${string}`,
): Promise<MaxWithdraw> {
  try {
    const [lpAmount, netOut] = await client.publicClient.readContract({
      address: client.addresses.pool,
      abi: poolAbiV2,
      functionName: "maxWithdraw",
      args: [tokenOut, account],
    });
    return { lpAmount, netOut };
  } catch (e) {
    throw parseContractErrorV2(e);
  }
}
```

- [ ] **Step 3: `quoteSwapV2` + `quoteWithdrawV2` (the 4-return §9 quote)**

Create `packages/sdk/src/actions/v2/quoteSwapV2.ts`:
```ts
import type { ReadClientV2 } from "./_readClient";
import type { QuoteV2 } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { parseContractErrorV2 } from "../../errors.v2";

export async function quoteSwapV2(
  client: ReadClientV2,
  args: { tokenIn: `0x${string}`; tokenOut: `0x${string}`; amountIn: bigint },
): Promise<QuoteV2> {
  try {
    const [amountOut, protocolFee, feeUsd1e18, postHealthBps] =
      await client.publicClient.readContract({
        address: client.addresses.pool,
        abi: poolAbiV2,
        functionName: "quoteSwapV2",
        args: [args.tokenIn, args.tokenOut, args.amountIn],
      });
    return { amountOut, protocolFee, feeUsd1e18, postHealthBps: Number(postHealthBps) };
  } catch (e) {
    throw parseContractErrorV2(e);
  }
}
```
Create `packages/sdk/src/actions/v2/quoteWithdrawV2.ts` (same shape, `functionName: "quoteWithdrawV2"`, `args: [tokenOut, lpAmount]`).

- [ ] **Step 4: Defer assertions to the integration test**

These actions are exercised against the live ledger / anvil fixture in Task 9 (no anvil mock can fabricate a real oracle-priced quote). Add a placeholder confirming they typecheck:
```bash
pnpm --filter @arcoralabs/dex-sdk typecheck 2>&1 | tail -3
```
Expected: clean (no errors from the new action files).

---

### Task 6: V2 write actions (`swapV2`, `depositV2`, `withdrawSingleV2`, `withdrawProportionalV2`)

**Files:** create the four write actions under `src/actions/v2/`. They reuse `ensureAllowance`, `minOut`, `deadline`, `assertReceiptOk`, and `parseContractErrorV2`. **The §9 "refresh quote immediately before submission" + "never submit an over-max tx" requirements are enforced here**: each oracle-priced write re-quotes right before the write (like V1 `swap`), and `withdrawSingleV2` additionally calls `maxWithdraw` and refuses an over-max `lpAmount` BEFORE writing.

- [ ] **Step 1: `swapV2` (re-quote → minOut → write → typed-revert recovery → decode)**

Create `packages/sdk/src/actions/v2/swapV2.ts` (mirror V1 `swap.ts`, swapping in `poolAbiV2`, `quoteSwapV2`, `parseContractErrorV2`, and the V2 `Swapped` event shape with `feeUsd1e18`):
```ts
import { decodeEventLog, type Log } from "viem";
import type { ArcoraDexClientV2 } from "../../clientV2";
import type { SwapResultV2, SwappedEventV2 } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { ensureAllowance } from "../../allowance";
import { minOut, deadline as defaultDeadline } from "../../slippage";
import { quoteSwapV2 } from "./quoteSwapV2";
import { MissingAccountError } from "../../errors";
import { parseContractErrorV2 } from "../../errors.v2";
import { assertReceiptOk } from "../../recoverRevert";

export interface SwapV2Args {
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  amountIn: bigint;
  slippageBps: number;
  deadline?: bigint;
  recipient?: `0x${string}`;
  exactApproval?: boolean;
}

export async function swapV2(client: ArcoraDexClientV2, args: SwapV2Args): Promise<SwapResultV2> {
  if (!client.walletClient || !client.account) throw new MissingAccountError();

  const { approveHash } = await ensureAllowance(
    client, args.tokenIn, client.addresses.pool, args.amountIn, args.exactApproval ?? false,
  );

  // §9: refresh the quote immediately before submission.
  const quote = await quoteSwapV2(client, {
    tokenIn: args.tokenIn, tokenOut: args.tokenOut, amountIn: args.amountIn,
  });
  const minAmountOut = minOut(quote.amountOut, args.slippageBps);
  const dl = args.deadline ?? defaultDeadline();
  const recipient = args.recipient ?? client.account.address;

  let hash: `0x${string}`;
  try {
    hash = await client.walletClient.writeContract({
      chain: client.chain, account: client.account,
      address: client.addresses.pool, abi: poolAbiV2, functionName: "swap",
      args: [args.tokenIn, args.tokenOut, args.amountIn, minAmountOut, dl, recipient],
    });
  } catch (e) {
    throw parseContractErrorV2(e);
  }

  const receipt = await client.publicClient.waitForTransactionReceipt({ hash });
  await assertReceiptOk(client.publicClient, receipt, {
    address: client.addresses.pool, abi: poolAbiV2, functionName: "swap",
    args: [args.tokenIn, args.tokenOut, args.amountIn, minAmountOut, dl, recipient],
    account: client.account.address,
  });
  const event = decodeSwappedV2(receipt.logs as Log[], client.addresses.pool);
  const result: SwapResultV2 = { hash, receipt, amountOut: event.amountOut, event };
  if (approveHash) result.approveHash = approveHash;
  return result;
}

function decodeSwappedV2(logs: Log[], pool: `0x${string}`): SwappedEventV2 {
  for (const log of logs) {
    if (log.address.toLowerCase() !== pool.toLowerCase()) continue;
    try {
      const d = decodeEventLog({ abi: poolAbiV2, data: log.data, topics: log.topics });
      if (d.eventName === "Swapped") {
        const a = d.args;
        return {
          user: a.user, tokenIn: a.tokenIn, tokenOut: a.tokenOut,
          amountIn: a.amountIn, amountOut: a.amountOut,
          feeUsd1e18: a.feeUsd1e18, protocolFeeAmtOut: a.protocolFeeAmtOut,
          recipient: a.recipient,
          blockNumber: log.blockNumber!, txHash: log.transactionHash!, logIndex: log.logIndex!,
        };
      }
    } catch { /* keep scanning */ }
  }
  throw new Error("V2 Swapped event not found in receipt logs.");
}
```

- [ ] **Step 2: `depositV2`** — mirror V1 `deposit.ts` (ensureAllowance → write `deposit` → decode `Deposited` → `lpMinted`), using `poolAbiV2` + `parseContractErrorV2`. No quote-vs-max guard needed for deposits beyond the contract's `DepositCapExceeded` (surfaced as a typed error).

- [ ] **Step 3: `withdrawSingleV2` (the over-max guard lives here)**

Create `packages/sdk/src/actions/v2/withdrawSingleV2.ts`. Before writing: re-quote with `quoteWithdrawV2` for `minTokenOut`, AND call `maxWithdraw(tokenOut, account)` and throw `ReserveFloorBreachedError` if `args.lpAmount > max.lpAmount` so the SDK never submits an over-max single-token withdrawal (§9), with the contract floor still the final backstop:
```ts
// … imports: poolAbiV2, quoteWithdrawV2, maxWithdraw, minOut, deadline,
//    assertReceiptOk, MissingAccountError, parseContractErrorV2,
//    ReserveFloorBreachedError, WithdrawSingleResult/WithdrewSingleEvent
export async function withdrawSingleV2(client: ArcoraDexClientV2, args: {
  tokenOut: `0x${string}`; lpAmount: bigint; slippageBps: number; deadline?: bigint;
}): Promise<WithdrawSingleResult> {
  if (!client.walletClient || !client.account) throw new MissingAccountError();

  // §9: never submit an over-max single-token withdrawal (contract floor is the
  // final enforcement; this is the client-side guard the app's Max relies on).
  const max = await maxWithdraw(client, args.tokenOut, client.account.address);
  if (args.lpAmount > max.lpAmount) throw new ReserveFloorBreachedError(args.tokenOut);

  // §9: refresh the quote immediately before submission.
  const quote = await quoteWithdrawV2(client, { tokenOut: args.tokenOut, lpAmount: args.lpAmount });
  const minTokenOut = minOut(quote.amountOut, args.slippageBps);
  const dl = args.deadline ?? defaultDeadline();

  let hash: `0x${string}`;
  try {
    hash = await client.walletClient.writeContract({
      chain: client.chain, account: client.account,
      address: client.addresses.pool, abi: poolAbiV2, functionName: "withdrawSingle",
      args: [args.tokenOut, args.lpAmount, minTokenOut, dl],
    });
  } catch (e) { throw parseContractErrorV2(e); }

  const receipt = await client.publicClient.waitForTransactionReceipt({ hash });
  await assertReceiptOk(client.publicClient, receipt, {
    address: client.addresses.pool, abi: poolAbiV2, functionName: "withdrawSingle",
    args: [args.tokenOut, args.lpAmount, minTokenOut, dl], account: client.account.address,
  });
  const event = decodeWithdrewSingle(receipt.logs as Log[], client.addresses.pool);
  return { hash, receipt, amountOut: event.amountOut, event };
}
```
(Implement `decodeWithdrewSingle` mirroring `decodeSwappedV2` for the `WithdrewSingle` event.)

- [ ] **Step 4: `withdrawProportionalV2` (the §11 fallback — no oracle, no quote, no floor)**

Create `packages/sdk/src/actions/v2/withdrawProportionalV2.ts`. It takes only `{ lpAmount, deadline? }`, writes `withdrawProportional`, and decodes `WithdrewProportional`. Per §8.3/§11 it requires NO USD valuation, NO token selection, NO `minOut`, and remains available when an oracle is unsafe or the pool is paused — so it does NOT call any quote/max/oracle path. Returns the `amounts[]` from the write return + the event:
```ts
export async function withdrawProportionalV2(client: ArcoraDexClientV2, args: {
  lpAmount: bigint; deadline?: bigint;
}): Promise<WithdrawProportionalResult> {
  if (!client.walletClient || !client.account) throw new MissingAccountError();
  const dl = args.deadline ?? defaultDeadline();
  let hash: `0x${string}`;
  try {
    hash = await client.walletClient.writeContract({
      chain: client.chain, account: client.account,
      address: client.addresses.pool, abi: poolAbiV2, functionName: "withdrawProportional",
      args: [args.lpAmount, dl],
    });
  } catch (e) { throw parseContractErrorV2(e); }
  const receipt = await client.publicClient.waitForTransactionReceipt({ hash });
  await assertReceiptOk(client.publicClient, receipt, {
    address: client.addresses.pool, abi: poolAbiV2, functionName: "withdrawProportional",
    args: [args.lpAmount, dl], account: client.account.address,
  });
  const event = decodeWithdrewProportional(receipt.logs as Log[], client.addresses.pool);
  // amounts[] are recovered from the event scan + a post-receipt static call is
  // unnecessary — withdrawProportional's return is decoded from the tx in the
  // anvil/integration test (Task 9). Surface the event; amounts default to [].
  return { hash, receipt, amounts: [], event };
}
```
(Note in the file: `amounts[]` is the function RETURN, not an event field; in the anvil integration test we read it via `simulateContract` before the write to assert the basket. Keep the result's `amounts` populated from that simulate in Task 9, or leave `[]` if not simulated — documented, not a stub.)

- [ ] **Step 5: Typecheck the write actions**
```bash
pnpm --filter @arcoralabs/dex-sdk typecheck 2>&1 | tail -3
```
Expected: clean once `clientV2.ts` (Task 8) exists; until then these reference `ArcoraDexClientV2` — implement Task 8 immediately after, or temporarily type against a local interface and tighten in Task 8. Record the order chosen.

---

### Task 7: Presentation helpers (the §9 display primitives Plan 4b consumes)

**Files:** create `packages/sdk/src/present/index.ts`; create `packages/sdk/test/unit/v2/present.test.ts`.

- [ ] **Step 1: Write the failing helper test (encodes the §7 initial fee schedule)**

Create `packages/sdk/test/unit/v2/present.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import {
  healthBand, healthLabel, estimatedFeePct, applyMaxGuard, INITIAL_FEE_SCHEDULE,
} from "../../../src/present";

describe("present helpers", () => {
  it("healthBand maps bps → the §7 band label", () => {
    expect(healthBand(10000)).toBe("75-100");
    expect(healthBand(8000)).toBe("75-100");
    expect(healthBand(6000)).toBe("50-75");
    expect(healthBand(3000)).toBe("25-50");
    expect(healthBand(1000)).toBe("0-25");
  });

  it("healthLabel is human and matches the band", () => {
    expect(healthLabel(9000)).toBe("Healthy");
    expect(healthLabel(1000)).toBe("Critical");
  });

  it("INITIAL_FEE_SCHEDULE is the §7 table (marginal fee per band)", () => {
    expect(INITIAL_FEE_SCHEDULE).toEqual([
      { fromBps: 7500, toBps: 10000, feeBps: 5 },
      { fromBps: 5000, toBps: 7500, feeBps: 20 },
      { fromBps: 2500, toBps: 5000, feeBps: 75 },
      { fromBps: 0,    toBps: 2500, feeBps: 300 },
    ]);
  });

  it("estimatedFeePct = feeUsd1e18 / grossUsd1e18 in bps", () => {
    // 0.05% of $100 = $0.05; 5e16 / 100e18 → 5 bps.
    expect(estimatedFeePct(50_000_000_000_000_000n, 100_000_000_000_000_000_000n)).toBeCloseTo(0.05, 4);
  });

  it("applyMaxGuard clamps and flags over-max", () => {
    expect(applyMaxGuard(120n, 100n)).toEqual({ amount: 100n, clamped: true,  overMax: true });
    expect(applyMaxGuard(80n,  100n)).toEqual({ amount: 80n,  clamped: false, overMax: false });
  });
});
```
Run — expected: FAIL.

- [ ] **Step 2: Implement the helpers (pure functions; no network)**

Create `packages/sdk/src/present/index.ts`:
```ts
import type { FeeBand } from "../types.v2";

/** The spec §7 initial fee schedule as marginal bands (health bps → fee bps). */
export const INITIAL_FEE_SCHEDULE = [
  { fromBps: 7500, toBps: 10000, feeBps: 5 },   // 75%-100%  → 0.05%
  { fromBps: 5000, toBps: 7500,  feeBps: 20 },  // 50%-75%   → 0.20%
  { fromBps: 2500, toBps: 5000,  feeBps: 75 },  // 25%-50%   → 0.75%
  { fromBps: 0,    toBps: 2500,  feeBps: 300 }, // 0%-25%    → 3.00%
] as const;

export type HealthBand = "75-100" | "50-75" | "25-50" | "0-25";

/** Map a reserve-health bps value to the §7 band it sits in. */
export function healthBand(healthBps: number): HealthBand {
  if (healthBps >= 7500) return "75-100";
  if (healthBps >= 5000) return "50-75";
  if (healthBps >= 2500) return "25-50";
  return "0-25";
}

export type HealthLabel = "Healthy" | "Caution" | "Low" | "Critical";

export function healthLabel(healthBps: number): HealthLabel {
  switch (healthBand(healthBps)) {
    case "75-100": return "Healthy";
    case "50-75":  return "Caution";
    case "25-50":  return "Low";
    default:       return "Critical";
  }
}

/**
 * Read a token's marginal fee bands FROM its on-chain TokenConfigV2 (preferred
 * over the static schedule — the registry is the source of truth). Returns the
 * bands sorted healthiest-first for display.
 */
export function feeBandsForToken(bands: FeeBand[]): FeeBand[] {
  return [...bands].sort((a, b) => b.upperHealthBps - a.upperHealthBps);
}

/** Estimated dynamic fee as a percentage: feeUsd1e18 / grossUsd1e18 * 100. */
export function estimatedFeePct(feeUsd1e18: bigint, grossUsd1e18: bigint): number {
  if (grossUsd1e18 === 0n) return 0;
  // bps with 1e4 precision, then → percent.
  const bps = Number((feeUsd1e18 * 1_000_000n) / grossUsd1e18) / 100;
  return bps / 100;
}

export interface MaxGuardResult { amount: bigint; clamped: boolean; overMax: boolean }

/** §9: clamp an entered amount to the floor-safe max; flag when it was over. */
export function applyMaxGuard(entered: bigint, max: bigint): MaxGuardResult {
  if (entered > max) return { amount: max, clamped: true, overMax: true };
  return { amount: entered, clamped: false, overMax: false };
}
```
Run `pnpm --filter @arcoralabs/dex-sdk test present` — expected: PASS.

> Note: `INITIAL_FEE_SCHEDULE` is the §7 DEFAULT for display before a token's config loads; live UI should prefer `feeBandsForToken(tokenConfig.bands)`. Both are exported so Plan 4b can show the schedule immediately and refine once the registry read resolves.

---

### Task 8: The `createArcoraDexV2` client factory + remaining read actions

**Files:** create `packages/sdk/src/clientV2.ts`, `packages/sdk/src/actions/v2/getTokensV2.ts`, `packages/sdk/src/actions/v2/getPoolStatsV2.ts`; create `packages/sdk/test/unit/v2/clientV2.test.ts`.

- [ ] **Step 1: `getTokensV2` (registry read → `TokenInfoV2[]` with bands)**

Create `packages/sdk/src/actions/v2/getTokensV2.ts` mirroring V1 `getTokens.ts` but reading `tokenConfig` (TokenConfigV2) and labelling from `KNOWN_TOKENS_V2` with an ERC20 fallback:
```ts
import type { ReadClientV2 } from "./_readClient";
import type { TokenInfoV2 } from "../../types.v2";
import { registryAbiV2 } from "../../abi/v2/registry";
import { erc20Abi } from "../../abi/erc20";
import { KNOWN_TOKENS_V2 } from "../../tokens/known.v2";
import { getAddress } from "viem";

export async function getTokensV2(
  client: ReadClientV2, args?: { activeOnly?: boolean },
): Promise<TokenInfoV2[]> {
  const registry = client.addresses.registry;
  const n = Number(await client.publicClient.readContract({
    address: registry, abi: registryAbiV2, functionName: "tokensLength",
  }));
  if (n === 0) return [];
  const addresses = await Promise.all(
    Array.from({ length: n }, (_, i) => client.publicClient.readContract({
      address: registry, abi: registryAbiV2, functionName: "tokens", args: [BigInt(i)],
    })),
  );
  const configs = await Promise.all(addresses.map((a) => client.publicClient.readContract({
    address: registry, abi: registryAbiV2, functionName: "tokenConfig", args: [a],
  })));
  const labels = await Promise.all(addresses.map(async (a) => {
    let key: `0x${string}`; try { key = getAddress(a); } catch { key = a; }
    const known = KNOWN_TOKENS_V2[key];
    if (known) return known;
    const [symbol, name] = await Promise.all([
      client.publicClient.readContract({ address: a, abi: erc20Abi, functionName: "symbol" }),
      client.publicClient.readContract({ address: a, abi: erc20Abi, functionName: "name" }),
    ]);
    return { symbol, name };
  }));
  const tokens: TokenInfoV2[] = addresses.map((address, i) => {
    const c = configs[i]!; const m = labels[i]!;
    return {
      address, symbol: m.symbol, name: m.name,
      decimals: Number(c.decimals), isActive: c.isActive, adapter: c.adapter,
      minimumReserveUsd: c.minimumReserveUsd, targetReserveUsd: c.targetReserveUsd,
      depositCapUsd: c.depositCapUsd,
      bands: c.bands.map((b) => ({ upperHealthBps: Number(b.upperHealthBps), rateBps: Number(b.rateBps) })),
    };
  });
  return args?.activeOnly ? tokens.filter((t) => t.isActive) : tokens;
}
```
(`Band` field names match the verified `FeeBandMathV2.Band` from Task 3 Step 3: `upperHealthBps` + `rateBps`.)

- [ ] **Step 2: `getPoolStatsV2`**

Create `packages/sdk/src/actions/v2/getPoolStatsV2.ts`: read `totalReservesUSD`, the LP `totalSupply` (via `lpAbi`), `protocolFeeShareBps`, `paused`; derive `lpPriceUsd1e18 = lpSupply === 0n ? 0n : navUsd1e18 * 10n**18n / lpSupply`.

- [ ] **Step 3: Write the factory test (resolution + coexistence with V1)**

Create `packages/sdk/test/unit/v2/clientV2.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { http } from "viem";
import { createArcoraDexV2 } from "../../../src/clientV2";
import { baseSepolia } from "../../../src/chains/baseSepolia";
import { DEFAULT_ADDRESSES_V2 } from "../../../src/addresses.v2";

describe("createArcoraDexV2", () => {
  it("resolves DEFAULT_ADDRESSES_V2 for baseSepolia and exposes the V2 surface", () => {
    const sdk = createArcoraDexV2({ chain: baseSepolia, transport: http() });
    expect(sdk.addresses).toEqual(DEFAULT_ADDRESSES_V2[baseSepolia.id]);
    for (const fn of [
      "reserveHealth", "maxSwapOut", "maxWithdraw", "quoteSwapV2", "quoteWithdrawV2",
      "swap", "deposit", "withdrawSingle", "withdrawProportional",
      "getTokens", "getPoolStats",
    ] as const) {
      expect(typeof sdk[fn]).toBe("function");
    }
  });

  it("throws for an unmapped chain unless addresses are passed", () => {
    // Arc 5042002 is intentionally absent from the V2 map.
    expect(() => createArcoraDexV2({ chain: { ...baseSepolia, id: 5042002 }, transport: http() }))
      .toThrow(/No default ArcoraDexAddresses/);
  });
});
```
Run — expected: FAIL.

- [ ] **Step 4: Implement `clientV2.ts` (mirror `client.ts`, V2 wiring, resolve `DEFAULT_ADDRESSES_V2`)**

Create `packages/sdk/src/clientV2.ts`:
```ts
import type { Account, Chain, PublicClient, Transport, WalletClient } from "viem";
import { createPublicClient, createWalletClient } from "viem";
import { DEFAULT_ADDRESSES_V2 } from "./addresses.v2";
import type { ArcoraDexAddresses } from "./addresses";
import { reserveHealth } from "./actions/v2/reserveHealth";
import { maxSwapOut } from "./actions/v2/maxSwapOut";
import { maxWithdraw } from "./actions/v2/maxWithdraw";
import { quoteSwapV2 } from "./actions/v2/quoteSwapV2";
import { quoteWithdrawV2 } from "./actions/v2/quoteWithdrawV2";
import { getTokensV2 } from "./actions/v2/getTokensV2";
import { getPoolStatsV2 } from "./actions/v2/getPoolStatsV2";
import { swapV2, type SwapV2Args } from "./actions/v2/swapV2";
import { depositV2, type DepositV2Args } from "./actions/v2/depositV2";
import { withdrawSingleV2 } from "./actions/v2/withdrawSingleV2";
import { withdrawProportionalV2 } from "./actions/v2/withdrawProportionalV2";
import * as fmt from "./format";
import * as slip from "./slippage";
import * as present from "./present";

export interface CreateArcoraDexV2Params {
  chain: Chain;
  transport: Transport;
  walletClient?: WalletClient;
  account?: Account;
  addresses?: ArcoraDexAddresses;
}

export interface ArcoraDexClientV2 {
  chain: Chain;
  publicClient: PublicClient;
  walletClient?: WalletClient;
  account?: Account;
  addresses: ArcoraDexAddresses;

  reserveHealth: (tokenOut: `0x${string}`) => ReturnType<typeof reserveHealth>;
  maxSwapOut: (tokenOut: `0x${string}`) => ReturnType<typeof maxSwapOut>;
  maxWithdraw: (tokenOut: `0x${string}`, account: `0x${string}`) => ReturnType<typeof maxWithdraw>;
  quoteSwapV2: (a: Parameters<typeof quoteSwapV2>[1]) => ReturnType<typeof quoteSwapV2>;
  quoteWithdrawV2: (a: Parameters<typeof quoteWithdrawV2>[1]) => ReturnType<typeof quoteWithdrawV2>;
  getTokens: (a?: Parameters<typeof getTokensV2>[1]) => ReturnType<typeof getTokensV2>;
  getPoolStats: () => ReturnType<typeof getPoolStatsV2>;

  swap: (a: SwapV2Args) => ReturnType<typeof swapV2>;
  deposit: (a: DepositV2Args) => ReturnType<typeof depositV2>;
  withdrawSingle: (a: Parameters<typeof withdrawSingleV2>[1]) => ReturnType<typeof withdrawSingleV2>;
  withdrawProportional: (a: Parameters<typeof withdrawProportionalV2>[1]) => ReturnType<typeof withdrawProportionalV2>;

  format: typeof fmt;
  slippage: typeof slip;
  present: typeof present;
}

export function createArcoraDexV2(params: CreateArcoraDexV2Params): ArcoraDexClientV2 {
  const addresses =
    params.addresses ??
    DEFAULT_ADDRESSES_V2[params.chain.id] ??
    (() => { throw new Error(
      `No default ArcoraDexAddresses for chainId ${params.chain.id}; pass { addresses } explicitly.`,
    ); })();

  const publicClient = createPublicClient({ chain: params.chain, transport: params.transport });
  const walletClient = params.walletClient
    ? params.walletClient
    : params.account
      ? createWalletClient({ chain: params.chain, transport: params.transport, account: params.account })
      : undefined;
  const account = (walletClient?.account ?? params.account) as Account | undefined;

  const client: ArcoraDexClientV2 = {
    chain: params.chain, publicClient, walletClient, account, addresses,
    reserveHealth: (t) => reserveHealth(client, t),
    maxSwapOut: (t) => maxSwapOut(client, t),
    maxWithdraw: (t, acc) => maxWithdraw(client, t, acc),
    quoteSwapV2: (a) => quoteSwapV2(client, a),
    quoteWithdrawV2: (a) => quoteWithdrawV2(client, a),
    getTokens: (a) => getTokensV2(client, a),
    getPoolStats: () => getPoolStatsV2(client),
    swap: (a) => swapV2(client, a),
    deposit: (a) => depositV2(client, a),
    withdrawSingle: (a) => withdrawSingleV2(client, a),
    withdrawProportional: (a) => withdrawProportionalV2(client, a),
    format: fmt, slippage: slip, present,
  };
  return client;
}
```
Run `pnpm --filter @arcoralabs/dex-sdk test clientV2` — expected: PASS. Then `typecheck` clean (resolves the Task 6 forward refs to `ArcoraDexClientV2`).

---

### Task 9: Integration tests — anvil V2 fixture + LIVE Base Sepolia (env-gated skip)

**Files:** create `packages/sdk/test/integration/v2/read.v2.test.ts` (anvil), `packages/sdk/test/integration/v2/addresses-live-v2.test.ts` (live, env-gated). Inspect `test/deploy.ts` first to decide whether the existing anvil fixture deploys V2 or only V1.

- [ ] **Step 1: Check whether the anvil fixture can deploy V2**

Run:
```bash
sed -n '1,60p' packages/sdk/test/deploy.ts
```
If `deploy.ts` deploys only V1 contracts, the anvil V2 read test is **deferred to a fixture-extension follow-up** (note it explicitly; do NOT stub a fake fixture). The live test below is the primary §14 "SDK reads against the real deploy" gate and does not need anvil. If the fixture already deploys V2 (or is trivially extended), add `read.v2.test.ts` exercising `reserveHealth`/`quoteSwapV2`/`getTokensV2` against it.

- [ ] **Step 2: Write the LIVE Base Sepolia test (mirror `addresses-live.test.ts`, env-gated skip)**

Create `packages/sdk/test/integration/v2/addresses-live-v2.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { createPublicClient, http } from "viem";
import { createArcoraDexV2 } from "../../../src/clientV2";
import { baseSepolia } from "../../../src/chains/baseSepolia";
import { DEFAULT_ADDRESSES_V2 } from "../../../src/addresses.v2";
import { poolAbiV2 } from "../../../src/abi/v2/pool";

const RPC = process.env.BASE_SEPOLIA_RPC;

// Skips cleanly when no RPC is provided (default CI), mirroring the V1
// addresses-live test's SKIP_LIVE_TESTS gate. Run with:
//   BASE_SEPOLIA_RPC=https://base-sepolia-rpc.publicnode.com pnpm --filter @arcoralabs/dex-sdk test addresses-live-v2
describe.skipIf(!RPC)("V2 Base Sepolia defaults are live (84532)", () => {
  it("pool is unpaused and registry lists 3 tokens", async () => {
    const pub = createPublicClient({ chain: baseSepolia, transport: http(RPC) });
    const { pool } = DEFAULT_ADDRESSES_V2[baseSepolia.id]!;
    const paused = await pub.readContract({ address: pool, abi: poolAbiV2, functionName: "paused" });
    expect(paused).toBe(false);

    const sdk = createArcoraDexV2({ chain: baseSepolia, transport: http(RPC) });
    const tokens = await sdk.getTokens();
    expect(tokens.length).toBe(3);
    expect(tokens.map((t) => t.symbol).sort()).toEqual(["EURC", "USDC", "USDT"]);
  }, 30_000);

  it("quoteSwapV2 USDC→EURC returns a 4-field quote with sane health", async () => {
    const sdk = createArcoraDexV2({ chain: baseSepolia, transport: http(RPC) });
    const { USDC, EURC } = {
      USDC: "0x3a98d8adC295d90171e9DA93D411dEa95674c867" as const,
      EURC: "0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7" as const,
    };
    // NOTE: a live quote requires a fresh Pyth pull (keeper) — if the adapter is
    // stale this throws OracleUnsafeError, which is itself a valid §11 assertion.
    // Keep amountIn small relative to reserves so it stays in the healthiest band.
    const q = await sdk.quoteSwapV2({ tokenIn: USDC, tokenOut: EURC, amountIn: 1_000_000n }); // 1 USDC (6dp)
    expect(q.amountOut).toBeGreaterThan(0n);
    expect(q.postHealthBps).toBeGreaterThanOrEqual(0);
    expect(q.postHealthBps).toBeLessThanOrEqual(10000);
  }, 30_000);

  it("reserveHealth(EURC) is within 0..10000 bps", async () => {
    const sdk = createArcoraDexV2({ chain: baseSepolia, transport: http(RPC) });
    const { healthBps } = await sdk.reserveHealth("0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7");
    expect(healthBps).toBeGreaterThanOrEqual(0);
    expect(healthBps).toBeLessThanOrEqual(10000);
  }, 30_000);
});
```

- [ ] **Step 3: Confirm default CI skips cleanly (no RPC) AND the live test passes WITH an RPC**

Default (no env) — must NOT hit the network:
```bash
pnpm --filter @arcoralabs/dex-sdk test addresses-live-v2 2>&1 | tail -6
```
Expected: the `describe.skipIf` block reports skipped (0 failed). Then, opt-in:
```bash
BASE_SEPOLIA_RPC=https://base-sepolia-rpc.publicnode.com pnpm --filter @arcoralabs/dex-sdk test addresses-live-v2 2>&1 | tail -10
```
Expected: 3 tests pass (pool unpaused, 3 tokens, quote/health sane). If the quote test throws `OracleUnsafeError`, run the Base keeper first (`ops/basekeeper/update-pyth-base-sepolia.mjs` per the deploy note) to refresh Pyth, then re-run — a stale-oracle revert is a correct fail-closed outcome, not an SDK bug.

---

### Task 10: V2 React hooks (`./react/v2`)

**Files:** create the V2 hooks + provider under `src/react/v2/`; create representative hook tests under `test/react/v2/`. Mirror the V1 hook patterns (`useArcoraDex`, `useQuoteSwap`, `useDebouncedValue`, react-query keys namespaced by `chain.id`).

- [ ] **Step 1: `ArcoraDexV2Provider` + `useArcoraDexV2`**

Create `packages/sdk/src/react/v2/ArcoraDexV2Provider.tsx` and `useArcoraDexV2.ts` mirroring the V1 provider/context, but building an `ArcoraDexClientV2` via `createArcoraDexV2` from the wagmi `usePublicClient`/`useWalletClient` + connected chain. The provider resolves V2 addresses from `DEFAULT_ADDRESSES_V2` (override prop allowed). Reuse the V1 `useDebouncedValue` (import from `../useDebouncedValue` — no duplicate).

- [ ] **Step 2: Read/quote hooks**

Create `useReserveHealth.ts`, `useQuoteSwapV2.ts`, `useQuoteWithdrawV2.ts`, `useMaxSwapOut.ts`, `useMaxWithdraw.ts` mirroring `useQuoteSwap.ts` (debounce the amount, react-query `enabled` guards, query keys namespaced `["arcora", "v2", <name>, sdk.chain.id, …]`). Example `useQuoteSwapV2.ts`:
```ts
"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "./useArcoraDexV2";
import { useDebouncedValue } from "../useDebouncedValue";
import type { QuoteV2 } from "../../types.v2";

export function useQuoteSwapV2(
  args: { tokenIn?: `0x${string}`; tokenOut?: `0x${string}`; amountIn?: bigint },
  options?: { debounceMs?: number; enabled?: boolean },
) {
  const sdk = useArcoraDexV2();
  const amount = useDebouncedValue(args.amountIn, options?.debounceMs ?? 400);
  const enabled =
    (options?.enabled ?? true) && !!args.tokenIn && !!args.tokenOut &&
    args.tokenIn !== args.tokenOut && !!amount && amount > 0n;
  const { data, isFetching, error } = useQuery({
    queryKey: ["arcora", "v2", "quoteSwap", sdk.chain.id, args.tokenIn, args.tokenOut, amount?.toString()],
    queryFn: () => sdk.quoteSwapV2({ tokenIn: args.tokenIn!, tokenOut: args.tokenOut!, amountIn: amount! }),
    enabled,
  });
  return { data: (data ?? null) as QuoteV2 | null, isFetching, error: error as Error | null };
}
```

- [ ] **Step 3: Write hooks**

Create `useSwapV2.ts`, `useDepositV2.ts`, `useWithdrawSingleV2.ts`, `useWithdrawProportionalV2.ts` mirroring V1 `useSwap.ts` (mutation wrappers around the SDK write actions, surfacing typed errors). Barrel them in `src/react/v2/index.ts`.

- [ ] **Step 4: Hook tests (mirror the V1 react test style + `TestWrapper`)**

Add at least `test/react/v2/useQuoteSwapV2.test.tsx` and `test/react/v2/ArcoraDexV2Provider.test.tsx` mirroring the existing `test/react/useQuoteSwap.test.tsx` + `TestWrapper.tsx` (happy-dom env via `environmentMatchGlobs` — the `test/react/**` glob already covers `test/react/v2/**`; confirm, and widen the glob if it doesn't). Run:
```bash
pnpm --filter @arcoralabs/dex-sdk test react/v2 2>&1 | tail -6
```
Expected: V2 hook tests pass.

---

### Task 11: Barrels + package exports (`./v2`, `./react/v2`)

**Files:** create `packages/sdk/src/v2.ts`, `packages/sdk/src/react/v2/index.ts`; edit `packages/sdk/package.json` (export keys only).

- [ ] **Step 1: `src/v2.ts` barrel (V2 surface; NO V1 collision)**

Create `packages/sdk/src/v2.ts`:
```ts
export { createArcoraDexV2 } from "./clientV2";
export type { ArcoraDexClientV2, CreateArcoraDexV2Params } from "./clientV2";
export { baseSepolia } from "./chains/baseSepolia";
export { DEFAULT_ADDRESSES_V2 } from "./addresses.v2";
export { KNOWN_TOKENS_V2 } from "./tokens/known.v2";
export { poolAbiV2 } from "./abi/v2/pool";
export { registryAbiV2 } from "./abi/v2/registry";
export * from "./types.v2";
export {
  OracleUnsafeError, ReserveFloorBreachedError, DepositCapExceededError, parseContractErrorV2,
} from "./errors.v2";
export { reserveHealth } from "./actions/v2/reserveHealth";
export { maxSwapOut } from "./actions/v2/maxSwapOut";
export { maxWithdraw } from "./actions/v2/maxWithdraw";
export { quoteSwapV2 } from "./actions/v2/quoteSwapV2";
export { quoteWithdrawV2 } from "./actions/v2/quoteWithdrawV2";
export { getTokensV2 } from "./actions/v2/getTokensV2";
export { getPoolStatsV2 } from "./actions/v2/getPoolStatsV2";
export { swapV2, type SwapV2Args } from "./actions/v2/swapV2";
export { depositV2, type DepositV2Args } from "./actions/v2/depositV2";
export { withdrawSingleV2 } from "./actions/v2/withdrawSingleV2";
export { withdrawProportionalV2 } from "./actions/v2/withdrawProportionalV2";
export {
  feeBandsForToken, estimatedFeePct, healthBand, healthLabel, applyMaxGuard, INITIAL_FEE_SCHEDULE,
} from "./present";
export type { HealthBand, HealthLabel, MaxGuardResult } from "./present";
```
(The `ArcoraDexAddresses` type is shared — re-export it from the V1 index, not here, to avoid a duplicate-export collision. Confirm `tsc` is clean.)

- [ ] **Step 2: Add the export conditions (additive; `.` and `./react` untouched)**

Edit `packages/sdk/package.json` `exports`:
```json
"exports": {
  ".":         { "types": "./src/index.ts",          "default": "./src/index.ts" },
  "./v2":      { "types": "./src/v2.ts",              "default": "./src/v2.ts" },
  "./react":   { "types": "./src/react/index.ts",     "default": "./src/react/index.ts" },
  "./react/v2":{ "types": "./src/react/v2/index.ts",  "default": "./src/react/v2/index.ts" }
},
```
Then verify the build emits the new entrypoints (tsup multi-entry — confirm `tsup.config.ts` globs `src/v2.ts` + `src/react/v2/index.ts`; add them to the entry list if it enumerates entries explicitly):
```bash
pnpm --filter @arcoralabs/dex-sdk build 2>&1 | tail -6
```
Expected: build succeeds and emits `dist/v2.*` + `dist/react/v2/*` (or whatever the tsup config names them).

---

### Task 12: Full-suite green + lint + typecheck + V1-untouched proof

**Files:** none new; verification.

- [ ] **Step 1: Full SDK suite (V1 + V2, default — live tests skip)**
```bash
pnpm --filter @arcoralabs/dex-sdk test 2>&1 | tail -8
```
Expected: V1 baseline `<N>` (Task 0) still passing + the new V2 unit/integration/react tests passing; live V2 test SKIPPED (no `BASE_SEPOLIA_RPC`). 0 failed.

- [ ] **Step 2: typecheck + lint**
```bash
pnpm --filter @arcoralabs/dex-sdk typecheck && pnpm --filter @arcoralabs/dex-sdk lint
```
Expected: both clean.

- [ ] **Step 3: Prove the V1/Arc surface is byte-for-byte untouched**
```bash
git diff --stat -- packages/sdk/src/index.ts packages/sdk/src/addresses.ts packages/sdk/src/client.ts \
  packages/sdk/src/actions packages/sdk/src/react/useSwap.ts packages/sdk/src/abi/pool.ts
```
Expected: EMPTY (the only V1-area edit allowed in this plan is `package.json`'s new export keys). If anything else shows, revert it — V2 is additive.

- [ ] **Step 4: Opt-in live gate (manual, documented; not in default CI)**
```bash
BASE_SEPOLIA_RPC=https://base-sepolia-rpc.publicnode.com pnpm --filter @arcoralabs/dex-sdk test addresses-live-v2 2>&1 | tail -8
```
Expected: 3 live tests pass (run the Base keeper first if the quote test reports a stale-oracle `OracleUnsafeError`).

---

### Task 13: Commit

- [ ] **Step 1: Stage + commit the V2 SDK module**
```bash
git add packages/sdk/src packages/sdk/test packages/sdk/package.json docs/superpowers/plans/2026-06-10-base-v2-sdk-integration.md
git commit -m "$(cat <<'EOF'
feat(sdk): add Base Sepolia V2 module to @arcoralabs/dex-sdk

Additive V2 namespace binding the live Base Sepolia (84532) V2 ledger:
baseSepolia chain + DEFAULT_ADDRESSES_V2, poolAbiV2/registryAbiV2, the §9
read/quote/write actions (reserveHealth, maxSwapOut, maxWithdraw,
quoteSwapV2/quoteWithdrawV2, swap/deposit/withdrawSingle/withdrawProportional),
reserve-health + marginal-fee presentation helpers, createArcoraDexV2 +
./react/v2 hooks, V2 typed errors, and an env-gated live Base Sepolia
integration test. The V1/Arc surface (5042002) is unchanged and stays green;
the two chains coexist via separate address maps and client factories.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```
Expected: one commit on `feat/base-v2-sdk-integration`. Do NOT push or open a PR — the controller reviews and integrates.

---

## Self-Review

### Spec §9 coverage map

| §9 requirement | Where satisfied in this plan |
|---|---|
| `reserveHealth(token)` | `actions/v2/reserveHealth.ts` (Task 5); `poolAbiV2` (Task 3); `useReserveHealth` (Task 10). |
| `maxSwapOut(tokenOut)` → max NET out + gross entitlement | `actions/v2/maxSwapOut.ts` → `{ netOut, grossUsd1e18 }` (Task 5). |
| `maxWithdraw(tokenOut, account)` → max LP + resulting net out | `actions/v2/maxWithdraw.ts` → `{ lpAmount, netOut }` (Task 5). |
| `quoteSwapV2` / `quoteWithdrawV2` (4-tuple) | `actions/v2/quoteSwapV2.ts`, `quoteWithdrawV2.ts` → `QuoteV2` (Task 5); ABI 4-return asserted (Task 3). |
| marginal fee breakdown + post-tx reserve health | `QuoteV2.feeUsd1e18` + `postHealthBps`; `present.feeBandsForToken` / `estimatedFeePct` / `healthBand` (Task 7). |
| App: show reserve health + estimated dynamic fee | SDK primitives shipped (`reserveHealth`, `estimatedFeePct`, `feeBandsForToken`); the DISPLAY is Plan 4b (consumes them). |
| App: `Max` action = only floor-safe amount | `maxSwapOut`/`maxWithdraw` + `applyMaxGuard` (Task 7); UI wiring → Plan 4b. |
| App: warn when entered > safe max | `applyMaxGuard().overMax` (Task 7); banner → Plan 4b. |
| App: never submit an over-max tx | Enforced in `withdrawSingleV2` (throws `ReserveFloorBreachedError` when `lpAmount > maxWithdraw`) — Task 6 Step 3; contract floor remains final. |
| App: refresh the quote immediately before submission | `swapV2`/`withdrawSingleV2`/`depositV2` re-quote right before `writeContract` (Task 6). |
| App: still rely on the contract as final enforcement | All writes go through `assertReceiptOk` typed-revert recovery; SDK guards are advisory, the on-chain floor/`OracleUnsafe`/`ReserveFloorBreached` reverts are authoritative (`parseContractErrorV2`, Task 4). |
| App: proportional withdrawal when oracle paths unavailable | `withdrawProportionalV2` (Task 6 Step 4) — no oracle/quote/max/floor path, always available; `OracleUnsafeError` (Task 4) is the signal the app switches to it (§11). |

### Placeholder scan
- No "TBD"/"implement later"/undefined-symbol in shown code. Two intentional, FLAGGED deferrals (not stubs): (a) the anvil V2 read test is conditional on `test/deploy.ts` already deploying V2 — Task 9 Step 1 checks and otherwise defers it to a fixture-extension follow-up rather than faking a fixture; (b) `withdrawProportionalV2`'s `amounts[]` is the function RETURN (not an event field) and is populated via `simulateContract` only in the anvil test path — documented in Task 6 Step 4, defaults to `[]` otherwise. Neither blocks compilation.
- The `registryAbiV2` `Band` struct is transcribed VERBATIM from the verified `contracts/src/v2/lib/FeeBandMathV2.sol` (`{ uint16 upperHealthBps; uint16 rateBps }`) — confirmed during plan-writing, not a guess. The `FeeBand` TS type and the `getTokensV2` `.map` accessor use the same `upperHealthBps`/`rateBps` names; a future contract rename is caught by the live `getTokensV2` decode in Task 9.

### Type/name consistency across tasks
- `quoteSwapV2`/`quoteWithdrawV2` return `(amountOut, protocolFee, feeUsd1e18, postHealthBps)` — identical in `IArcoraDexPoolV2.sol`, `poolAbiV2`, the `QuoteV2` type, the actions, and the hooks. `postHealthBps` is `number` at the TS boundary (cast via `Number()`), `bigint` only across the wire.
- `maxSwapOut → (netOut, grossUsd1e18)` and `maxWithdraw → (lpAmount, netOut)` — interface order preserved in ABI, types (`MaxSwapOut`/`MaxWithdraw`), and action destructuring.
- `swap(tokenIn, tokenOut, amountIn, minOut, deadline, recipient)` — the V2 `swap` recipient arg (present in `IArcoraDexPoolV2`) is carried through `SwapV2Args.recipient` and the write call, matching V1's signature exactly.
- Events: V2 `Swapped` carries `feeUsd1e18` (not V1's `lpFeeUsd1e18`) + `protocolFeeAmtOut`; `WithdrewSingle`/`WithdrewProportional` are distinct (vs V1's single `Withdrew`). The ABI, `SwappedEventV2`/`WithdrewSingleEvent`/`WithdrewProportionalEvent` types, and the decoders agree.
- `ArcoraDexAddresses {pool, registry, lp}` is REUSED (not re-defined) by `addresses.v2.ts` and `clientV2.ts` — one shape, two maps.
- Errors: `OracleUnsafe`/`ReserveFloorBreached`/`DepositCapExceeded` selectors (from `IArcoraDexPoolV2`) map to the three new classes; all shared selectors delegate to the audited V1 `parseContractError`.

### Multi-chain coexistence proof (the §15 "no Arc hardcoding in the Base flow" gate)
- Arc 5042002 lives only in `DEFAULT_ADDRESSES`/`KNOWN_TOKENS` (untouched); Base 84532 lives only in `DEFAULT_ADDRESSES_V2`/`KNOWN_TOKENS_V2` (new). `clientV2` resolves exclusively from the V2 map; `client` (V1) from the V1 map. Task 2 Step 1 asserts neither map contains the other's chain id. Task 12 Step 3 proves the V1 source files are byte-for-byte unchanged.

---

## Appendix — Plan 4b (App V2 UX) outline, for a LATER plan

Plan 4b imports `@arcoralabs/dex-sdk/v2` + `@arcoralabs/dex-sdk/react/v2` and is its own plan. High-level tasks:

1. **Wagmi multi-chain config** — add `baseSepolia` to `app/lib/wagmi.ts` alongside `arcTestnet` (both chains + per-chain transports; env-overridable Base RPC defaulting to the publicnode endpoint). Keep Arc working; add a chain selector in `NetworkButton`/`Header`.
2. **V2 env + provider wiring** — add `NEXT_PUBLIC_BASE_*` envs to `app/.env.example`; mount `ArcoraDexV2Provider` for the Base chain (V1 provider stays for Arc); a `useActiveDexVersion()` that picks V1-vs-V2 by connected chain.
3. **Reserve-health + dynamic-fee display** — a reserve-health badge (`healthLabel`/`healthBand`) + estimated-fee line (`estimatedFeePct`) in `SwapCard` and `WithdrawTab`; a fee-band table (`feeBandsForToken`) in the pool view.
4. **Max button + over-max guard** — wire `maxSwapOut`/`maxWithdraw` + `applyMaxGuard` into the amount inputs; a `Max` button that fills the floor-safe amount; an inline warning when entered > max; disable submit while `overMax` (never submit an over-max tx — backstopped by the SDK guard + the contract).
5. **Quote-refresh-before-submit** — the confirm modal re-reads `quoteSwapV2`/`quoteWithdrawV2` immediately before signing (the SDK action already re-quotes; the UI shows the refreshed numbers).
6. **Proportional-exit fallback** — when `getTokens`/quotes surface `OracleUnsafeError` (or the pool is paused), the Withdraw screen hides the single-token path and offers `withdrawProportional` (the §11 always-available exit) with a clear explanation.
7. **Faucet/token map for Base Sepolia** — extend `app/lib/faucet-tokens.ts` (or gate the faucet to Arc) so the Base USDC/USDT/EURC are selectable; the faucet API stays Arc-only unless a Base faucet exists.
8. **App tests** — component tests for the Max guard, over-max disabled-submit, dynamic-fee presentation, network selection, and the proportional emergency exit (spec §14 "SDK and application tests cover safe maximums, … network selection, and proportional emergency exit").
