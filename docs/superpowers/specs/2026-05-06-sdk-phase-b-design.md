# ArcoraDEX SDK (Phase B v0.1) — Design Spec

**Date:** 2026-05-06
**Status:** Approved (brainstorming complete) — pending implementation plan
**Authors:** Hüseyin Arslan + Claude
**Builds on:** v1.0-testnet (`docs/rollouts/2026-05-06-arcoradex-deploy.md`); spec §10 of `2026-05-06-arcoradex-spinoff-design.md`

---

## 1. Context & Motivation

ArcoraDEX v1.0-testnet ships with contracts (`Pool`, `Registry`, `LP`), a Next.js frontend (`app/`), and a 7-stable smoke trail. The frontend duplicates concerns that any SDK would also expose: ABI definitions, address constants, token metadata, decimal-aware formatting, slippage math, allowance + approve dances. Phase B extracts these into a reusable, framework-agnostic TypeScript SDK and refactors the frontend to consume it — eliminating duplication and creating a single source of truth that future integrations (third-party DEX aggregators, agentic workflows, CLIs, indexers) can adopt.

Spec §10 estimated Phase B at 1–2 weeks. This spec scopes the **v0.1 work** — building the SDK in a monorepo workspace and migrating the frontend onto it. **NPM publish is explicitly out of scope**; that is gated by spec §10's "30 days stable on testnet" trigger and will get its own short release-procedure spec.

## 2. Locked decisions

| Decision | Choice |
|---|---|
| Repo strategy | Monorepo workspace inside `Kubudak90/arcoradex` (`packages/sdk/` + `app/`) |
| Package name | `@arcoralabs/dex-sdk` |
| API shape | Unified client factory (`createArcoraDex({chain, transport, account?})`) |
| Approval handling | Auto-approve `MAX_UINT256` inside `swap`/`deposit`; opt-out via `{ exactApproval: true }` |
| React integration | Same package, `/react` subpath export |
| Frontend migration | Full migration — `app/lib/{abi,contracts,format,slippage,hooks/useTokens}` deleted |
| NPM publish | Workspace-only for v0.1; publish at v1.0 trigger |
| Build tooling | tsup + ESM-only + source-direct dev |
| Live data | Pull (snapshot reads) + opt-in event subscriptions via viem `watchContractEvent` |
| Testing | Vitest unit + Anvil-backed integration + Anvil-backed React tests |
| Versioning | v0.1.0 → 0.x freely; semver discipline starts at v1.0 publish |

## 3. Repo Structure

### 3.1 New top-level layout

