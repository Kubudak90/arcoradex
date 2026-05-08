# Arcora v0.7 — Shared-Vault Stablecoin Pool (drop-in package)

Self-contained snapshot of the v0.7 multi-stablecoin pool refactor as of
**2026-05-01 ~02:30 TRT**. Lifted from `~/arc-fx-gateway` working tree at
HEAD `e66cbf4`. The original repo is intact — this is a parallel copy you
can pick up in a separate session without disturbing app/SDK/etc.

## What's in here

```
contracts/
├── foundry.toml              # solc 0.8.26, optimizer 200 runs, evm cancun
├── remappings.txt
├── src/
│   ├── ArcFXGateway.sol      # v0.7 — token-agnostic, routes through StablePool
│   ├── interfaces/
│   │   └── IChainlinkAggregator.sol
│   ├── libraries/
│   │   └── PriceGuard.sol    # legacy — gateway no longer uses; pool has its own
│   ├── pool/
│   │   ├── IStablePool.sol
│   │   └── StablePool.sol    # singleton shared-vault, per-token PriceGuard, Ownable2Step + Pausable
│   ├── registry/
│   │   ├── IStablecoinRegistry.sol
│   │   └── StablecoinRegistry.sol  # Ownable2Step
│   └── testnet/
│       ├── MintableERC20.sol     # NEW — production-deployable mock
│       └── MockChainlinkFeed.sol # carry-over from v0.6
└── test/
    ├── ArcFXGateway.fuzz.t.sol
    ├── ArcFXGateway.invariant.t.sol
    ├── ArcFXGateway.t.sol
    ├── StablePool.t.sol           # NEW — 27 tests
    ├── StablecoinRegistry.t.sol   # NEW — 14 tests
    ├── handlers/
    │   └── GatewayHandler.sol
    └── helpers/
        └── MockERC20.sol          # carry-over
docs/
├── 2026-04-29-plan-3-multi-stablecoin.md  # spec (pair-based version; rev2 was reverted in source repo)
└── 2026-04-30-multi-stablecoin-pool.md    # full implementation plan, all 16 tasks
```

## Architecture (the design we actually built)

**Shared vault, no pairs.** One contract holds reserves for all active
stables. Swap routes through per-token USD oracles:

```
swap(in, out, amountIn):
  usdValueIn = amountIn * priceIn / 10^decimalsIn
  usdValueNet = usdValueIn * (BPS - swapFeeBps) / BPS
  amountOut   = usdValueNet * 10^decimalsOut / priceOut
  require reserves[out] >= gross
  reserves[in]  += amountIn
  reserves[out] -= gross
  protocolFeesAccrued[out] += fee
```

Per-token PriceGuard guards against bad oracle prints (50bps default,
150bps for FX-pegged stables like EURC/TRYC/BRLC). Stale-oracle revert
at 1 hour. Pausable. Ownable2Step on all three contracts.

## What's done (Tasks 1–11)

| # | Task | Tests | Notes |
|---|---|---|---|
| 1 | `IStablecoinRegistry` interface | — | |
| 2 | `StablecoinRegistry` impl + Ownable2Step tests | 7 | |
| 3 | Registry mutation tests (deactivate, setOracle, setDeviation, ordering) | +7 | total 14 |
| 4 | `IStablePool` interface | — | |
| 5 | `StablePool` deposit/withdraw/pause skeleton | 10 | |
| 6 | `quote()` cross-decimal oracle math | +7 | USDC↔EURC, USDC↔DAI (6↔18) |
| 7 | `swap()` state mutation, fee accrual, recipient routing | +5 | |
| 8 | Per-token PriceGuard (last-accepted price) | +4 | total 27 pool tests |
| 9 | `MintableERC20` (production-deployable mock) | — | |
| 10 | `ArcFXGateway` v0.7 refactor | — | drops USDC/EURC immutables; routes through pool |
| 11 | Migrate gateway test suite to v0.7 setup | 49 base + 1 fuzz + 2 invariants | gateway suite green |

**Build status:** run `forge test --skip "script/*"` from `contracts/`
after checkout; the suite covers registry, pool, gateway, fuzz, and
invariants.
Old `script/Deploy.s.sol` and `script/DeployAll.s.sol` were NOT migrated
and don't compile against the v0.7 gateway constructor — they will be
superseded by Task 13's `DeployV07.s.sol`. Unrelated `script/` changes
land in Task 13.

