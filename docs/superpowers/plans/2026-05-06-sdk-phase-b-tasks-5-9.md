# Phase B Implementation Plan — Tasks 5–9 (Core SDK)

> Continuation of `2026-05-06-sdk-phase-b.md`. Same TDD/commit conventions; SDK base SHA after T4 lands.

This continuation file covers T5 (factory + read actions), T6 (write actions with auto-approve), T7 (error path coverage), T8 (subscriptions), and T9 (public barrel finalize + build smoke).

Each task follows the TDD pattern from T1-T4: write failing test → run to confirm red → implement minimal code → run to confirm green → commit. File paths, code blocks, and commit messages are all explicit; the engineer follows the steps without re-deriving the design.

For brevity, full code listings for T5-T9 are inlined in the master plan handoff (provided to the implementer subagent at dispatch time) rather than duplicated here. The structure is identical to T3-T4: each task has 5-12 numbered steps; each code-changing step includes the complete file content; each test step shows the failing run command and the expected error.

## T5 — `createArcoraDex` factory + 8 read actions + Anvil harness

Creates `test/setup.ts` (vitest globalSetup that boots Anvil + runs `forge script DeployArcoraDex.s.sol`), `test/deploy.ts` (parses `broadcast/run-latest.json` to extract addresses), `src/types.ts` (result + event types), `src/client.ts` (factory binding read methods), eight files under `src/actions/` (quoteSwap, quoteDeposit, quoteWithdraw, getPoolStats, getTokens, getReserves, getPosition, getProtocolFees), and integration tests `client.test.ts` + `read.test.ts`. Updates `src/index.ts` barrel.

Anvil + foundry must be on PATH for tests; CI installs via `foundry-rs/foundry-toolchain@v1`.

Expected outcome: ~22 tests pass (T3 + T4 unit + T5 integration). First run ~30s (Anvil bootstrap), subsequent runs faster.

## T6 — Write actions with auto-approve

Creates `src/allowance.ts` (`ensureAllowance(client, token, spender, amount, exactApproval?)` reads allowance, sends `approve(MAX_UINT256)` if short or `approve(amount)` when exactApproval=true, waits for receipt, returns optional `approveHash`), three action files (`actions/swap.ts`, `actions/deposit.ts`, `actions/withdraw.ts`), and integration tests for each. Updates `client.ts` interface + binding and barrel.

Each write action: throws `MissingAccountError` if the SDK has no account; computes auto-quote → applies `slippageBps` to derive `minOut` → invokes `walletClient.writeContract` (wrapped in try/catch → `parseContractError`) → waits for receipt → decodes the `Swapped`/`Deposited`/`Withdrew` event from receipt logs → returns `{ approveHash?, hash, receipt, <amount field>, event }`.

`withdraw` skips `ensureAllowance` (LP burn is internal).

## T7 — Error path coverage

Adds `test/integration/errors.test.ts`. Direct-throw paths (`MissingAccountError` on read-only client write, `DeadlinePassedError` with deadline=1n) tested against real SDK calls. Selector-mapped classes (`SlippageExceededError`, `TokenNotActiveError`, `PoolPausedError`, generic fallback) tested via `parseContractError()` against synthetic ContractFunctionRevertedError shapes — same decoding code path the live SDK hits when contracts revert.

~6 new tests.

## T8 — Subscriptions

Creates four files under `src/subscriptions/` (`subscribeSwaps`, `subscribeDeposited`, `subscribeWithdrew`, `subscribePoolStats`). The first three wrap `viem.watchContractEvent` with the matching event name; each accepts `(handler, options?)` and returns an `Unsubscribe` function. `subscribePoolStats` wraps `viem.watchBlockNumber` and re-runs `getPoolStats` per block. Updates `client.ts` + barrel.

Adds `test/integration/subscriptions.test.ts` with two tests: handler is invoked when a swap is broadcast on the same SDK; `unsub()` halts further callbacks. Each test allows ~1.5s for viem's polling cycle.

## T9 — Public barrel finalize + tsup build smoke

Audits `src/index.ts` to confirm every public symbol is exported (factory, all types, addresses, chain, tokens, format, slippage, errors, read+write actions, subscriptions, allowance). Runs `pnpm --filter @arcoralabs/dex-sdk build` to produce `dist/{index,react}.{mjs,d.mts}`.

Adds `test/integration/build.test.ts` that asserts the four dist artifacts exist and `index.mjs` is non-trivially sized. This guards against future `pnpm publish` shipping a half-built bundle.

CI ordering: `typecheck` → `build` → `test` (build must precede the dist smoke test).

---

[T10–T13 continue in `2026-05-06-sdk-phase-b-tasks-10-13.md`.]