```
arcoradex/
├── pnpm-workspace.yaml         # NEW
├── package.json                # NEW (root, devDeps + scripts)
├── contracts/                  # unchanged
├── app/                        # unchanged structure; package.json + lib/* refactored
├── packages/
│   └── sdk/                    # NEW
│       ├── package.json
│       ├── tsup.config.ts
│       ├── tsconfig.json
│       ├── tsconfig.build.json
│       ├── vitest.config.ts
│       ├── eslint.config.mjs
│       ├── README.md
│       ├── src/
│       │   ├── index.ts                # core public barrel
│       │   ├── client.ts               # createArcoraDex factory
│       │   ├── addresses.ts            # v1.0-testnet defaults
│       │   ├── chains/
│       │   │   └── arcTestnet.ts
│       │   ├── tokens/
│       │   │   ├── known.ts            # KNOWN_TOKENS map
│       │   │   └── label.ts            # tokenLabel + getAddress normalization
│       │   ├── abi/
│       │   │   ├── pool.ts             # parseAbi
│       │   │   ├── registry.ts
│       │   │   ├── lp.ts
│       │   │   └── erc20.ts
│       │   ├── actions/
│       │   │   ├── quoteSwap.ts
│       │   │   ├── quoteDeposit.ts
│       │   │   ├── quoteWithdraw.ts
│       │   │   ├── getPoolStats.ts
│       │   │   ├── getTokens.ts
│       │   │   ├── getReserves.ts
│       │   │   ├── getPosition.ts
│       │   │   ├── getProtocolFees.ts
│       │   │   ├── swap.ts             # auto-approve + write
│       │   │   ├── deposit.ts          # auto-approve + write
│       │   │   └── withdraw.ts
│       │   ├── subscriptions/
│       │   │   ├── subscribeSwaps.ts
│       │   │   ├── subscribeDeposited.ts
│       │   │   ├── subscribeWithdrew.ts
│       │   │   └── subscribePoolStats.ts
│       │   ├── format/
│       │   │   └── index.ts            # units, usd, tryParseUnits
│       │   ├── slippage/
│       │   │   └── index.ts            # minOut, deadline
│       │   ├── errors.ts               # ArcoraDexError + parseContractError
│       │   ├── allowance.ts            # ensureAllowance helper (used by swap/deposit)
│       │   ├── types.ts                # SwapResult, DepositResult, WithdrawResult, etc.
│       │   └── react/
│       │       ├── index.ts            # react public barrel
│       │       ├── ArcoraDexProvider.tsx
│       │       ├── useArcoraDex.ts
│       │       ├── useTokens.ts
│       │       ├── useQuoteSwap.ts
│       │       ├── useQuoteDeposit.ts
│       │       ├── useQuoteWithdraw.ts
│       │       ├── usePoolStats.ts
│       │       ├── usePosition.ts
│       │       ├── useSwap.ts
│       │       ├── useDeposit.ts
│       │       ├── useWithdraw.ts
│       │       ├── useAllowance.ts
│       │       └── useSwapHistory.ts
│       └── test/
│           ├── setup.ts                # Anvil bootstrap helper
│           ├── deploy.ts               # invokes contracts/script/DeployArcoraDex.s.sol
│           ├── unit/
│           │   ├── format.test.ts
│           │   ├── slippage.test.ts
│           │   ├── errors.test.ts
│           │   └── tokens.test.ts
│           ├── integration/
│           │   ├── client.test.ts
│           │   ├── read.test.ts
│           │   ├── swap.test.ts
│           │   ├── deposit.test.ts
│           │   ├── withdraw.test.ts
│           │   ├── errors.test.ts
│           │   └── subscriptions.test.ts
│           └── react/
│               ├── TestWrapper.tsx
│               ├── useTokens.test.tsx
│               ├── useQuoteSwap.test.tsx
│               ├── useSwap.test.tsx
│               ├── usePoolStats.test.tsx
│               └── useSwapHistory.test.tsx
└── docs/superpowers/
    ├── specs/2026-05-06-sdk-phase-b-design.md   # this file
    └── plans/2026-05-06-sdk-phase-b.md          # implementation plan
```

### 3.2 Files removed

```
app/lib/abi/pool.ts
app/lib/abi/registry.ts
app/lib/abi/lp.ts
app/lib/abi/erc20.ts
app/lib/contracts.ts
app/lib/format.ts
app/lib/slippage.ts
app/lib/hooks/useTokens.ts
app/lib/__tests__/format.test.ts
app/lib/__tests__/slippage.test.ts
```

### 3.3 Files preserved

- `app/lib/wagmi.ts` — wagmi config (chain list, transports, connectors) is app-specific
- `app/lib/utils.ts` — `cn`, `shortAddr` UI utilities

### 3.4 Workspace plumbing

`pnpm-workspace.yaml`:
```yaml
packages:
  - app
  - packages/*
```

Root `package.json` (minimal — no Turbo/Nx; pnpm `-r` is sufficient for two packages):
```json
{
  "name": "arcoradex-monorepo",
  "private": true,
  "scripts": {
    "build": "pnpm -r build",
    "test": "pnpm -r test",
    "typecheck": "pnpm -r typecheck",
    "lint": "pnpm -r lint",
    "dev": "pnpm --filter app dev"
  },
  "engines": { "node": ">=22", "pnpm": ">=10" }
}
```

