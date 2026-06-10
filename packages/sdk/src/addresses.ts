import { arcTestnet } from "./chains/arcTestnet";

export interface ArcoraDexAddresses {
  pool:     `0x${string}`;
  registry: `0x${string}`;
  lp:       `0x${string}`;
}

/**
 * Live public-testnet addresses on Arc (chainId 5042002).
 * FRESH redeploy 2026-06-10 (Branch C lost-key recovery): fresh governance
 * (Gov Safe 3/5 + Pause-Guardian 2/3 + Timelock) + fresh tokens + fresh faucet.
 * Supersedes the 2026-06-06 set (keys lost). Prior deployments are kept only in
 * git history.
 */
const ARC_TESTNET_V3: ArcoraDexAddresses = {
  registry: "0x372f83a1432Aa43b72eDCE083DC8352d9Bfb47f1",
  pool:     "0x214825E3e24a07cd58e48267e492320dAccCe2f6",
  lp:       "0xc07e979B5Ee023Ad96E65E733b99902306CAFEf2",
};

export const DEFAULT_ADDRESSES: Record<number, ArcoraDexAddresses> = {
  [arcTestnet.id]: ARC_TESTNET_V3,
};
