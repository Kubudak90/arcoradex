# Wide-Audit (2026-05-31) Full Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remediate all 33 findings (2H / 3M / 11L / 12I / 5G) plus the audit's open-coverage items from `docs/audits/2026-05-31-wide-audit.md`, taking the maximal-scope decisions (real-key governance rotation, shared faucet store, full oracle source separation, behaviour-changing economic fixes) **without regressing any existing behaviour** — the contracts suite (148 tests) and the SDK/app suites stay green after every merged PR.

**Architecture:** Work is split into 9 PRs mirroring the repo's existing convention (one subsystem per PR, e.g. #53 app / #54 sdk / #55 contracts). PRs are ordered lowest-risk-and-most-isolated → behaviour-changing economics → off-chain → **irreversible on-chain rotation last**. Every code fix is TDD: a regression test that fails on current source is written first, then the fix makes it pass. Every PR ends with a full-suite green gate before merge. The on-chain governance rotation (PR-9) is a runbook executed only after all code + tests are merged and the new key custody is ready.

**Tech Stack:** Solidity 0.8.26 + Foundry (`forge`), TypeScript SDK + Vitest, Next.js 15 dApp + Vitest, Node ≥20 keeper (viem) + systemd, Safe multisig + OZ TimelockController, Upstash Redis / Vercel KV for the shared faucet store.

---

## Global conventions (read once, apply to every task)

- **Baseline test command (contracts):** `cd contracts && FOUNDRY_PROFILE=ci forge test` → expect `148 passed, 0 failed` before you start. (CI profile: 10k fuzz runs, invariant runs 1024 × depth 128, solc 0.8.26, evm cancun.) For fast iteration use plain `forge test --match-contract <Name>`.
- **Baseline test command (sdk):** `cd packages/sdk && pnpm test` (vitest, singleFork).
- **Baseline test command (app):** `cd app && pnpm test` (vitest, `lib/__tests__/**`).
- **Commit cadence:** one commit per task (test+fix together where TDD), conventional-commit prefix matching the finding, e.g. `fix(audit): H-1 LP-lock DoS (sender-gate)`.
- **Branching:** branch per PR off `main`, e.g. `audit/w-h1-lp-lock`. Never commit straight to `main`.
- **Don't-break rule:** if a fix forces an *existing* test to change, that change must be justified in the commit body (the old assertion encoded behaviour the fix intentionally alters). A fix that silently deletes a test is a red flag.
- **PR body footer:** end with the 🤖 Generated-with line; commit footer with the Co-Authored-By line.
- **First action of PR-1:** commit the audit report itself — `docs/audits/` is currently untracked (`git status` shows `?? docs/audits/`). Add it so the remediation has a tracked baseline:
  - [ ] `git add docs/audits/2026-05-31-wide-audit.md docs/audits/2026-05-24-full-sweep-audit.{html,pdf} && git commit -m "docs(audit): commit 2026-05-31 wide audit + prior full-sweep artifacts"`

---

## PR ordering & dependency map

| PR | Subsystem | Findings | Risk | Depends on | On-chain? |
|----|-----------|----------|------|------------|-----------|
| **PR-1** | contracts/security | H-1, + commit audit | Low (isolated) | — | no |
| **PR-2** | contracts/economics | L-9, L-10, I-1, I-2, I-3 + invariant-suite expansion | **High** | PR-1 | no |
| **PR-3** | contracts/oracle | H-2 (on-chain bounds), I-4, I-5, I-6, I-7, G-5 | Med | PR-2 | no (deployed in PR-9) |
| **PR-4** | contracts/gas | G-1, G-2, G-3, G-4 | Med (refactor) | PR-2, PR-3 | no |
| **PR-5** | contracts/scripts | L-7, L-8 (script), H-2 (key-separation scripts) | Low | PR-3 | no |
| **PR-6** | sdk | L-1, I-8, I-9, I-10, G-5(sdk) + hooks/subscriptions/addresses | Low | PR-3 (ABI parity) | no |
| **PR-7** | app | M-2, M-3, L-11, I-12, L-5, L-6 | Med | PR-6 (minOut) | no |
| **PR-8** | ops/keeper | L-2, L-3, L-4, I-11 + key-split + guard-monitor + TimeoutStartSec | Med | PR-5 | no |
| **PR-9** | governance rotation | M-1, L-8(live), H-2(live writers) | **Irreversible** | **all above** | **YES** |

**Why this order:** PR-1 ships the top public-testnet blocker in isolation. PR-2 makes the riskiest economic changes early, *while* hardening the invariant suite so PR-3/PR-4 refactors are caught if they drift NAV. PR-4 (gas refactor of the price stack) runs after the economic shape is final. PR-5/PR-8 prepare the scripts + keeper for separated keys. PR-9 is the only live-chain, irreversible step and runs last, after every code path it touches is merged and tested.

---

## PR-1 — H-1: LP min-hold lock weaponization (sender-gate)

**Files:**
- Modify: `contracts/src/ArcoraDexLP.sol:36-41` (`_update` hook)
- Modify: `contracts/src/ArcoraDexPool.sol:661-669` (`notifyLPTransfer`)
- Modify: `contracts/src/interfaces/IArcoraDexPool.sol` (add `EarlyTransfer` error)
- Test: `contracts/test/ArcoraDexPool.security.t.sol` (add offensive-direction tests; update 2 existing)
- Test: `contracts/test/ArcoraDexLP.t.sol:97-115` (update hook test)

