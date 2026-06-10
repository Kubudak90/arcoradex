import { baseSepolia } from "./chains/baseSepolia";
import { arcTestnet } from "./chains/arcTestnet";
import type { ArcoraDexAddresses } from "./addresses";

/**
 * Live Base Sepolia V2 ledger (chainId 84532), deployed 2026-06-10
 * (docs/rollouts/2026-06-10-base-sepolia-v2-deploy.md — the SECOND, working
 * broadcast; the abandoned upgraded-Pyth broadcast is NOT this set). Reuses the
 * V1 ArcoraDexAddresses {pool, registry, lp} shape.
 */
const BASE_SEPOLIA_V2: ArcoraDexAddresses = {
  pool:     "0x63FD6180dC6Aa5aE2941Bd28D2dc34c54F2b7820",
  registry: "0xae1f10b007cDC4131797A45232a3D52Ff2C314e2",
  lp:       "0x02aFC4c2c72ecE2049725DA2bd9080EF6285c844",
};

/**
 * Live Arc testnet V2 ledger (chainId 5042002), deployed 2026-06-11
 * (docs/rollouts/2026-06-09-* + the Arc V2 deploy record): the SAME V2 contracts
 * as Base (IArcoraDexPoolV2 etc.), only the addresses + chain differ. This is a
 * SEPARATE V2 deployment from the V1 Arc pool in `./addresses.ts` — they share
 * chainId 5042002 but are distinct contracts, so the V1 surface stays untouched.
 */
const ARC_TESTNET_V2: ArcoraDexAddresses = {
  pool:     "0x9191B2c7ac888F2840a99bb1Bf154b8B38716312",
  registry: "0x1beBA5b2F374F9e5C8b47439CB743442f1408536",
  lp:       "0x332e977aA9707eC3a0125B22c97Bc0c464658150",
};

export const DEFAULT_ADDRESSES_V2: Record<number, ArcoraDexAddresses> = {
  [baseSepolia.id]: BASE_SEPOLIA_V2,
  [arcTestnet.id]:  ARC_TESTNET_V2,
};
