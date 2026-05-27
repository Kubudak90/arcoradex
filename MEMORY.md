# ArcoraDEX — Project Memory

Quick-reference for Claude sessions. Keep entries terse; link to rollout docs for detail.

## Network

- **Arc testnet** — chainId `5042002`, RPC `https://rpc.testnet.arc.network`, explorer `https://testnet.arcscan.app`
- **Native gas token:** USDC (Arc testnet)

## Key EOAs

- **Deployer EOA:** `0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b`
- **Governance Safe (3/5):** `0x715f669D79Cc72d6685F8724c0B86f7B53d7e624`
- **Pause Guardian Safe (2/3):** `0x39500e45935f36CfcEb826590aaE97226Ac6640D`
- **TimelockController (48 h):** `0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83`

See `memory/arcoradex_role_eoas.md` for full address table.

## Live contracts (V3, current)

| Contract | Address |
|---|---|
| ArcoraDexRegistry V3 | `0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB` |
| ArcoraDexPool V3 | `0x1ce1ef94e7ebe70727bd69003d61a3f0c9a331bc` |
| ArcoraDexLP V3 | `0x17B47173C457069E53B3B75Ef42773041B79523e` |

Deployed in [Phase 2 — Governance Migration (2026-05-14)](docs/rollouts/2026-05-14-phase2-governance.md).

## Deployment history

- [v0.7 deploy (2026-05-01)](docs/rollouts/2026-05-01-v0.7-deploy.md) — legacy arc-fx-gateway; archived on `legacy/v0.7-arc-fx-gateway` branch.
- [ArcoraDEX initial deploy (2026-05-06)](docs/rollouts/2026-05-06-arcoradex-deploy.md) — v1.0-testnet. Pool `0x3051d24D…` now paused/abandoned.
- [Key separation cutover (2026-05-10)](docs/rollouts/2026-05-10-key-separation-cutover.md) — tokens + feeds redeployed under separated EOA keys; same token addresses in use today.
- [Phase 1 — Testnet Redeploy (2026-05-14)](docs/rollouts/2026-05-14-phase1-deploy.md) — added `maxStaleSeconds` to Registry, `lastValidPrice` cache to Pool; fresh V2 deploy.
- [Phase 2 — Governance Migration (2026-05-14)](docs/rollouts/2026-05-14-phase2-governance.md) — Timelock + 3/5 Gov Safe + 2/3 Pause Guardian; V3 pool/registry/LP. Deployer EOA no longer direct owner.
- [Phase 3 — Oracle Hardening (2026-05-17/18)](docs/rollouts/2026-05-14-phase3-oracle.md) — dual-source `OracleAggregator` (V1), `CumulativeDeviationGuard`, tightened TRYC/BRLC caps; registry swapped via Timelock.
- [Phase 3 Operationalization (2026-05-18)](docs/rollouts/2026-05-18-phase3-operationalization.md)
- [Phase 3.5 OracleAggregator V2 (2026-05-20)](docs/rollouts/2026-05-20-phase3_5-oracle-v2.md) — V2 redeploy: per-source staleness, degraded-mode signal, monotonic roundId. Registry pointers swapped via Timelock batch `0xe2e130fb…58354c`, executed 2026-05-22 (tx `0x6b65230972baab17f256b9fd62643d7af370617ec8b6077fa30d7e852045d314`, block 43528310).

## V3 Pool + P3 oracle layer

- 7 stables: USDC, USDT, PYUSD, DAI, EURC, TRYC, BRLC
- Per-token `OracleAggregator` (V2 as of 2026-05-22) with dual Chainlink feeds + per-source staleness
- Registry `maxOracleDeviationBps`: 50 (USD pegs) / 150 (EURC) / 200 (TRYC, BRLC)
- `CumulativeDeviationGuard` at `0x035447f8d97A23fFfC32aa8bFb8ffDbC7B94E608` (event-only in P3)
- Pool swapFeeBps: 5 (0.05%), protocolFeeShareBps: 2500 (25%)

## Active audit findings (open)

See `docs/audit/p5-tracking.md` for P5 findings. C-1/C-2/C-5/C-14/G-3/G-7 closed by Phase 3.5.

## Conventions

- All oracle changes require 48 h Timelock + Gov Safe scheduling.
- Emergency pause bypasses Timelock (Pause Guardian direct).
- Aggregator redeploys: use `DeployOraclesP3_5.s.sol` pattern + non-zero salt in `P3_5BatchBuilder`.
