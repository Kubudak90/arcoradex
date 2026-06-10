# Base Sepolia V2 — §13-step-2 Drill Runbook

Run AFTER `DeployBaseSepoliaV2.s.sol` succeeds and the address ledger is captured into
`ops/basekeeper/.env` (REGISTRY, POOL, LP, GOV_SAFE, TIMELOCK, ADAPTER_{USDC,USDT,EURC},
EURC_MOCK_CL_FEED, TOKEN_{USDC,USDT,EURC}). These drills exercise spec §11 (oracle failure
behavior), §7 (marginal fee bands / reserve floor), §8.3 (proportional emergency exit), and
§12 (the monitorable signals each drill emits). They are the §13-step-2 gate before the
mainnet rollout (§13 steps 4-7, a separate plan).

Permissionless drills are executable via the `cast` scripts under `ops/basekeeper/drills/`.
Drills that require an owner action (Registry/Pool owned by the Timelock; adapters by the Gov
Safe) document the Safe/Timelock procedure — they CANNOT be a one-liner because the deploy
hands ownership to multisig governance.

## Pre-flight
- Keeper has pulled Pyth fresh: `node ops/basekeeper/update-pyth-base-sepolia.mjs` (all 3 legs).
- Deployer/test account holds test-token balances (the deploy minted seed; mint more via the
  Timelock-owned... NO — tokens stay deployer-owned for testnet faucet convenience; see deploy
  Task 2 Step 6 note. Mint test tokens directly with the deployer key as needed.)

## Drill 1 — Oracle failure (EURC mock CL leg stale)  [permissionless]
Goal (§11): when EURC's Chainlink leg goes stale, EURC becomes unsafe -> swaps INTO EURC and
single-token withdrawals INTO EURC revert; proportional exit still works.
Mechanism: the EURC Chainlink leg is the in-process `MockChainlinkFeed`; its `setAnswer` is
owner-gated. The deploy leaves the mock CL feed owned by the DEPLOYER (testnet operator) — NOT
governance — precisely so this drill is a one-liner. Stop the keeper, let `updatedAt` age past
`chainlinkMaxStaleSeconds` (7d) OR (faster) point the adapter's window tighter is governance —
instead, deploy a second short-window EURC adapter for the drill, OR warp on a fork.
Run (fork-time, deterministic): `bash ops/basekeeper/drills/01-oracle-failure.sh`
Observe: `cast call POOL "quoteSwapV2(address,address,uint256)" USDC EURC 1000000` reverts with
`OracleUnsafe(EURC)`; `cast send POOL "withdrawProportional(uint256,uint256)" <lp> <deadline>`
succeeds. §12 signal: adapter `peekPrice(EURC).safe == false`.

## Drill 2 — Divergence drill  [permissionless]
Goal (§10): when the EURC mock CL leg and the Pyth EURC price diverge beyond `maxDivergenceBps`,
EURC is unsafe. Set the mock CL leg to $1.30 while Pyth EURC is ~$1.08:
Run: `bash ops/basekeeper/drills/02-divergence.sh`
Observe: `peekPrice(EURC).safe == false`; swaps into EURC revert. §12 signal: primary/secondary
divergence over bound.

## Drill 3 — Stale-price drill (Pyth leg)  [permissionless]
Goal (§11): stop pulling Pyth; after `pythMaxStaleSeconds` (24h) all three tokens' Pyth legs go
stale and every token is unsafe. (On a fork, warp `pythMaxStaleSeconds + 1`.)
Run: `bash ops/basekeeper/drills/03-stale-pyth.sh`
Observe: all `peekPrice(*).safe == false`; the keeper pull (`update-pyth-base-sepolia.mjs`)
restores safety. §12 signal: Pyth freshness alarm.

## Drill 4 — Confidence drill  [fork-only, documented]
Goal (§10): a blown Pyth confidence ratio (> `pythMaxConfBps`) makes a token unsafe. Live Sepolia
Pyth confidence cannot be forced; on a fork, `vm.mockCall` the Pyth `getPriceUnsafe` to return a
high `conf`. Documented in `DeployBaseSepoliaV2.t.sol::test_drill_confidence` (Task 3).

## Drill 5 — Reserve-floor drill  [permissionless]
Goal (§7): a swap large enough to push the output reserve below `minimumReserveUsd` reverts
`ReserveFloorBreached`; the max floor-safe amount (`maxSwapOut`) succeeds.
Run: `bash ops/basekeeper/drills/05-reserve-floor.sh`
Observe: an over-max `cast call POOL "quoteSwapV2"...` reverts `ReserveFloorBreached(tokenOut)`;
`maxSwapOut(tokenOut)` returns the safe ceiling and a swap at that amount succeeds.

## Drill 6 — Marginal-fee verification  [permissionless]
Goal (§7/§14): one large swap pays the same total fee as the sum of split swaps (within rounding),
and a deeper-band swap pays a higher marginal rate. Compare `quoteSwapV2` fee for one large vs N
small amounts spanning a band boundary.
Run: `bash ops/basekeeper/drills/06-marginal-fee.sh`
Observe: `fee(one) ~= sum(fee(split))`; printed fee/health breakdown matches the §7 schedule.

## Drill 7 — Emergency proportional exit  [permissionless]
Goal (§8.3): `withdrawProportional` returns the pro-rata basket of EVERY reserve, works while a
token is unsafe (Drill 1 state) and while paused (Drill 8 state), excludes protocol fees.
Run: `bash ops/basekeeper/drills/07-proportional-exit.sh`
Observe: caller receives a share of all 3 tokens; succeeds even with EURC unsafe / pool paused.

## Drill 8 — Pause drill  [Pause Guardian (PG Safe) + Timelock]
Goal (§6.2/§12): the Pause-Guardian Safe can `pause()` immediately; only the Timelock (Pool owner)
can `unpause()`. This is the §12 "live pause drill" gate.
Procedure (multisig — documented, not a one-liner):
1. PG Safe (2/3) builds + signs `pause()` on POOL, executes. `cast call POOL "paused()"` == true.
   Swaps/deposits/single-withdraws revert `PoolPaused`; `withdrawProportional` still works (Drill 7).
2. Gov Safe (3/5) schedules a Timelock op calling `POOL.unpause()`, waits the 48h delay (or the
   delay configured at deploy), executes. `paused()` == false.
§12 signal: Pool pause-state change observed by monitoring; Timelock proposal + execution observed.