**Why not the one-liner:** Adding only `value > 0` in `_update` does **not** close H-1 — an attacker holding ≥1 wei of LP can still `transfer(victim, 1)` and `notifyLPTransfer` will raise the victim's `lastMintAt`. The robust fix is to **gate the sender**: a transfer of locked LP reverts until the sender's own hold has elapsed, and the recipient's clock is never bumped by the sender. This still closes the deposit→transfer→withdraw JIT bypass (INV-9): you cannot move LP until your own 1h hold elapses, by which point you could have withdrawn yourself — so a fresh recipient withdrawing is equivalent to the sender withdrawing after hold. No griefing surface remains because `lastMintAt[victim]` now depends only on the victim's own deposits.

- [ ] **Step 1: Write failing offensive-direction tests**

In `contracts/test/ArcoraDexPool.security.t.sol`:
```solidity
function test_h1_zeroValueTransfer_doesNotLockVictim() public {
    // victim deposits, waits out the hold, is ready to withdraw
    _deposit(victim, usdc, 1_000e6);
    vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
    // attacker (fresh deposit => fresh lastMintAt) tries to re-lock victim via dust
    _deposit(attacker, usdc, 1e6);
    vm.prank(attacker);
    vm.expectRevert(); // value==0 must not reach notifyLPTransfer; see Step 3
    lp.transfer(victim, 0);
    // victim can still withdraw
    vm.prank(victim);
    pool.withdraw(usdc, lp.balanceOf(victim), 0, block.timestamp + 1, victim);
}

function test_h1_dustTransfer_fromLockedSender_reverts() public {
    _deposit(attacker, usdc, 1_000e6); // attacker now locked
    vm.prank(attacker);
    vm.expectRevert(IArcoraDexPool.EarlyTransfer.selector);
    lp.transfer(victim, 1); // sender within hold cannot move LP -> cannot grief
}

function test_h1_transfer_afterHold_succeeds_andDoesNotBumpRecipient() public {
    _deposit(alice, usdc, 1_000e6);
    vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
    uint256 bobLockBefore = pool.lastMintAt(bob);
    vm.prank(alice);
    lp.transfer(bob, lp.balanceOf(alice)); // allowed: alice past hold
    assertEq(pool.lastMintAt(bob), bobLockBefore, "recipient clock must not be bumped");
}
```

- [ ] **Step 2: Run, verify they fail**

Run: `cd contracts && forge test --match-test test_h1_ -vv`
Expected: FAIL (current code allows zero-value transfer and bumps recipient).

- [ ] **Step 3: Implement the fix**

`ArcoraDexLP.sol` — only notify on real transfers:
```solidity
function _update(address from, address to, uint256 value) internal override {
    super._update(from, to, value);
    if (from != address(0) && to != address(0) && value > 0) {
        IArcoraDexPool(MINTER).notifyLPTransfer(from, to);
    }
}
```

`ArcoraDexPool.sol` `notifyLPTransfer` — gate the sender, stop bumping the recipient:
```solidity
function notifyLPTransfer(address from, address to) external override {
    if (msg.sender != address(LP)) revert NotLP();
    // Anti-JIT: locked LP cannot move until the sender's own hold elapses.
    // The recipient's clock is intentionally NOT raised — that was the H-1 griefing vector.
    uint256 unlockAt = lastMintAt[from] + MIN_HOLD_SECONDS;
    // slither-disable-next-line timestamp
    if (block.timestamp < unlockAt) revert EarlyTransfer(unlockAt, block.timestamp);
    to; // recipient inherits no lock; their own lastMintAt governs their withdraws
}
```

`IArcoraDexPool.sol` — add the error:
```solidity
error EarlyTransfer(uint256 unlockAt, uint256 nowTs);
```

- [ ] **Step 4: Update the 2 existing hook tests to the new semantics**

`ArcoraDexPool.security.t.sol:290-313` `test_jit_mev_blocked_by_lp_transfer_hook` and `ArcoraDexLP.t.sol:97-115` `test_transfer_hook_calls_notifyLPTransfer`: the JIT case must now assert the transfer **reverts with `EarlyTransfer`** when the sender is still within the hold, and **succeeds without bumping** the recipient when past it. Keep `test_jit_mev_blocked_by_min_hold` (254-276) unchanged — it still passes.

- [ ] **Step 5: Run full suite**

Run: `cd contracts && FOUNDRY_PROFILE=ci forge test`
Expected: `148 passed` (3 tests added, 2 retargeted → count may rise; **0 failed** is the gate).

- [ ] **Step 6: Commit** — `fix(audit): H-1 LP-lock DoS — gate sender, stop recipient-clock bump`

---

## PR-2 — Contracts economics: L-9, L-10, I-1, I-2, I-3 + invariant-suite expansion

This is the highest-risk PR. Land the invariant-suite infrastructure *with* the economic fixes so the suite is never red on a merged commit.

**Files:**
- Modify: `contracts/src/ArcoraDexRegistry.sol` (L-9 cap+remove, I-1 deactivate guard, I-2 reactivate hook)
- Modify: `contracts/src/ArcoraDexPool.sol` (L-10 balance-delta accounting, I-2 cache reset, I-3 fee-sweep gate)
- Modify: `contracts/src/interfaces/IArcoraDexRegistry.sol` (add `removeToken`, `MAX_TOKENS`, errors)
- Create: `contracts/test/mocks/FeeOnTransferERC20.sol`
- Modify: `contracts/test/handlers/PoolHandler.sol` (new fuzz actions)
- Modify: `contracts/test/ArcoraDexPool.invariant.t.sol` (per-LP value-conservation invariant)
- Test: `contracts/test/ArcoraDexRegistry.t.sol`, `contracts/test/ArcoraDexPool.t.sol`

