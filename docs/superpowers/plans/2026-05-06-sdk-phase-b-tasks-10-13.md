# Phase B Implementation Plan — Tasks 10–13 (React layer + frontend migration + deploy)

> Continuation of `2026-05-06-sdk-phase-b.md` and `2026-05-06-sdk-phase-b-tasks-5-9.md`. SDK core complete after T9; this file finishes the React layer, migrates the frontend onto the SDK, and ships to production.

## T10 — Read hooks + ArcoraDexProvider (TDD)

Creates `src/react/ArcoraDexProvider.tsx` (React context provider deriving the SDK instance from wagmi: `useChainId`, `useAccount`, `usePublicClient`, `useWalletClient`; memoized so the SDK is recreated only when chain/account/transport identity changes), `useArcoraDex` (returns the raw SDK from context), and the read hooks: `useTokens`, `useQuoteSwap`, `useQuoteDeposit`, `useQuoteWithdraw`, `usePoolStats`, `usePosition`.

Each hook wraps a SDK action with `@tanstack/react-query` `useQuery`. Query keys: `["arcora", "tokens", chainId]`, `["arcora", "quoteSwap", chainId, tokenIn, tokenOut, amountIn]`, etc. `useQuoteSwap` debounces input via a small custom hook (`useDebouncedValue`); default `debounceMs: 400`. `usePoolStats` accepts `{ refetchOnBlock: boolean }`; when true, subscribes to `usePublicClient().watchBlockNumber` and invalidates the stats query on each new block.

`src/react/index.ts` barrel exports: `ArcoraDexProvider`, `useArcoraDex`, all read hooks.

