# ArcoraDEX

> Oracle-priced multi-stablecoin DEX with public liquidity. Part of [ArcoraLabs](https://github.com/Kubudak90).

ArcoraDEX is a shared-vault, oracle-priced swap protocol for stablecoins. Anyone can deposit any active stable, receive a single USD-denominated `ADEX-LP` token, and earn 90% of swap fees. Withdrawals are single-token at oracle price minus the swap fee.

## Status

- **v1 (Phase A)** — under construction. See `docs/superpowers/specs/2026-05-06-arcoradex-spinoff-design.md` for the design and `docs/superpowers/plans/2026-05-06-arcoradex-spinoff.md` for the implementation plan.
- **Roadmap** — Phase B (TypeScript SDK), Phase C (analytics dashboard), Phase D (docs site), Phase E (audit + Arc mainnet). See spec §10.
- **Legacy** — the prior `arc-fx-gateway` + multi-stable pool state is preserved on the `legacy/v0.7-arc-fx-gateway` branch.

## Local development

```bash
cd contracts
forge install
forge test
```

Contracts will deploy via `script/DeployArcoraDex.s.sol` (added in T14). Frontend lives under `app/` (Next.js 16); see its README once added.

## License

MIT