`packages/sdk/package.json`:
```json
{
  "name": "@arcoralabs/dex-sdk",
  "version": "0.1.0",
  "type": "module",
  "exports": {
    ".":      { "types": "./src/index.ts",       "default": "./src/index.ts" },
    "./react":{ "types": "./src/react/index.ts", "default": "./src/react/index.ts" }
  },
  "files": ["dist", "src", "README.md"],
  "scripts": {
    "build":     "tsup",
    "test":      "vitest run",
    "typecheck": "tsc --noEmit",
    "lint":      "eslint src test"
  },
  "peerDependencies": {
    "viem": "^2.20.0",
    "wagmi": "^2.14.0",
    "@tanstack/react-query": "^5.0.0",
    "react": "^18.0.0 || ^19.0.0"
  },
  "peerDependenciesMeta": {
    "wagmi":   { "optional": true },
    "@tanstack/react-query": { "optional": true },
    "react":   { "optional": true }
  }
}
```

Source-direct dev: app's `import { useTokens } from "@arcoralabs/dex-sdk/react"` resolves through the pnpm symlink to `packages/sdk/src/react/index.ts`. Next.js Turbopack handles TypeScript in workspace dependencies natively. No build step required during local development; SDK code edits hot-reload in the app.

For v1.0 publish, the `exports` map's "production" condition will be flipped to `./dist/index.mjs` and `./dist/react.mjs` (a CI script switches it before `pnpm publish`).

## 4. Public API

### 4.1 Core (`@arcoralabs/dex-sdk`)

```ts
import { createArcoraDex, arcTestnet } from "@arcoralabs/dex-sdk";
import { http } from "viem";

const sdk = createArcoraDex({
  chain: arcTestnet,
  transport: http(),
  account: optionalViemAccount,
  addresses: optionalOverrides,    // default: v1.0-testnet for arcTestnet.id
});
```

#### Read methods (no account required)

```ts
sdk.quoteSwap({ tokenIn, tokenOut, amountIn })
  → bigint                                            // amountOut net of fee

sdk.quoteDeposit({ token, amount })
  → bigint                                            // lpOut

sdk.quoteWithdraw({ tokenOut, lpAmount })
  → { amountOut: bigint, protocolFee: bigint }

sdk.getPoolStats()
  → {
      navUsd1e18: bigint,
      lpSupply: bigint,
      lpPriceUsd1e18: bigint,
      swapFeeBps: number,
      protocolFeeShareBps: number,
      paused: boolean,
    }

sdk.getTokens({ activeOnly?: boolean })
  → Array<{
      address: `0x${string}`;
      symbol: string;
      name: string;
      decimals: number;
      isActive: boolean;
      oracle: `0x${string}`;
      maxOracleDeviationBps: number;
    }>

sdk.getReserves()
  → Record<`0x${string}`, bigint>                     // token → raw reserve

sdk.getPosition(addr)
  → {
      lpBalance: bigint,
      usdValue1e18: bigint,
      sharePct: number,                               // 0..1
    }

sdk.getProtocolFees(token)
  → bigint
```

#### Write methods (account required; throws `MissingAccountError` if absent)

```ts
sdk.swap({
  tokenIn, tokenOut, amountIn,
  slippageBps: number,                                // required
  deadline?: bigint,                                  // default = now + 20m
  recipient?: `0x${string}`,                          // default = account.address
  exactApproval?: boolean,                            // default = false (= MAX_UINT256)
})
  → {
      approveHash?: `0x${string}`,                    // present iff approval was needed
      hash: `0x${string}`,                            // swap tx
      receipt: TransactionReceipt,
      amountOut: bigint,
      event: SwappedEventDecoded,                     // user, tokenIn, tokenOut, amountIn,
                                                      // amountOut, lpFeeUsd1e18,
                                                      // protocolFeeAmtOut, recipient,
                                                      // blockNumber, txHash, logIndex
    }

sdk.deposit({ token, amount, slippageBps, deadline?, exactApproval? })
  → { approveHash?, hash, receipt, lpMinted, event: DepositedEventDecoded }

sdk.withdraw({ tokenOut, lpAmount, slippageBps, deadline? })
  → { hash, receipt, amountOut, event: WithdrewEventDecoded }
  // No approval needed — LP burn is internal.
```

