import { arcTestnet } from "./chains/arcTestnet";

export interface ArcoraDexAddresses {
  pool:     `0x${string}`;
  registry: `0x${string}`;
  lp:       `0x${string}`;
}

/** v1.0-testnet addresses, recorded in docs/rollouts/2026-05-06-arcoradex-deploy.md. */
const ARC_TESTNET_V1: ArcoraDexAddresses = {
  registry: "0x920E3E59DD37Be3D9D3750D7B912A9dd08db0D29",
  pool:     "0x3051d24D771bAF44031571544a9159578035D0c5",
  lp:       "0x7CEAbF411806A29ffaEbCAB2BF3Dc8a9ECBD110C",
};

export const DEFAULT_ADDRESSES: Record<number, ArcoraDexAddresses> = {
  [arcTestnet.id]: ARC_TESTNET_V1,
};