Adds `test/react/TestWrapper.tsx` (mounts `<WagmiProvider>` with wagmi `mock` connector + the deployer's anvil private key, `<QueryClientProvider>`, `<ArcoraDexProvider>`) and react tests using `@testing-library/react` + `happy-dom`:

- `useTokens.test.tsx` — `renderHook` mounts the wrapper, asserts initial `isLoading: true` then `tokens.length === 7` after settle
- `useQuoteSwap.test.tsx` — debounce with `vi.useFakeTimers()`, returns `null` for invalid input, returns a positive bigint for valid 100 USDC → EURC
- `usePoolStats.test.tsx` — `refetchOnBlock: true`, mine a block via anvil RPC `evm_mine`, assert query refetched

~6 react tests.

## T11 — Write hooks + useSwapHistory + useAllowance

Creates `useSwap`, `useDeposit`, `useWithdraw` (all `useMutation`-based, on success they invalidate `useTokens`, `usePoolStats`, `usePosition` queries via `queryClient.invalidateQueries`). Mutation result is the SDK's `SwapResult`/`DepositResult`/`WithdrawResult` so the consumer's `onSuccess` callback can drive a toast directly off `result.event`.

`useAllowance({ token, spender, amount })` returns `{ isApprovalNeeded, ensureAllowance, isPending }`; `ensureAllowance` is a `useMutation` over `sdk.allowance()` (this hook is a convenience for components that want to inspect approval state separately rather than rely on the auto-approve inside `useSwap`/`useDeposit`).

`useSwapHistory({ limit, watch, fromBlock })` does an initial `getLogs` for the `Swapped` event (via `usePublicClient`), maintains a rolling window of `limit` entries (default 50) in component state, and when `watch: true` subscribes via `sdk.subscribeSwaps` to prepend new events. Returns `{ events, isLoading }`.

Updates `src/react/index.ts` barrel.

Adds react tests:
- `useSwap.test.tsx` — `mutate()` triggers approve+swap chain, calls `onSuccess` with decoded event, invalidates `useTokens` query
- `useSwapHistory.test.tsx` — `watch: true` updates incrementally when a swap lands on the SDK

~9 new react tests. All ~65 SDK tests green at this point (~20 unit + ~30 integration + ~15 react).

## T12 — App migration (atomic refactor)

This is the largest single task in the plan — one cohesive commit that migrates the whole frontend onto the SDK.

### Files removed

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

### Files modified

`app/components/wallet/Providers.tsx` — wraps children in `<ArcoraDexProvider>` inside the existing `<WagmiProvider>` + `<QueryClientProvider>`.

`app/components/swap/SwapCard.tsx` — drops the manual allowance/approve dance, becomes a single-button form. Imports `useTokens`, `useQuoteSwap`, `useSwap` from `@arcoralabs/dex-sdk/react`. The "Swap" button kicks off the SDK's auto-approve path; staged toast off `result.approveHash` (when defined) → `result.event`.

`app/components/liquidity/DepositTab.tsx` and `WithdrawTab.tsx` — analogous migrations to `useDeposit`, `useWithdraw`, `useQuoteDeposit`, `useQuoteWithdraw`.

`app/components/liquidity/PositionPanel.tsx` — `usePosition()` instead of multiple `useReadContract`s.

`app/components/pool/ReservesTable.tsx` — `usePoolStats()` + `useTokens()`; per-token reserve via `sdk.getReserves()` from `useArcoraDex()` (one-shot, not a hook because we render once on mount).

`app/components/pool/SwapHistory.tsx` — `useSwapHistory({ limit: 50, watch: true })`. The 6-decimal display fix from the spinoff cleanup carries forward in the SDK's `fmtUnits` + token-decimals lookup via `useTokens()`.

### Verification

`pnpm --filter app typecheck && pnpm --filter app lint && pnpm --filter app test && pnpm --filter app build` all green.

A `git grep` for the removed lib paths returns nothing in `app/`. The only remaining `app/lib/*` files are `wagmi.ts` and `utils.ts`.

### Commit

Single commit titled `refactor(app): migrate to @arcoralabs/dex-sdk + /react hooks (T12)`. Message references the spec/plan and notes the SwapCard simplification.

## T13 — Deploy + smoke + tag

1. **Vercel preview** — pushing the branch to GitHub triggers Vercel's preview build. Verify the preview URL renders all three pages without errors.

2. **Live UI smoke** — manual round-trip on the preview against the live Arc-testnet contracts:
   - Connect wallet (anvil-funded test address or real testnet wallet)
   - Swap 10 USDC → EURC (auto-approve fires on first run)
   - Swap 10 USDC → DAI (no approve — allowance was MAX_UINT256)
   - Deposit 100 USDC → ADEX-LP minted
   - Withdraw 1 ADEX-LP → tokenOut received
   - Reload page; PositionPanel + ReservesTable + SwapHistory all render correct decimals + values

3. **Promote to production** — `vercel --prod` on the merged main, alias to `swap.arcorapay.xyz`.

4. **Fast-forward main + tag** — push the worktree branch as `feat/sdk-phase-b`, fast-forward to `main`, tag `sdk-v0.1.0` annotated:
   ```
   git tag -a sdk-v0.1.0 -m "ArcoraDEX SDK v0.1.0 — workspace-only marker"
   git push origin sdk-v0.1.0
   ```

5. **Mark Phase B v0.1 complete** in roadmap (spec §10 Phase B status update can be a follow-up commit).

### Definition of Done

- ✅ `pnpm -r typecheck && pnpm -r lint && pnpm -r test && pnpm -r build` green at repo root
- ✅ `app/lib/` contains only `wagmi.ts` and `utils.ts`; no SDK-shaped files left
- ✅ `swap.arcorapay.xyz` round-trip smoke clean (swap, deposit, withdraw)
- ✅ ~65 SDK tests green (~20 unit + ~30 integration + ~15 react), CI < 2 min
- ✅ `sdk-v0.1.0` tag pushed
- ✅ Spec, plan (master + the two task continuations), and final review captured under `docs/superpowers/`

---

[End of plan. Phase B v1.0 NPM publish is a separate short spec, written when the spec §10 trigger fires.]