### Task 2.1 — L-10: credit measured balance delta, not requested amount

- [ ] **Step 1: Failing test** — add `FeeOnTransferERC20` (a `MintableERC20` that burns `feeBps` on transfer) and a test that deposits it; assert `reserves[token] == received` (post-fee), not `amount`.

`contracts/test/mocks/FeeOnTransferERC20.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {MintableERC20} from "../../src/testnet/MintableERC20.sol";
contract FeeOnTransferERC20 is MintableERC20 {
    uint16 public feeBps;
    constructor(string memory n, string memory s, uint8 d, uint16 _feeBps)
        MintableERC20(n, s, d) { feeBps = _feeBps; }
    function _update(address from, address to, uint256 v) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (v * feeBps) / 10_000;
            super._update(from, address(0xdead), fee); // burn-as-fee
            v -= fee;
        }
        super._update(from, to, v);
    }
}
```
Test in `ArcoraDexPool.t.sol`: `test_l10_depositCreditsReceivedNotRequested()`.

- [ ] **Step 2: Run, verify fail** — `forge test --match-test test_l10_ -vv` → reserves over-credited by the fee.
- [ ] **Step 3: Implement** — snapshot balance around the inbound transfer (deposit `:421-422`, swap `:533-534`):
```solidity
uint256 balBefore = IERC20(token).balanceOf(address(this));
IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
reserves[token] += received; // was: += amount
// use `received` for downstream NAV/mint math
```
Apply the identical pattern to the swap in-leg (`amountIn` → `receivedIn`). **Don't-break radar:** downstream LP-mint and NAV math must use `received`, not `amount`; `InsufficientLiquidity` checks compare against `reserves` (still consistent).

- [ ] **Step 4: Add the invariant** — in `ArcoraDexPool.invariant.t.sol`, register `FeeOnTransferERC20` as a 4th handler token and keep `invariant_balance_equals_reserves_plus_fees` green under fee-on-transfer.
- [ ] **Step 5:** `FOUNDRY_PROFILE=ci forge test` green.
- [ ] **Step 6: Commit** — `fix(audit): L-10 reserve accounting uses measured balance delta`

### Task 2.2 — L-9: bound the token set + reclaim iteration cost

- [ ] **Step 1: Failing test** — `test_l9_listToken_revertsAtMaxTokens()` and `test_l9_removeToken_dropsFromNavLoop()` (remove requires `reserves[token]==0 && !isActive`).
- [ ] **Step 2:** run → fail (no cap, no remove).
- [ ] **Step 3: Implement** in `ArcoraDexRegistry.sol`:
  - `uint256 public constant MAX_TOKENS = 32;` and `require(tokens.length < MAX_TOKENS)` (revert `MaxTokensReached`) in `listToken`.
  - `function removeToken(address token) external onlyOwner` — require `!_info[token].isActive`; swap-pop from `tokens[]`; delete `_info[token]`; emit `TokenRemoved`. **Precondition the pool checks:** the pool must expose/`require(reserves[token] == 0)` before allowing removal (add a `poolReservesZero` guard or have governance verify; simplest: add `IArcoraDexPool(pool).reserves(token) == 0` check — but Registry has no pool ref. Instead enforce in a Pool-side `removeToken` wrapper, or document that governance must drain first and assert in the removeToken NatSpec + a Pool view check in the test). Choose: add `reserves(token)==0` assertion in the **Pool's** governance flow test and keep Registry.removeToken gated on `!isActive` only.
  - Add `removeToken`, `MAX_TOKENS` to `IArcoraDexRegistry.sol` + errors `MaxTokensReached`, `TokenStillActive`.
- [ ] **Step 4:** green gate. **Don't-break radar:** swap-pop reorders `tokens[]`; the NAV loop is order-independent (summation) so safe; confirm no test asserts a fixed token index.
- [ ] **Step 5: Commit** — `fix(audit): L-9 MAX_TOKENS cap + removeToken to bound NAV loop`

### Task 2.3 — I-1 / I-2: deactivation reserve guard + reactivation cache reset

- [ ] **Step 1: Failing tests** — `test_i1_deactivate_requiresZeroReserves()`; `test_i2_reactivate_afterPriceMove_doesNotTradeStale()` (deactivate, warp + move oracle, reactivate, assert next op uses fresh price not stale cache → expects a forced `syncAcceptedPrice` or auto cache-reset).
- [ ] **Step 2:** run → fail.
- [ ] **Step 3: Implement:**
  - I-1: `deactivateToken` requires the pool's `reserves[token] == 0` (enforce via a Pool-side governance function `deactivateToken(token)` that checks reserves then calls Registry, OR add the assertion in the Timelock batch + test). Recommended: add `ArcoraDexPool.requireDrainedThenDeactivate(token)` `onlyOwner` that asserts `reserves[token]==0` and calls `REGISTRY.deactivateToken(token)`; document that governance must route deactivation through it.
  - I-2: on reactivation, reset the cache. Add `ArcoraDexPool.onReactivate(address token) onlyOwner` that sets `lastValidPrice[token]=0; lastValidPriceAt[token]=0; lastAcceptedPrice[token]=0;` forcing the next read to take the fresh-oracle path (or revert `NoValidPrice` until the keeper pushes), and require it be called in the same Timelock batch as `reactivateToken`. Update NatSpec on both.
