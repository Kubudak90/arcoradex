# Base V2 Core Contracts — Review Punch List

Items surfaced by per-task reviews during plan execution. None are implementer errors —
all are properties of the plan/spec as written ("plan-gaps"). Decide + fix after Task 13,
before the external-review milestone (spec §15).

## From Task 4 review (RegistryV2, commit 98ff4db)

- **O1 — `minimumReserveUsd == 0` accepted by `_validate`.** CLOSED 3cbf0a6 — `_validate`
  now reverts `InvalidReserveBounds(token)` when `minimumReserveUsd == 0`. With min=0 the
  protected floor is zero and priced ops can drain a reserve fully before stopping. If §6.2
  intends a non-zero floor: `if (c.minimumReserveUsd == 0) revert InvalidReserveBounds(token);`
- **O2 — `setPool(address(0))` un-wires the pool and silently bypasses the I-1
  deactivate-with-reserves guard.** CLOSED 3cbf0a6 — `setPool(address(0))` now reverts
  `ZeroAddress()` (initial pre-setPool zero state remains valid). Either forbid zero in
  `setPool` or make the guard unconditional. Low severity (owner = 48h Timelock) but I-1
  should arguably be absolute.
- **O3 — `setTokenConfig` on a live token can raise `minimumReserveUsd` above current
  reserves (retroactive floor).** Internally consistent (re-validated) and likely intended
  as governance responsibility — confirm intent, document in the ops runbook.

## From Task 6 review (PoolV2 core, commit 977d000)

- **O4 — per-token `TokenConfigV2.protocolFeeShareBps` is dead weight:** CLOSED 3cbf0a6 —
  removed the per-token field + its validation + the now-unused registry
  `InvalidProtocolFeeShareBps` error; the pool-level state var is the single source of truth
  (V1 pattern); pricing code unchanged. swap/quote use the POOL-LEVEL state var in all
  traverse calls (per plan). Either remove the per-token field or make pricing honor it —
  decide before external review.
- **O5 — `notifyLPTransfer` could be `view`** (compiler warning, cosmetic; in plan + impl).

## From Tasks 7+8 review (withdrawals)

- **O6 — real-adapter view/mut NAV divergence:** `quoteWithdrawV2`/`quoteSwapV2` use
  `peekPrice` (view) while execution uses `readPrice` (mut). Identical under the mock; a
  real Chainlink/Pyth adapter that mutates on read could diverge quote vs exec. The
  REAL-ADAPTER PLAN must guarantee peek==read within a block or document the bound.
- Task 10 must pin: withdrawSingle-when-paused, and withdrawSingle stopped by an unsafe
  price on a DIFFERENT active token (any-token-unsafe via `_navMut`).

## From Task 4 implementer (matching plan exactly — missing dedicated tests)

- `InvalidDecimals` out-of-range branch: revert exists, no dedicated test. CLOSED 3cbf0a6 —
  added `test_reject_decimalsOutOfRange` (decimals 0 and 19 both revert).
- `InvalidProtocolFeeShareBps` branch: revert exists, no dedicated test. CLOSED 3cbf0a6 —
  moot: the per-token branch + error were removed by O4.

## From Task 9 review/implementer (views)

- **O7 — `maxSwapOut`/`maxWithdraw` understate by ~1.7%** (upper search bound = usable
  reserve, below true fee-adjusted max). Deliberate no-overstate choice; if the app's Max
  button should be tighter, raise the bound to `usable*BPS/(BPS-maxBandRate)` keeping the
  ok-largest invariant. UI/SDK plan should be aware.
- Plan's Task 9 Step-1 test had a transcription defect (3M input vs revert-on-breach swap);
  fixed faithfully to intent — noted for plan-author awareness.

## RESOLVED during execution — §7 anti-split violation (was CRITICAL)

- Adjudicated real bug: above-target reserves let split txs refresh band-0 capacity →
  split saved up to ~94 bps vs single. FIXED in `a6ac2fb` (excess credited to band 0;
  3.2M-reserve sweep: split==single exact above target; below-target byte-identical).
- Residual (by design): below-target MID-BAND-STRADDLE chained halves diverge ~0.003 USD
  in the PROTECTIVE direction (split pays more). INV-5 equality therefore keeps a
  below-target guard. Follow-up idea: make INV-5 one-sided (splitFee >= singleFee - 8wei)
  to probe all regimes. Spec author should also note §7's "bounded integer rounding"
  wording is strictly true only as a one-sided guarantee.