Auto-approval is opaque to the caller in the simple path: one `await`, two wallet popups. The returned `result.approveHash` is non-undefined iff an approval transaction was sent. UIs can render staged toasts ("Approving allowance…" → "Swapping…") off this signal.

`exactApproval: true` approves only the amount needed for this single transaction. Default `false` approves `MAX_UINT256` so subsequent swaps require no further approvals — standard DEX UX.

#### Subscriptions

```ts
const unsub = sdk.subscribeSwaps(
  (event: SwappedEventDecoded) => void,
  { fromBlock?: bigint }
);

const unsub = sdk.subscribeDeposited(handler);
const unsub = sdk.subscribeWithdrew(handler);
const unsub = sdk.subscribePoolStats(handler);   // fires on each new block

unsub();   // tears down the watcher
```

Built on viem's `watchContractEvent` and `watchBlockNumber`. Multiple subscriptions of the same event share the underlying watcher (refcounted) for efficiency.

#### Utility namespaces

```ts
sdk.format.units(value: bigint, decimals: number, displayDecimals?: number): string
sdk.format.usd(value1e18: bigint, displayDecimals?: number): string
sdk.format.tryParseUnits(input: string, decimals: number): bigint | null
sdk.format.tokenLabel(addr: `0x${string}`): { symbol: string; name: string }

sdk.slippage.minOut(quoted: bigint, slippageBps: number): bigint
sdk.slippage.deadline(secondsFromNow?: number): bigint
```

These also exist as standalone exports for tree-shake-friendly consumption: `import { fmtUnits, minOut } from "@arcoralabs/dex-sdk"`.

### 4.2 React (`@arcoralabs/dex-sdk/react`)

```tsx
import {
  ArcoraDexProvider,
  useArcoraDex,
  useTokens,
  useQuoteSwap,
  useQuoteDeposit,
  useQuoteWithdraw,
  usePoolStats,
  usePosition,
  useSwap,
  useDeposit,
  useWithdraw,
  useAllowance,
  useSwapHistory,
} from "@arcoralabs/dex-sdk/react";
```

#### Provider

```tsx
<WagmiProvider config={wagmiConfig}>
  <QueryClientProvider client={queryClient}>
    <ArcoraDexProvider
      chain={arcTestnet}                    // optional; default = wagmi's selected chain
      addresses={...}                        // optional; default = v1.0-testnet
    >
      <App />
    </ArcoraDexProvider>
  </QueryClientProvider>
</WagmiProvider>
```

The provider derives the underlying SDK instance from wagmi's `useChainId`, `useAccount`, `usePublicClient`, `useWalletClient`. Re-creates the instance only when those identities change (memoized).

#### Hooks

```ts
const sdk = useArcoraDex();           // raw instance for escape-hatch use

const { tokens, activeTokens, isLoading } = useTokens();

const { data: amountOut, isFetching, error } = useQuoteSwap(
  { tokenIn, tokenOut, amountIn },
  { debounceMs?: number, enabled?: boolean }
);

const { data: lpOut } = useQuoteDeposit({ token, amount }, { debounceMs });

const { data: { amountOut, protocolFee } } = useQuoteWithdraw(
  { tokenOut, lpAmount },
  { debounceMs }
);

const { stats } = usePoolStats({ refetchOnBlock?: boolean });

const { position } = usePosition();   // user's LP balance + USD value

const { events: swaps, isLoading } = useSwapHistory({
  limit?: number,                     // default 50
  watch?: boolean,                    // default true; subscribes for incremental updates
  fromBlock?: bigint,
});

const { isApprovalNeeded, ensureAllowance, isPending } = useAllowance({
  token, spender, amount,
});

const { mutate: swap, isPending, error } = useSwap();
swap(
  { tokenIn, tokenOut, amountIn, slippageBps: 50 },
  { onSuccess: (result) => toast(`Swapped → ${result.amountOut}`) }
);
// Same for useDeposit, useWithdraw.
```