- [ ] **Step 4:** add a `PoolHandler` action `governanceDeactivateReactivate(seed)` and a per-LP value-conservation invariant (see Task 2.5) to fuzz the cohort-swing path.
- [ ] **Step 5:** green gate. **Don't-break radar:** zeroing cache can make a token temporarily `NoValidPrice` until the keeper pushes — that's intended; document in runbook.
- [ ] **Step 6: Commit** — `fix(audit): I-1/I-2 deactivate reserve-guard + reactivate cache reset`

### Task 2.4 — I-3: fee-sweep symmetry under pause

- [ ] **Step 1: Failing test** — `test_i3_withdrawProtocolFees_revertsWhenPaused()`.
- [ ] **Step 2:** run → fail (currently fee-sweep works while paused, but user withdrawals are frozen — asymmetric).
- [ ] **Step 3: Implement** — add `whenNotPaused` to `withdrawProtocolFees` (`ArcoraDexPool.sol:631`). Rationale: admin must not extract value while users are frozen out. **Rejected alternative:** auto-expiring guardian pause — re-opening a pool mid-incident is a worse security posture; keep manual `onlyOwner` unpause.
- [ ] **Step 4:** green gate. Update `docs/audit/known-acceptable-risks.md` R5 note: fee-sweep now pause-gated.
- [ ] **Step 5: Commit** — `fix(audit): I-3 gate protocol-fee sweep behind whenNotPaused`

### Task 2.5 — Invariant-suite expansion (the "don't-break" insurance)

- [ ] **Step 1:** add `PoolHandler` actions: `pushPrice(tokenSeed, deltaBps)` (calls `feed.setAnswer` within divergence band), `advanceTime(secondsSeed)` (`vm.warp`), `pauseUnpause(seed)`, `deactivateReactivate(seed)`, `syncPrice(seed)`.
- [ ] **Step 2:** add ghost-variable accounting per actor (cumulative USD in vs LP value out) and a new invariant `invariant_no_positive_pnl_from_atomic_deposit_oraclemove_withdraw()` and `invariant_per_lp_value_conservation()`.
- [ ] **Step 3:** run the expanded invariants against the **fixed** code (post 2.1–2.4) → must be green. If red, a fix is incomplete — return to it.
- [ ] **Step 4: Commit** — `test(contracts): expand invariant suite (price-mutating, time, governance actions + value-conservation)`
- [ ] **Final PR-2 gate:** `FOUNDRY_PROFILE=ci forge test` → 0 failed.

---

## PR-3 — Oracle hardening (code) + oracle docs/cleanup

**Files:**
- Modify: `contracts/src/testnet/MockChainlinkFeedV2.sol` (H-2 on-chain bounds)
- Modify: `contracts/src/interfaces/IChainlinkAggregator.sol` (I-4 NatSpec)
- Modify: `contracts/src/oracle/OracleAggregator.sol` (I-5 NatSpec / optional symmetric cap)
- Modify: `contracts/src/ArcoraDexPool.sol:689-714` (I-6 NatSpec), `contracts/src/interfaces/IArcoraDexPool.sol` (G-5 remove unused errors)
- Modify: `contracts/src/ArcoraDexRegistry.sol` (I-7 setter NatSpec + optional decimals assert)
- Test: `contracts/test/MockChainlinkFeedV2.t.sol`

### Task 3.1 — H-2 (on-chain part): bounded `setAnswer`

> Deployed live in PR-9 (current feeds lack bounds; new bounded feeds are deployed during rotation). This task lands the code + tests.

