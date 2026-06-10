export interface KnownTokenMeta {
  symbol: string;
  name: string;
}

/** Checksummed Arc-testnet token addresses → human metadata.
 *  FRESH redeploy 2026-06-10 (Branch C); supersedes 2026-06-06 (keys lost). */
export const KNOWN_TOKENS: Record<`0x${string}`, KnownTokenMeta> = {
  "0x200380a191FdB530C73120674EAF00E8417D168B": { symbol: "USDC", name: "USD Coin" },
  "0xd93548768635d218478899448729eB9d6fCE9903": { symbol: "USDT", name: "Tether USD" },
  "0xd3fea5191fbD9e5B7492DE0e8289897514421407": { symbol: "PYUSD", name: "PayPal USD" },
  "0x89dD7f0D66e35F78794ee0215E380DD3269A2a0B": { symbol: "DAI", name: "Dai" },
  "0xD4637b44879630dD0fE35FE86CC90EA192aeF008": { symbol: "EURC", name: "Euro Coin" },
  "0x0dA050E630A1801421AdEf52351b1a1123b38265": { symbol: "TRYC", name: "Turkish Lira Coin" },
  "0x98422826dD9C22123991713810E1aC0B5d15179d": { symbol: "BRLC", name: "Brazilian Real Coin" },
};
