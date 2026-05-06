export interface KnownTokenMeta {
  symbol: string;
  name: string;
}

/** Checksummed v1.0-testnet token addresses → human metadata. */
export const KNOWN_TOKENS: Record<`0x${string}`, KnownTokenMeta> = {
  "0x3BFa09fF6467639f0981948385bA1018Ac07d22C": { symbol: "USDC", name: "USD Coin" },
  "0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B": { symbol: "USDT", name: "Tether USD" },
  "0xfdB2c86d010698401f0b969348DC58b6659B96a3": { symbol: "PYUSD", name: "PayPal USD" },
  "0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE": { symbol: "DAI", name: "Dai" },
  "0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD": { symbol: "EURC", name: "Euro Coin" },
  "0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61": { symbol: "TRYC", name: "Turkish Lira Coin" },
  "0xa13c0935A98e2c175b31A4054f698819271a8FfC": { symbol: "BRLC", name: "Brazilian Real Coin" },
};
