import type { KnownTokenMeta } from "./known";
import { baseSepolia } from "../chains/baseSepolia";
import { arcTestnet } from "../chains/arcTestnet";

/** Live V2 token addresses → labels, keyed by chain id. Each chain's V2 pool
 *  exposes the same three stables; addresses never collide across chains, so
 *  the flat `KNOWN_TOKENS_V2` (below) can merge them for the address-only
 *  lookup `getTokensV2` performs. */
export const KNOWN_TOKENS_V2_BY_CHAIN: Record<number, Record<`0x${string}`, KnownTokenMeta>> = {
  // Base Sepolia (84532) — deploy 2026-06-10.
  [baseSepolia.id]: {
    "0x3a98d8adC295d90171e9DA93D411dEa95674c867": { symbol: "USDC", name: "USD Coin" },
    "0x7110315D229C7CE655399703ACbA8E67f1d5C0c0": { symbol: "USDT", name: "Tether USD" },
    "0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7": { symbol: "EURC", name: "Euro Coin" },
  },
  // Arc testnet (5042002) — deploy 2026-06-11.
  [arcTestnet.id]: {
    "0x168655bc42265d8721AD6BCe20435919A0160B79": { symbol: "USDC", name: "USD Coin" },
    "0xD05FE3e0A38508b182143E1eBf69C657a87cBe22": { symbol: "USDT", name: "Tether USD" },
    "0xb1D82C6ba72CfE115Baa0Cd33De78224D9370Eea": { symbol: "EURC", name: "Euro Coin" },
  },
};

/** Flat union of every chain's V2 tokens → labels. `getTokensV2` looks up by
 *  address only (it already knows the active chain via the registry it reads),
 *  and addresses are unique across chains, so a flat merge is safe and keeps
 *  the existing lookup path unchanged. */
export const KNOWN_TOKENS_V2: Record<`0x${string}`, KnownTokenMeta> = Object.assign(
  {},
  ...Object.values(KNOWN_TOKENS_V2_BY_CHAIN),
) as Record<`0x${string}`, KnownTokenMeta>;
