import { arcTestnet } from "./chains/arcTestnet";

export interface ArcoraDexAddresses {
  pool:     `0x${string}`;
  registry: `0x${string}`;
  lp:       `0x${string}`;
}

/**
 * Live public-testnet addresses on Arc (chainId 5042002).
 * Deployed 2026-06-06 via DeployPublicTestnet.s.sol (fresh M-1 governance:
 * Gov Safe 3/5 + Pause-Guardian 2/3 + 48h Timelock; H-2 separated keepers).
 * Prior deployments are kept only in git history.
 */
const ARC_TESTNET_V3: ArcoraDexAddresses = {
  registry: "0xc6D0FB58Bf2d529021A4E679F36Fe31842A97c97",
  pool:     "0x532505501B1D789A724E9341B95aD9037aA1a3bf",
  lp:       "0x8C286D963030E5218d08E2cf83F40c624b561155",
};

export const DEFAULT_ADDRESSES: Record<number, ArcoraDexAddresses> = {
  [arcTestnet.id]: ARC_TESTNET_V3,
};