Hook layer responsibilities:
- React Query state management (`isLoading`, `isFetching`, `error`, `refetch`)
- `useQuoteSwap` debounces input + auto-cancels stale fetches
- Write hooks invalidate corresponding read queries on success
- `usePoolStats({ refetchOnBlock: true })` invalidates on each new block (via wagmi `useBlockNumber`)
- `useSwapHistory({ watch: true })` does an initial `getLogs` + subscribes for new events; maintains stable rolling-window state

### 4.3 Errors

Typed error hierarchy (all extend `ArcoraDexError extends Error`):

```ts
class MissingAccountError                              // write call without account
class InsufficientBalanceError       { token; balance; required }
class InsufficientLiquidityError     { token; requested; available }
class FirstDepositTooSmallError      { usd; minimum }
class SlippageExceededError          { actual; minOut }
class OracleStaleError               { token }
class OracleDeviationError           { token; newPrice; prev; maxDevBps }
class PoolPausedError
class TokenNotActiveError            { token }
class DeadlinePassedError
```

`parseContractError(viemError: BaseError | ContractFunctionRevertedError): ArcoraDexError`

Decodes the revert selector against the SDK's known error signatures; returns the matched typed error or a generic `ArcoraDexError` for unknown reverts. Frontend can `catch (e instanceof SlippageExceededError) { ... }` to drive UX.

## 5. Build & Dev Workflow

### 5.1 Source-direct dev (no build during iteration)

The pnpm workspace symlinks `packages/sdk/` into `app/node_modules/@arcoralabs/dex-sdk`. `package.json` `exports` point at `./src/index.ts` and `./src/react/index.ts` (TypeScript source). Next.js Turbopack compiles workspace TypeScript dependencies inline. SDK code edits hot-reload in the app dev server with no manual build step.

### 5.2 Production build (run before publish)

`packages/sdk/tsup.config.ts`:
```ts
import { defineConfig } from "tsup";

export default defineConfig({
  entry: { index: "src/index.ts", react: "src/react/index.ts" },
  format: ["esm"],
  dts: true,
  splitting: true,
  treeshake: true,
  sourcemap: true,
  clean: true,
  external: ["react", "wagmi", "viem", "@tanstack/react-query"],
});
```

Output: `dist/index.mjs`, `dist/index.d.mts`, `dist/react.mjs`, `dist/react.d.mts`. Total bundle target: < 50 KB minified for core (excluding peer deps), < 30 KB for `/react`.

A pre-publish CI script flips `package.json` `exports` from `./src/*` to `./dist/*` (production condition). v0.x publish is manual; v1.0+ may use Changesets.

### 5.3 TypeScript config

`packages/sdk/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["DOM", "DOM.Iterable", "ES2022"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noEmit": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "isolatedModules": true,
    "jsx": "react-jsx",
    "declaration": true,
    "paths": { "@/*": ["./src/*"] }
  },
  "include": ["src/**/*", "test/**/*"],
  "exclude": ["dist", "node_modules"]
}
```

`tsconfig.build.json` extends the above with `noEmit: false` for type emission during `tsup --dts`.

### 5.4 ESLint

SDK has its own flat config (`packages/sdk/eslint.config.mjs`), stricter than `app/`:
- `@typescript-eslint/no-explicit-any: error`
- `@typescript-eslint/consistent-type-exports: error`
- `@typescript-eslint/consistent-type-imports: error`
- `prefer-const: error`
- `no-console: warn`

Library code holds itself to a higher type discipline than UI code.

## 6. Frontend Migration

The frontend refactor lands as **task T12** in the implementation plan — a single atomic refactor commit (gated by all-green typecheck/test/build).

### 6.1 Per-component diff

