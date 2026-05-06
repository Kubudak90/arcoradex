/**
 * ArcoraDEX testnet contract addresses (chainId 5042002).
 *
 * Sourced from docs/rollouts/2026-05-06-arcoradex-deploy.md.
 * Override at build time via NEXT_PUBLIC_* env vars (see .env.example).
 */

const env = (k: string, fallback: `0x${string}`): `0x${string}` => {
  const v = process.env[k];
  return (v && v.startsWith("0x") ? (v as `0x${string}`) : fallback);
};

export const POOL_ADDRESS = env(
  "NEXT_PUBLIC_POOL_ADDRESS",
  "0x3051d24D771bAF44031571544a9159578035D0c5"
);
export const REGISTRY_ADDRESS = env(
  "NEXT_PUBLIC_REGISTRY_ADDRESS",
  "0x920E3E59DD37Be3D9D3750D7B912A9dd08db0D29"
);
export const LP_ADDRESS = env(
  "NEXT_PUBLIC_LP_ADDRESS",
  "0x7CEAbF411806A29ffaEbCAB2BF3Dc8a9ECBD110C"
);

/**
 * Initial token roster — labels + symbols only. The frontend reads decimals,
 * oracle, and active state from the registry on chain; this list just gives
 * us human-readable identity for known mocks. Unknown listed tokens render
 * with a fallback label.
 */
export const KNOWN_TOKENS: Record<string, { symbol: string; name: string }> = {
  "0x3BFa09fF6467639f0981948385bA1018Ac07d22C": { symbol: "USDC", name: "USD Coin" },
  "0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B": { symbol: "USDT", name: "Tether USD" },
  "0xfdB2c86d010698401f0b969348DC58b6659B96a3": { symbol: "PYUSD", name: "PayPal USD" },
  "0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE": { symbol: "DAI", name: "Dai" },
  "0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD": { symbol: "EURC", name: "Euro Coin" },
  "0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61": { symbol: "TRYC", name: "Turkish Lira Coin" },
  "0xa13c0935A98e2c175b31A4054f698819271a8FfC": { symbol: "BRLC", name: "Brazilian Real Coin" },
};

export function tokenLabel(address: string): { symbol: string; name: string } {
  const meta = KNOWN_TOKENS[address] || KNOWN_TOKENS[address.toLowerCase()] || KNOWN_TOKENS[address.toUpperCase()];
  if (meta) return meta;
  return { symbol: address.slice(2, 6).toUpperCase(), name: address };
}
