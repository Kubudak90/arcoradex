import type { KnownTokenMeta } from "./known";

/** Live Base Sepolia (84532) V2 token addresses → labels (deploy 2026-06-10).
 *  Separate from the Arc KNOWN_TOKENS so the maps never cross chains. */
export const KNOWN_TOKENS_V2: Record<`0x${string}`, KnownTokenMeta> = {
  "0x3a98d8adC295d90171e9DA93D411dEa95674c867": { symbol: "USDC", name: "USD Coin" },
  "0x7110315D229C7CE655399703ACbA8E67f1d5C0c0": { symbol: "USDT", name: "Tether USD" },
  "0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7": { symbol: "EURC", name: "Euro Coin" },
};