- [ ] **Step 1: Failing tests** in `MockChainlinkFeedV2.t.sol`: `test_h2_setAnswer_revertsBelowMinBand`, `_revertsAboveMaxBand`, `_revertsOnMaxJump`, `_revertsBeforeMinInterval`, and `test_h2_setAnswer_acceptsInBandWithinJump`.
- [ ] **Step 2:** run → fail (constructor signature + guards don't exist).
- [ ] **Step 3: Implement** — add immutables + guards (keep the existing monotonic-roundId behaviour the prior audit pinned):
```solidity
int256 public immutable minAnswer;
int256 public immutable maxAnswer;
uint32 public immutable maxJumpBps;        // 0 = disabled
uint32 public immutable minUpdateSeconds;  // 0 = disabled
error AnswerOutOfBounds(int256 a, int256 lo, int256 hi);
error MaxJumpExceeded(uint256 diffBps, uint32 cap);
error MinIntervalNotMet(uint256 nowTs, uint256 nextOkTs);

function setAnswer(int256 newAnswer) external {
    if (msg.sender != writer) revert NotWriter();
    if (newAnswer <= 0) revert AnswerNotPositive();
    if (newAnswer < minAnswer || newAnswer > maxAnswer)
        revert AnswerOutOfBounds(newAnswer, minAnswer, maxAnswer);
    if (latestAnswer != 0) {
        uint256 prev = uint256(latestAnswer);
        uint256 diff = newAnswer > latestAnswer
            ? uint256(newAnswer - latestAnswer) : uint256(latestAnswer - newAnswer);
        if (maxJumpBps != 0 && diff * 10_000 > prev * maxJumpBps)
            revert MaxJumpExceeded(diff * 10_000 / prev, maxJumpBps);
        if (minUpdateSeconds != 0 && block.timestamp < latestUpdatedAt + minUpdateSeconds)
            revert MinIntervalNotMet(block.timestamp, latestUpdatedAt + minUpdateSeconds);
    }
    _roundId += 1;
    latestAnswer = newAnswer;
    latestUpdatedAt = block.timestamp;
    emit AnswerUpdated(newAnswer, block.timestamp);
}
```
Extend the constructor to accept `(minAnswer, maxAnswer, maxJumpBps, minUpdateSeconds)`. **Don't-break radar:** every existing `new MockChainlinkFeedV2(...)` in tests + scripts must pass the new args — update all call sites (test setups, `DeployOraclesP3*.s.sol`, `MigrateFeedsToV2.s.sol`). Use permissive defaults in existing tests (`minUpdateSeconds=0`, wide band) so monotonic-roundId tests still pass; use tight per-token bounds in deploy scripts.

- [ ] **Step 4:** green gate.
- [ ] **Step 5: Commit** — `fix(audit): H-2 on-chain sanity band + max-jump + min-interval on MockChainlinkFeedV2`

### Task 3.2 — I-4/I-5/I-6/I-7 NatSpec + G-5 cleanup (no behaviour change)

- [ ] I-4: document the `roundId == 0` degraded-mode convention on `IChainlinkAggregator.latestRoundData` and on `OracleAggregator` single-source branch (`:77-85`).
- [ ] I-5: document that the divergence cap is measured against `min(pAns,sAns)` (asymmetric, slightly wider than vs mid); leave math as-is (numerically negligible at 50–200 bps) — note the option to switch to `mid` if symmetric semantics ever required.
- [ ] I-6: correct `syncAcceptedPrice` NatSpec (`:689-692`) — the cache (`lastValidPriceAt`) is reset only on the fresh branch; the stale branch re-baselines `lastAcceptedPrice` only.
- [ ] I-7: add NatSpec to `setOracle`/`setDeviation`/`setMaxStaleSeconds`; add `require(newOracle.decimals() <= 18)` in `setOracle` (defense-in-depth; covered by runtime normalization but cheap). Add `test_i7_setOracle_rejectsOver18Decimals()`.
- [ ] G-5: remove `InvalidOracleRound` / `InvalidOracleTimestamp` from `IArcoraDexPool` (grep-confirmed unused in `src/`). **Coordinate with PR-6** (SDK still decodes them).
- [ ] **Gate + Commit** — `docs+fix(audit): I-4/I-5/I-6/I-7 oracle NatSpec, decimals guard, G-5 remove dead errors`
- [ ] Reconcile `docs/audit/invariants.md` INV-7 (still describes the old hardcoded-roundId behaviour) → update to monotonic-roundId.

---

## PR-4 — Gas: thread `TokenInfo`, drop redundant calls, `unchecked` loops

**Files:** `contracts/src/ArcoraDexPool.sol` (`_readOracle`, `_readUsdPrice1e18Mut`, `_readUsdPrice1e18WithGuard`, `_readAndGuardPrice`, both NAV loops), `contracts/src/interfaces/IArcoraDexRegistry.sol` (optionally cache decimals in `TokenInfo`).

> Runs after PR-2/PR-3 so it refactors the final price-stack shape. **NAV must be bit-identical before/after** — this is a pure optimization.

- [ ] **Step 1: Pin a golden NAV test** — `test_g1_nav_unchanged_after_refactor()` snapshotting `totalReservesUSD()` and a deposit/withdraw/swap quote for a fixed 3-token fixture; record exact values BEFORE refactor.
- [ ] **Step 2: G-1** — thread one `TokenInfo memory info` from `_readAndGuardPrice`/NAV-loop down through `_readUsdPrice1e18Mut(info,...)`, `_readUsdPrice1e18WithGuard(info,...)`, `_readOracle(info,...)`; remove the redundant `REGISTRY.tokenInfo()` reads (was 2–3× per token).
- [ ] **Step 3: G-2** — in the NAV loops, branch on `info.isActive` locally instead of a separate `REGISTRY.isActive()` call. Preserve "skip in loop, revert `TokenNotActive` in price path".
- [ ] **Step 4: G-3** — cache oracle `decimals` in `TokenInfo` (set at `listToken`/`setOracle`) and read it from the struct; keep a runtime `decimals()` fallback only if `setOracle` can't guarantee parity. (Pairs with I-7's `decimals()<=18` assert.)
- [ ] **Step 5: G-4** — wrap both NAV-loop increments: `for (uint256 i; i < n;) { ...; unchecked { ++i; } }`.
- [ ] **Step 6:** run golden test + full CI suite → NAV identical, 0 failed. Optionally capture `forge test --gas-report` delta in the commit body.
- [ ] **Step 7: Commit** — `perf(audit): G-1/G-2/G-3/G-4 collapse price-stack reads + unchecked NAV loops`

---

## PR-5 — Scripts: neutralize retired P3, fix executor for future deploys, key-separation deploy path

**Files:** `contracts/script/P3BatchBuilder.sol`, `P3GovernanceActions.s.sol`, `ExecuteP3Batch.s.sol`, `DeployGovernanceP2.s.sol:160-164`, `MigrateFeedsToV2.s.sol`, `MigrateSecondaryWriters.s.sol`, `DeployOraclesP3.s.sol`.