| Component | Old behavior | New behavior |
|---|---|---|
| `SwapCard.tsx` | Manual allowance check, two-button "Approve → Swap" flow | Single "Swap" button via `useSwap` (auto-approve internal); staged toast for approve→swap |
| `DepositTab.tsx` | Manual allowance, separate approve | Single "Deposit" button via `useDeposit` |
| `WithdrawTab.tsx` | Direct `useWriteContract` + `quoteWithdraw` | `useWithdraw` + `useQuoteWithdraw` |
| `PositionPanel.tsx` | `useReadContracts([lp, pool])` | `usePosition` + `usePoolStats` |
| `ReservesTable.tsx` | Direct `useReadContract`s | `usePoolStats` + `useTokens` + `getReserves` (via `useArcoraDex`) |
| `SwapHistory.tsx` | Inline `usePublicClient().getLogs()` + manual decimals lookup | `useSwapHistory({ watch: true })` |
| `Providers.tsx` | `WagmiProvider` + `QueryClientProvider` | + `<ArcoraDexProvider>` |

### 6.2 Refactor invariant

After T12, `git grep -l "@/lib/abi\|@/lib/contracts\|@/lib/format\|@/lib/slippage\|@/lib/hooks/useTokens"` over `app/` returns nothing. The only remaining `app/lib/*` files are `wagmi.ts` and `utils.ts`. The SDK is the single source of truth.

### 6.3 UI smoke after migration

`swap.arcorapay.xyz` Vercel deploy round-trip on Arc testnet:
1. Connect wallet
2. Swap 10 USDC → EURC (auto-approve fires on first run)
3. Swap 10 USDC → DAI (no approve — allowance covered by MAX_UINT256)
4. Deposit 100 USDC → ADEX-LP minted
5. Withdraw 1 ADEX-LP → tokenOut received
6. Reload page; PositionPanel + ReservesTable + SwapHistory all render correct decimals + values

This is a manual smoke; not a Playwright run. T13 covers it explicitly in the plan's Definition of Done.

## 7. Testing Strategy

Three layers, all under `packages/sdk/test/`.

### 7.1 Unit tests

Pure JS, no chain dependency. ~20 tests.

- `format.test.ts` — `units`, `usd`, `tryParseUnits` (carries forward existing `app/lib/__tests__/format.test.ts` cases)
- `slippage.test.ts` — `minOut`, `deadline` (carries forward)
- `errors.test.ts` — `parseContractError` decodes each known revert selector to the right typed error class; unknown selectors return generic `ArcoraDexError`
- `tokens.test.ts` — `tokenLabel` normalization through viem's `getAddress` for case-mixed inputs

### 7.2 Integration tests

Anvil-backed. Fresh `ArcoraDexPool/Registry/LP` deploy per test file.

`test/setup.ts` exports `bootstrapAnvil()`:
1. `child_process.spawn('anvil', ['--silent', '--port', randomPort])` — startup ~3s
2. Reads contracts via `forge script ../../contracts/script/DeployArcoraDex.s.sol --rpc-url http://localhost:port --broadcast --private-key 0xac0974... --silent` — ~2s
3. Parses `contracts/broadcast/.../run-latest.json` for deployed addresses
4. Returns `{ rpcUrl, addresses, mintToken(token, to, amount), getReadSdk(), getWriteSdk(privateKey?) }` helpers

Integration test files (~30 tests across the files below):
- `client.test.ts` — read-only mode, with-account mode, addresses default vs override, `MissingAccountError` on write without account
- `read.test.ts` — quote vs view parity (`quoteSwap` agrees with the on-chain `quote` at byte level), `getPoolStats`, `getTokens`, `getReserves`, `getPosition`, `getProtocolFees`
- `swap.test.ts` — first-swap auto-approve path (`approveHash` defined), subsequent swap (no approval), `exactApproval: true` behavior, `recipient` override, slippage revert maps to `SlippageExceededError`, decoded `event` payload
- `deposit.test.ts` — first-deposit `MIN_LIQUIDITY` burn → `lpMinted == usd - 1000`, subsequent proportional, `FirstDepositTooSmallError` on tiny first deposit
- `withdraw.test.ts` — single-token, fee in tokenOut, `InsufficientLiquidityError` when reserves are exhausted, no approval transaction
- `errors.test.ts` — force-revert each path; verify the matched error class
- `subscriptions.test.ts` — `subscribeSwaps` receives an event for a triggered swap; `unsub()` halts callbacks; `subscribePoolStats` fires on each new block (via `vm.mine`)

