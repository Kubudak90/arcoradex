// Static list of stables the faucet mints per claim. Decimals locked to the
// live Arc testnet deployment. Amounts chosen so each mint is roughly
// $1000 USD-equivalent at the asset's peg/price.
//
// The shape is asserted by app/lib/__tests__/faucet-tokens.test.ts so a
// silent mismatch (e.g. wrong decimals, zero amount, dirty address) breaks
// CI before the route hits production.

export interface FaucetToken {
  symbol: string;
  address: `0x${string}`;
  decimals: 6 | 18;
  amount: bigint;
}

export const FAUCET_TOKENS: readonly FaucetToken[] = [
  { symbol: "USDC",  address: "0x3BFa09fF6467639f0981948385bA1018Ac07d22C", decimals: 6,  amount: 1_000n },
  { symbol: "USDT",  address: "0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B", decimals: 6,  amount: 1_000n },
  { symbol: "PYUSD", address: "0xfdB2c86d010698401f0b969348DC58b6659B96a3", decimals: 6,  amount: 1_000n },
  { symbol: "DAI",   address: "0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE", decimals: 18, amount: 1_000n },
  { symbol: "EURC",  address: "0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD", decimals: 6,  amount: 925n }, // ≈ $1000 @ 1.08
  { symbol: "TRYC",  address: "0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61", decimals: 6,  amount: 34_500n }, // ≈ $1000 @ 0.029
  { symbol: "BRLC",  address: "0xa13c0935A98e2c175b31A4054f698819271a8FfC", decimals: 6,  amount: 5_000n }, // ≈ $1000 @ 0.20
] as const;