- [ ] **L-7:** neutralize the retired P3 batch (still runnable with `SALT=bytes32(0)`, would regress Registry to V1 aggregators). Chosen approach = **hard guard, keep for history**: add to the top of `P3GovernanceActions.run()` and `ExecuteP3Batch.run()`:
```solidity
revert("P3 retired — superseded by P3.5; see docs/audits/2026-05-31-wide-audit.md L-7");
```
Plus a chainid-guard comment. (Deleting also acceptable; guard preserves the deployment trail the file documents.) Add `test_l7_retiredP3_reverts()` if these scripts are unit-testable, else a comment-verified manual step.
- [ ] **L-8 (script):** in `DeployGovernanceP2.s.sol:160-164`, stop granting `EXECUTOR_ROLE` to `address(0)`; grant it to the Governance Safe (and optionally a dedicated executor). This fixes **future** deploys; the live Timelock is fixed in PR-9. Update governance tests (`SafeSigHelpers`-driven) that assume open execution.
- [ ] **H-2 (key-separation scripts):** parameterize the secondary-feed writer as a **separate** `KEEPER_SECONDARY` address. In `MigrateSecondaryWriters.s.sol` use `KEEPER_SECONDARY` (not the primary keeper) for `setWriter`; in `DeployOraclesP3.s.sol`/`MigrateFeedsToV2.s.sol` wire bounded-feed constructor args (from Task 3.1) with per-token bands. These scripts are **executed in PR-9**.
- [ ] **Gate:** `FOUNDRY_PROFILE=ci forge test` green. **Commit** — `fix(audit): L-7 retire P3 scripts, L-8 close executor (future deploys), H-2 separate secondary writer in scripts`

---

## PR-6 — SDK: typed errors, ABI parity, safe defaults, hooks/subscriptions

**Files:** `packages/sdk/src/actions/{swap,deposit,withdraw,quoteSwap,quoteDeposit,quoteWithdraw}.ts`, `errors.ts`, `abi/{pool,registry}.ts`, `types.ts`, `actions/getTokens.ts`, `allowance.ts`, `slippage/index.ts`, `addresses.ts`, `react/use*.ts`, `subscriptions/*.ts`. Test dir: `packages/sdk/test/{unit,integration,react}`.

- [ ] **L-1:** wrap each `quote*` action's `readContract` in try/catch routed through `parseContractError`; and in `swap/deposit/withdraw` move the quote call inside the wrapped body. Add `SameToken`, `ZeroAmount` cases to the `parseContractError` switch (`errors.ts:137-181`). Test: `test/unit/errors.test.ts` cases + an integration test forcing a quote revert maps to a typed error.
- [ ] **G-5 (sdk):** remove `InvalidOracleRound` / `InvalidOracleTimestamp` from `abi/pool.ts:30-31` and their `errors.ts:172-175` cases (contract no longer declares them after PR-3). Update `test/unit/errors.test.ts` (drop the synthetic cases).
- [ ] **I-8:** add the missing `uint32 maxStaleSeconds` 5th field to the Registry `TokenInfo` struct in `abi/registry.ts:3`, add `maxStaleSeconds` to `types.ts` `TokenInfo`, and capture it in `getTokens.ts` decode. Test: round-trip `maxStaleSeconds` from a mock.
- [ ] **I-9:** keep `maxUint256` default but (a) document the unlimited-approval default loudly in `ensureAllowance` NatSpec + README, and (b) **address-trust:** verify `client.addresses.pool` against the on-chain `LP.MINTER()` / a canonical check before approving (reject if mismatch) to close the open coverage item. Test: `ensureAllowance` rejects when spender ≠ canonical pool.
- [ ] **I-10:** in `minOut`, treat `slippageBps >= 10_000` as a caller error — `throw new RangeError("slippageBps must be < 10000")` instead of silently returning `0n`. Update `test/unit/slippage.test.ts` (the permissive test becomes an expect-throws).
- [ ] **Open coverage — hooks:** in `react/useSwap/useDeposit/useWithdraw/useQuote*`, ensure surfaced errors are passed through `parseContractError` so `error` is a typed `ArcoraDexError`. Add a react test.
- [ ] **Open coverage — subscriptions:** in `subscribeSwaps.ts`, dedupe by `(txHash, logIndex)` and handle `removed` logs (reorg); in both subscriptions, surface errors to an optional `onError` callback instead of silently swallowing. Add integration tests.
- [ ] **Gate:** `cd packages/sdk && pnpm test` green. **Commit** — `fix(audit): SDK L-1/I-8/I-9/I-10/G-5 + hooks typed errors + subscription reorg dedupe`

---

## PR-7 — App / dApp: faucet integrity + chain gating + quote consistency

**Files:** `app/app/api/faucet/route.ts`, `app/lib/faucet-rate-limit.ts`, `app/components/swap/{SwapCard,ConfirmSwapModal}.tsx`, `app/components/liquidity/{DepositTab,WithdrawTab}.tsx`, `app/components/wallet/FaucetButton.tsx`. Tests: `app/lib/__tests__/`, new route test.