### 7.3 React tests

Anvil-backed + `@testing-library/react`. ~15 tests.

`test/react/TestWrapper.tsx` mounts `<WagmiProvider>` + `<QueryClientProvider>` + `<ArcoraDexProvider>` with a mock connector (wagmi `mock` connector wired to a deterministic private-key account).

- `useTokens.test.tsx` — initial loading state, then settles to the active token list
- `useQuoteSwap.test.tsx` — debounce with fake timers, returns null on invalid input
- `useSwap.test.tsx` — `mutate({ ... })` triggers approve+swap tx chain, calls `onSuccess` with decoded event, invalidates `useTokens` and `usePosition` queries
- `usePoolStats.test.tsx` — `refetchOnBlock: true` triggers refetch on `vm.mine`
- `useSwapHistory.test.tsx` — `watch: true` updates incrementally when a new swap lands

### 7.4 CI

`.github/workflows/sdk.yml` (new):
```yaml
name: sdk
on:
  push:
    branches: [main]
    paths: ['packages/sdk/**', '.github/workflows/sdk.yml']
  pull_request:
    paths: ['packages/sdk/**', '.github/workflows/sdk.yml']
jobs:
  test:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: packages/sdk } }
    steps:
      - uses: actions/checkout@v4
      - uses: foundry-rs/foundry-toolchain@v1
      - uses: pnpm/action-setup@v3
        with: { version: 10 }
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: pnpm, cache-dependency-path: pnpm-lock.yaml }
      - run: pnpm install --frozen-lockfile
      - run: pnpm typecheck
      - run: pnpm lint
      - run: pnpm test                      # vitest covers unit + integration + react
      - run: pnpm build
```

Run time: unit < 1s, integration ~30–60s (Anvil overhead amortized), React ~30s. Total ~1 min on a clean GH Actions runner.

### 7.5 Coverage targets

- `packages/sdk/src/`: line ≥ 90%, branch ≥ 80%
- v8 provider (Vitest default), CI artifact

## 8. Versioning & Publish

- v0.1.0 ships as **workspace-only**. No NPM publish during Phase B.
- Iteration in `0.x` is unconstrained — breaking changes welcome until the v1.0 publish gate.
- Phase B implementation completion (T13) tags `sdk-v0.1.0` locally for archaeology.
- v1.0 publish trigger (per spec §10): "30 days stable on testnet" or "third-party integration demand."
- v1.0 publish process is a separate short spec (`docs/superpowers/specs/<date>-sdk-v1-publish.md`): tsup build → flip `exports` to dist → `pnpm publish --access public` → GitHub release.
- Optional Changesets integration deferred until v1.0 (Phase B v0.x has no public consumers; manual versioning is fine).

## 9. Build Sequence (Phase B v0.1)

13 tasks across 3 bands. Each task lands a single commit with all-green checks (typecheck, lint, test, build at the relevant scope).

### Band 1 — Workspace + skeleton (T1–T2)
1. **T1** — `pnpm-workspace.yaml`, root `package.json`, `packages/sdk/` skeleton with empty `src/index.ts` and `src/react/index.ts` barrels. Add `"@arcoralabs/dex-sdk": "workspace:*"` to `app/package.json`. `pnpm install` + `pnpm -r typecheck` green.
2. **T2** — SDK ESLint flat config (strict ruleset). `pnpm -r lint` green.

