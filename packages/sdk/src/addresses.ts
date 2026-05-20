import { arcTestnet } from "./chains/arcTestnet";

export interface ArcoraDexAddresses {
  pool:     `0x${string}`;
  registry: `0x${string}`;
  lp:       `0x${string}`;
}

/**
 * Live V3-testnet addresses on Arc (chainId 5042002).
 * Recorded in:
 *   - docs/rollouts/2026-05-14-phase3-oracle.md     (P3 oracle layer)
 *   - docs/rollouts/2026-05-14-phase2-governance.md (Timelock/Safe owners)
 * V1 addresses (paused) are kept only in git history; see commit dae32d1 for
 * the original.
 */
const ARC_TESTNET_V3: ArcoraDexAddresses = {
  registry: "0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB",
  pool:     "0x1ce1Ef94e7ebe70727BD69003d61A3F0c9A331bc",
  lp:       "0x17B47173C457069E53B3B75Ef42773041B79523e",
};

export const DEFAULT_ADDRESSES: Record<number, ArcoraDexAddresses> = {
  [arcTestnet.id]: ARC_TESTNET_V3,
};