- [ ] **M-2:** record the cooldown **before** broadcasting (right after rate-limit + mutex pass), then in the catch roll it back only if `Object.keys(txHashes).length === 0`. Test (new `route.test.ts` with a mocked walletClient that throws on token #4): a partial-failure leaves a cooldown timestamp → immediate re-POST is rate-limited.
- [ ] **M-3:** introduce a shared `CooldownStore` backed by Upstash Redis (`@upstash/redis`) using `SET key val NX PX <ttl>` for atomic reserve-or-fail, keyed by **both** address and IP; add a global hourly mint budget key. Keep `MemoryCooldownStore` as the dev/test fallback (select by `process.env.UPSTASH_REDIS_REST_URL` presence). Add `@upstash/redis` to `app/package.json`; document `UPSTASH_REDIS_REST_URL` / `UPSTASH_REDIS_REST_TOKEN` in `.env.example`. The `inFlightAddrs/Ips` Sets become Redis `SET NX` reservations too. Tests against an in-memory Redis mock.
- [ ] **L-11:** fail **closed** — if `NEXT_PUBLIC_APP_URL` is unset in production (`process.env.VERCEL_ENV === 'production'` or `NODE_ENV==='production'`), reject the request (or assert at build/startup). Keep dev permissive. Add the var to `.env.example`. Test: missing origin allowlist in prod → 403.
- [ ] **I-12:** return a generic client message (`"Faucet mint failed, please retry later."`); log the raw viem/RPC error server-side only. Update `FaucetButton.tsx` to show the generic message. (Pairs with M-2 so the error path is not also a free-retry signal.)
- [ ] **L-5:** add `useChainId()` gating to `SwapCard`/`DepositTab`/`WithdrawTab`: `ctaDisabled = ...|| chainId !== arcTestnet.id`, and render a "Switch to Arc Testnet" CTA (`useSwitchChain`) mirroring `ConnectButton.tsx:13`. Test the disabled/switch state.
- [ ] **L-6:** make the displayed "Minimum received" use the **same** `minAmountOut` the SDK will submit — have the SDK return/accept the exact `minOut` (PR-6 surfaces it) and pass it into `ConfirmSwapModal` instead of recomputing from a stale quote, or freeze a single quote for both display and submit within the confirm flow.
- [ ] **Gate:** `cd app && pnpm test` green. **Commit** — `fix(audit): faucet M-2/M-3/L-11/I-12 + L-5 chain gating + L-6 minOut display parity`

---

## PR-8 — Ops / keeper: liveness hardening, key split, guard monitor

**Files:** `ops/keepalive/multi-feed-push.mjs`, `ops/keepalive/guard-record.mjs`, `ops/keepalive/arcoradex-feeds.service`, `arcoradex-guard-record.service`, `ops/keepalive/fetch-keeper-secret.sh`, new `ops/keepalive/guard-monitor.mjs`. (No keeper tests exist today — add a minimal `ops/keepalive/test/` with node:test for the pure helpers.)

- [ ] **L-3:** wrap both CoinGecko `fetch` calls (`:88`, `:104`) in an `AbortController` with a 10–15s timeout; on timeout, log + skip that batch (existing per-batch error handling already degrades gracefully). Add `TimeoutStartSec=120` to both `.service` units.
- [ ] **L-4:** on every `writeContract` (feed push `:151-157,:178-179`; `guard-record.mjs:118-122`): set an explicit `maxFeePerGas`/`maxPriorityFeePerGas` ceiling, manage `nonce` explicitly (fetch pending nonce once per run, increment locally), and pass a `timeout` to `waitForTransactionReceipt`. Add a fallback RPC (array of transports / retry). Add a startup keeper-balance check that warns/aborts below a threshold.
- [ ] **L-2:** give the FX legs (EURC/TRYC/BRLC) a real reference-drift guard — fetch an independent second FX source and reject if the two disagree beyond a small bps tolerance; tighten each FX `band` to a few-hundred-bps window around the trusted reference; set `maxPegDriftBps` for FX too. (On-chain divergence becomes meaningful only after the writer split below.)
- [ ] **H-2 key split:** load `KEEPER_PRIMARY_KEY` and `KEEPER_SECONDARY_KEY`; build two wallet clients; push primary feeds with the primary wallet and secondary feeds with the secondary wallet (the `[["primary",f.feed],["secondary",f.secondary]]` loop selects the wallet by role). Update `fetch-keeper-secret.sh` to pull both keys from Vault (separate paths/AppRoles). (On-chain `setWriter(keeper_secondary)` happens in PR-9.)
- [ ] **I-11:** source `GUARD`/`REGISTRY` in `guard-record.mjs` from env (matching `multi-feed-push.mjs`) instead of hardcoding `:29,:35`; document the env vars.
- [ ] **Open coverage — guard pipeline:** add `ops/keepalive/guard-monitor.mjs` that subscribes to `CumulativeDeviationGuard.CircuitBreakerTripped`, **re-validates** the price against an independent feed before paging, and (manual-in-the-loop for now) emits an alert/Safe-tx proposal to the Pause-Guardian; treat `record` events as untrusted hints (per the contract's trust-boundary NatSpec). Guard against permissionless event spam (debounce + independent re-validation).
- [ ] **Gate:** run the new `node --test` helpers green; dry-run both keeper scripts against a local fork. **Commit** — `fix(audit): keeper L-2/L-3/L-4/I-11 + primary/secondary key split + guard monitor`

---

## PR-9 — Governance rotation (LIVE, irreversible) — runbook

> Execute only after PR-1…PR-8 are merged, the new key custody is provisioned, and a dry-run on a local fork of testnet `5042002` has passed. This closes **M-1**, the **live L-8**, and the **live half of H-2** (separate on-chain writers + bounded feeds). Two 48h Timelock waits → ~6 calendar days.

**Current live graph (from broadcast artifacts):** Pool `0x1ce1Ef94…331bc` & Registry `0x9914436E…05aB` owned by Timelock `0x36444f65…6E83` (executor = `address(0)`, open); Gov Safe `0x715f…e624` (3/5, **public-mnemonic keys**) is the Timelock's sole proposer and direct owner of the 7 aggregators, 7 secondary feeds, and the deviation guard; Pause-Guardian Safe (2/3, public-mnemonic). **All current keys must be treated as compromised.**

**Phase 0 — key custody (off-chain):**
- [ ] Generate 5 new Gov-Safe signer keys + 3 new Pause-Guardian keys (hardware wallets / encrypted keystore; not the Foundry mnemonic, not env files).
- [ ] Generate `keeper_primary` + `keeper_secondary` keys in **separate** Vault AppRoles (distinct custody).
- [ ] Fund the new deployer + signers with ARC gas.

**Phase 1 — deploy new governance (direct):**
- [ ] Deploy new Gov Safe (3/5, real keys), new Pause-Guardian Safe (2/3), new TimelockController (48h, **proposer = new Gov Safe, executor = new Gov Safe** — not `address(0)`), via the PR-5-fixed `DeployGovernanceP2.s.sol`.

**Phase 2 — hand off Pool/Registry ownership (48h Timelock-gated, uses OLD keys one last time):**
- [ ] Using the **old** Gov Safe, schedule `Pool.transferOwnership(newTimelock)` and `Registry.transferOwnership(newTimelock)` on the **old** Timelock. ⚠️ This is the final use of the public keys; scheduling is irreversible.
- [ ] **WAIT 48h.**
- [ ] Execute the transfers; on the new Timelock, accept ownership. Verify `Pool.owner()==newTimelock` & `Registry.owner()==newTimelock`.

**Phase 3 — rotate oracle-layer ownership + deploy bounded feeds (direct):**
- [ ] Deploy the **bounded** `MockChainlinkFeedV2` feeds (PR-3 constructor args, per-token bands) for primary + secondary, or re-point via `MigrateFeedsToV2`/`DeployOraclesP3` (PR-5 scripts). Owner = new Gov Safe.
- [ ] Transfer the 7 V2 aggregators + deviation guard ownership → new Gov Safe (Ownable2Step accept).

**Phase 4 — separate writers (H-2 live, direct):**
- [ ] New Gov Safe calls `setWriter(keeper_primary)` on all 7 **primary** feeds and `setWriter(keeper_secondary)` on all 7 **secondary** feeds (PR-5 `MigrateSecondaryWriters` with `KEEPER_SECONDARY`). Verify each.
- [ ] Deploy the PR-8 keeper with both keys; confirm independent primary/secondary pushes; confirm the aggregator divergence check now carries real signal (corrupt one source on a fork → cache fallback fires).

**Phase 5 — Registry oracle pointers (if re-pointing, 48h-gated):**
- [ ] If feeds were redeployed, schedule the `Registry.setOracle` batch on the new Timelock (P3.5-style non-zero salt), **WAIT 48h**, execute.

**Phase 6 — close out:**
- [ ] Mark the old Gov Safe `0x715f…e624` + old Pause-Guardian Safe as **poisoned/never-reuse** in the runbook; document the public-mnemonic keys as compromised.
- [ ] Update `docs/audit/known-acceptable-risks.md` R5/R6: governance now uses real independent keys; oracle now has separate primary/secondary writers + on-chain bounds.
- [ ] Write a new `docs/rollouts/2026-XX-XX-governance-rotation.md` recording the new addresses.
- [ ] Final verification: `FOUNDRY_PROFILE=ci forge test` green; keeper liveness confirmed; M-1 / L-8 / H-2 closed.

---

## Self-review (spec coverage)

- **H-1** → PR-1. **H-2** → PR-3 (bounds) + PR-5 (scripts) + PR-8 (key split) + PR-9 (live writers). **M-1** → PR-9 (+PR-5 script fix). **M-2/M-3** → PR-7. **L-1** → PR-6. **L-2/L-3/L-4** → PR-8. **L-5/L-6/L-11** → PR-7. **L-7/L-8** → PR-5 (code) + PR-9 (live executor). **L-9/L-10** → PR-2. **I-1/I-2/I-3** → PR-2. **I-4/I-5/I-6/I-7** → PR-3. **I-8/I-9/I-10** → PR-6. **I-11** → PR-8. **I-12** → PR-7. **G-1/G-2/G-3/G-4** → PR-4. **G-5** → PR-3 (contract) + PR-6 (SDK).
- **Open-coverage items:** invariant-suite weakness → PR-2; MintableERC20 mint-authority (faucet key = token owner) → verify in PR-7 and document; SDK hooks/subscriptions/addresses-trust → PR-6; guard-record hardening + monitor pipeline → PR-8; migration state-carryover (cache reset on feed swap) → PR-2 (I-2) + PR-9 Phase 3.
- **Doc drift:** invariants.md INV-7 → PR-3; SDK dead errors → PR-6; known-acceptable-risks R5/R6 → PR-2/PR-9.

**Gaps intentionally deferred to mainnet (documented, not coded here):** genuinely-independent real Chainlink/Pyth primary feeds (testnet keeps bounded mocks); fee-collector multisig separation (R7); Immunefi program (R8). These are recorded in `docs/audit/p5-tracking.md`, not in scope for the public testnet.
