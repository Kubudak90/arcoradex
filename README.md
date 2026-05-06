# ArcoraDEX

> Oracle-priced multi-stablecoin DEX with public liquidity. Part of [ArcoraLabs](https://github.com/Kubudak90).

ArcoraDEX is a shared-vault, oracle-priced swap protocol for stablecoins. Anyone can deposit any active stable, receive a single USD-denominated `ADEX-LP` token, and earn 90% of swap fees. Withdrawals are single-token at oracle price minus the swap fee.

## Status

- **v1.0-testnet** — live on Arc testnet (chainId 5042002). Frontend at <https://swap.arcorapay.xyz>. Addresses + smoke flows in `docs/rollouts/2026-05-06-arcoradex-deploy.md`.
- **Design / plan** — `docs/superpowers/specs/2026-05-06-arcoradex-spinoff-design.md` and `docs/superpowers/plans/2026-05-06-arcoradex-spinoff.md`.
- **Roadmap** — Phase B (TypeScript SDK), Phase C (analytics dashboard), Phase D (docs site), Phase E (audit + Arc mainnet). See spec §10.
- **Legacy** — the prior `arc-fx-gateway` + multi-stable pool state is preserved on the `legacy/v0.7-arc-fx-gateway` branch.

## Local development

```bash
# Contracts (68 tests: registry / LP / pool / fuzz / invariant)
cd contracts
forge install
forge test
FOUNDRY_PROFILE=ci forge test    # 10k fuzz runs, 1024x128 invariants

# Deploy (Arc testnet)
PRIVATE_KEY=0x... forge script script/DeployArcoraDex.s.sol \
  --rpc-url https://rpc.testnet.arc.network --broadcast --slow

# Frontend (Next.js 16 + wagmi/viem)
cd app
pnpm install
pnpm dev                         # http://localhost:3000
pnpm typecheck && pnpm test && pnpm build
```

## License

MIT
