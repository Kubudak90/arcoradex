# @arcoralabs/dex-sdk

TypeScript SDK for [ArcoraDEX](https://swap.arcorapay.xyz). Framework-agnostic core + React hooks.

> **Phase B v0.1** — workspace-only. Will be published to NPM at v1.0 after the spec §10 trigger (30 days stable on testnet, or external integration demand).

## Usage

```ts
import { createArcoraDex, arcTestnet } from "@arcoralabs/dex-sdk";
import { http } from "viem";

const sdk = createArcoraDex({ chain: arcTestnet, transport: http() });
const out = await sdk.quoteSwap({ tokenIn, tokenOut, amountIn });
```

See `docs/superpowers/specs/2026-05-06-sdk-phase-b-design.md` in the repo for the full API.

## License

MIT
