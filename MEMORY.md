# ArcoraDEX — Project Memory

Quick-reference for Claude sessions. Keep entries terse; link to rollout docs for detail.

## Network

- **Arc testnet** — chainId `5042002`, RPC `https://rpc.testnet.arc.network`, explorer `https://testnet.arcscan.app`
- **Native gas token:** USDC (Arc testnet)

## Key EOAs

- **Deployer EOA:** `0xC49303Bda108dE3FFDBDEC069B795b645168D7e6`
- **Governance Safe (3/5):** `0x396145BAB316d84F958368d93ec8984559f0261B`
- **Pause Guardian Safe (2/3):** `0x1098e88b8b243451109D7eA7690f9e2ca7b18280`
- **TimelockController:** `0xEb2E77144F5BcB854ED75C687988c4F19100e5D7` (delay 0, raising to 48h)

See `memory/arcoradex_role_eoas.md` for full address table.

## Live contracts (V3, current)

| Contract | Address |
|---|---|
| ArcoraDexRegistry V3 | `0x372f83a1432Aa43b72eDCE083DC8352d9Bfb47f1` |
| ArcoraDexPool V3 | `0x214825E3e24a07cd58e48267e492320dAccCe2f6` |
| ArcoraDexLP V3 | `0xc07e979B5Ee023Ad96E65E733b99902306CAFEf2` |

Deployed in the [2026-06-10 fresh redeploy (Branch C)](#deployment-history) lost-key recovery.

## Deployment history

- [v0.7 deploy (2026-05-01)](docs/rollouts/2026-05-01-v0.7-deploy.md) — legacy arc-fx-gateway; archived on `legacy/v0.7-arc-fx-gateway` branch.
- [ArcoraDEX initial deploy (2026-05-06)](docs/rollouts/2026-05-06-arcoradex-deploy.md) — v1.0-testnet. Pool `0x3051d24D…` now paused/abandoned.
- [Key separation cutover (2026-05-10)](docs/rollouts/2026-05-10-key-separation-cutover.md) — tokens + feeds redeployed under separated EOA keys; same token addresses in use today.
- [Phase 1 — Testnet Redeploy (2026-05-14)](docs/rollouts/2026-05-14-phase1-deploy.md) — added `maxStaleSeconds` to Registry, `lastValidPrice` cache to Pool; fresh V2 deploy.
- [Phase 2 — Governance Migration (2026-05-14)](docs/rollouts/2026-05-14-phase2-governance.md) — Timelock + 3/5 Gov Safe + 2/3 Pause Guardian; V3 pool/registry/LP. Deployer EOA no longer direct owner.
- [Phase 3 — Oracle Hardening (2026-05-17/18)](docs/rollouts/2026-05-14-phase3-oracle.md) — dual-source `OracleAggregator` (V1), `CumulativeDeviationGuard`, tightened TRYC/BRLC caps; registry swapped via Timelock.
- [Phase 3 Operationalization (2026-05-18)](docs/rollouts/2026-05-18-phase3-operationalization.md)
- [Phase 3.5 OracleAggregator V2 (2026-05-20)](docs/rollouts/2026-05-20-phase3_5-oracle-v2.md) — V2 redeploy: per-source staleness, degraded-mode signal, monotonic roundId. Registry pointers swapped via Timelock batch `0xe2e130fb…58354c`, executed 2026-05-22 (tx `0x6b65230972baab17f256b9fd62643d7af370617ec8b6077fa30d7e852045d314`, block 43528310).
- 2026-06-10 fresh redeploy (Branch C): lost-key recovery — fresh governance + fresh tokens + fresh faucet on Arc testnet; deployer 0xC493…D7e6; Gov Safe 0x3961…261B 3/5, PG 0x1098…8280 2/3, Timelock 0xEb2E…e5D7 (delay 0, raising to 48h). Pool 0x2148…e2f6, Registry 0x372f…47f1, LP 0xc07e…FEf2.

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