## What's left (Tasks 12–16)

12. **Cross-stable e2e gateway tests** — add USDT, PYUSD, DAI, TRYC, BRLC mocks and 5 new pay-flow tests.
13. **`script/DeployV07.s.sol`** — single-shot deploy: registry + pool + gateway + 7 mocks + 7 feeds, lists tokens, seeds reserves. Also delete or migrate the old `Deploy.s.sol` / `DeployAll.s.sol`.
14. **Live testnet deploy + 7-path smoke** — broadcast to Arc testnet, verify `cast code <addr>` for each contract (foundry-broadcast-lies trap), run 7 pay flows (same-token, USDC↔EURC bidirectional, USDT→USDC, PYUSD→DAI, DAI→TRYC, BRLC→EURC), record tx hashes in a rollout note.
15. **VPS keeper extension** — `ops/keepalive/multi-feed-push.ts` pulls 6 prices from CoinGecko (USDC hardcoded peg=1), pushes to mock feeds with sanity-band gating. Update systemd unit on VPS.
16. **PR + memory update** — full `forge test`, gas snapshot, push branch, open PR into `plan-1-protocol`, update `~/.claude/projects/.../memory/roadmap_open_items.md`.

Full task texts with code blocks, file paths, and TDD steps are in
`docs/2026-04-30-multi-stablecoin-pool.md`.

## Audit hardening notes

The old `_estimateAmountIn` iterator plateau has been replaced by a
bounded doubling + bisection search. Fuzz and invariant tests no longer
silently accept unexpected `pay()` reverts, so estimator liveness
regressions should fail the suite.

PriceGuard baseline drift is handled by `StablePool.syncAcceptedPrice`.
The keeper updates each mock feed and then calls `syncAcceptedPrice(token)`
on the pool, so tokens that go quiet between swaps do not accumulate an
unobserved oracle delta that later bricks the first swap.

Gateway protocol fees are capped at 100 bps at construction/deploy time,
and registry token listings verify `IERC20Metadata(token).decimals()`
against the supplied registry decimal.

## Pick-up checklist for next session

1. Drop the `contracts/` directory into a fresh `foundry-rs/forge`-init'd
   repo, or merge it onto a checkout of `arc-fx-gateway` at HEAD `e66cbf4`.
2. Run `forge install` for any missing deps (`openzeppelin-contracts`,
   `forge-std`, `chainlink-brownie-contracts`).
3. Run `forge test --skip "script/*"` — must pass.
4. Read `docs/2026-04-30-multi-stablecoin-pool.md` for the full plan.
5. Continue from the latest rollout note.

## Source commits (in `arc-fx-gateway` HEAD `e66cbf4` lineage)

```
e66cbf4 test(contracts): migrate gateway tests to v0.7 setup (registry + StablePool)
6a688a2 feat(contracts): refactor ArcFXGateway to v0.7 (token-agnostic, pool-routed)
63a3ecc feat(contracts): add MintableERC20 for testnet stable mocks
c54c5ca feat(contracts): per-token PriceGuard with last-accepted price tracking
a26fa56 feat(contracts): StablePool swap + fee accrual + recipient routing
de50252 feat(contracts): StablePool quote with cross-decimal oracle math
f33bd5e feat(contracts): StablePool deposit/withdraw/pause skeleton
5c1d794 feat(contracts): add IStablePool interface
77160b5 test(contracts): cover deactivate/setOracle/setDeviation + array order
f041b40 feat(contracts): add StablecoinRegistry with Ownable2Step
8d3a583 feat(contracts): add IStablecoinRegistry interface for v0.7 multi-stable pool
```

Branch: `plan-1-protocol` in `~/arc-fx-gateway`. The new files were
landed directly on this branch since concurrent tooling kept the
working tree on it.

## Spec note

The spec doc shipped here (`docs/2026-04-29-plan-3-multi-stablecoin.md`)
is the **pair-based original** — a rev2 update was written to the
shared-vault design we actually built, then reverted in the source repo
between Tasks 7 and 11. The plan doc is what we executed against and
matches the code. If you need the rev2 shared-vault spec, it's
recoverable from `git show f80a888:docs/superpowers/specs/2026-04-29-plan-3-multi-stablecoin.md`.