### Band 2 — Core SDK (T3–T9, TDD)
3. **T3** — Helpers move: `format/`, `slippage/`, `errors.ts` (typed error classes + `parseContractError` against synthetic encoded selectors). ~15 unit tests.
4. **T4** — `abi/`, `addresses.ts`, `tokens/`, `chains/arcTestnet.ts`. Unit tests for `tokenLabel` normalization.
5. **T5** — `createArcoraDex` + read actions (`quoteSwap`, `quoteDeposit`, `quoteWithdraw`, `getPoolStats`, `getTokens`, `getReserves`, `getPosition`, `getProtocolFees`). Anvil integration tests (~10).
6. **T6** — Write actions (`swap`, `deposit`, `withdraw`) with auto-approve via `allowance.ts`. Integration tests (~10).
7. **T7** — Error path coverage: force-revert each contract error path against Anvil and verify it surfaces as the matched typed error class introduced in T3. Integration tests (~6).
8. **T8** — Subscriptions (`subscribeSwaps`, `subscribeDeposited`, `subscribeWithdrew`, `subscribePoolStats`). Integration tests (~4).
9. **T9** — Public barrel finalize. `pnpm --filter @arcoralabs/dex-sdk build` smoke; verify `dist/` types are correct via TypeScript module-resolution test.

### Band 3 — React + frontend migration (T10–T13)
10. **T10** — `src/react/`: `ArcoraDexProvider`, `useArcoraDex`, `useTokens`, read hooks (`useQuoteSwap`, `useQuoteDeposit`, `useQuoteWithdraw`, `usePoolStats`, `usePosition`). React tests (~6).
11. **T11** — Write hooks (`useSwap`, `useDeposit`, `useWithdraw`, `useAllowance`) + `useSwapHistory`. React tests (~9). All ~65 SDK tests green (~20 unit + ~30 integration + ~15 react).
12. **T12** — App migration: delete `app/lib/{abi,contracts,format,slippage,hooks/useTokens}` + their tests. Refactor `app/components/{swap,liquidity,pool,wallet}/*` and `Providers.tsx` onto SDK hooks. SwapCard becomes single-button. App `pnpm typecheck && pnpm test && pnpm build` green.
13. **T13** — Vercel preview deploy → manual UI round-trip smoke (per §6.3) → promote to production at `swap.arcorapay.xyz` → fast-forward `feat/sdk-phase-b` to `main` → tag `sdk-v0.1.0`.

### Dependencies
- T1 → T2 (lint config needs lint to be wired)
- T3, T4 parallel-safe (independent helpers)
- T5 → T6 → T7 (write needs allowance helper from T6's pre-step)
- T8 independent of T5–T7 once T4 lands
- T10 needs T5+T6+T7 (read+write actions exist before hooks wrap them)
- T11 → T12 (frontend can't migrate until all hooks exist)
- T13 strict last (Vercel deploy + tag)

### Definition of Done
- ✅ `pnpm -r typecheck && pnpm -r lint && pnpm -r test && pnpm -r build` green
- ✅ `app/lib/` contains only `wagmi.ts` and `utils.ts`
- ✅ `swap.arcorapay.xyz` round-trip smoke clean (swap, deposit, withdraw)
- ✅ ~65 SDK tests green (~20 unit + ~30 integration + ~15 react), CI < 2 min
- ✅ `sdk-v0.1.0` tag pushed
- ✅ This spec + plan + final review captured under `docs/superpowers/`

## 10. Out of Scope (explicit non-goals for Phase B v0.1)

- NPM publish (Phase B v1.0)
- Changesets / automated version bumps
- typedoc auto-generated API reference (Phase D — docs site)
- React Native compatibility audit (no current need)
- Multi-chain SDK (only Arc Testnet now; mainnet is Phase E)
- CLI tool wrapping the SDK
- Vercel AI SDK integration (`tools` array for agentic flows) — natural follow-up but not v0.1

## 11. Open Questions / Deferred Decisions

- **NPM `@arcoralabs` scope ownership** — needs to be registered before the v1.0 publish step. No-op for Phase B v0.1.
- **`useSwapHistory` retention strategy** — for now, in-memory rolling window of `limit` entries. Persistent indexing belongs in Phase C.
- **Subscription multiplexing** — viem's `watchContractEvent` already deduplicates underlying RPC subscriptions when called multiple times with the same args; SDK layer doesn't need explicit refcounting unless profiling shows hot-path waste.
- **Error parsing fallback for proxy-routed reverts** — Arc testnet has no proxy contracts in our flow, so this is moot for v0.1; if v1.x ever proxies through a router, `parseContractError` will need recursive selector lookup.
