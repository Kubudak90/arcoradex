import { baseSepolia } from "./chains/baseSepolia";
import type { ArcoraDexAddresses } from "./addresses";

/**
 * Live Base Sepolia V2 ledger (chainId 84532), deployed 2026-06-10
 * (docs/rollouts/2026-06-10-base-sepolia-v2-deploy.md — the SECOND, working
 * broadcast; the abandoned upgraded-Pyth broadcast is NOT this set). Reuses the
 * V1 ArcoraDexAddresses {pool, registry, lp} shape. Kept SEPARATE from the V1
 * DEFAULT_ADDRESSES (Arc 5042002) so the two chains coexist and the V1/Arc live
 * test stays green.
 */
const BASE_SEPOLIA_V2: ArcoraDexAddresses = {
  pool:     "0x63FD6180dC6Aa5aE2941Bd28D2dc34c54F2b7820",
  registry: "0xae1f10b007cDC4131797A45232a3D52Ff2C314e2",
  lp:       "0x02aFC4c2c72ecE2049725DA2bd9080EF6285c844",
};

export const DEFAULT_ADDRESSES_V2: Record<number, ArcoraDexAddresses> = {
  [baseSepolia.id]: BASE_SEPOLIA_V2,
};
