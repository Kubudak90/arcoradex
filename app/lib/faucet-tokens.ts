// Static list of stables the faucet mints per claim. Decimals locked to the
// live Base Sepolia (84532) V2 deployment. Amounts chosen so each mint is
// roughly $1000 USD-equivalent at the asset's peg/price.
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

// Addresses: live Base Sepolia (84532) V2 token set (deploy 2026-06-10).
// Source of truth: packages/sdk/src/tokens/known.v2.ts. All three mints are
// 6-decimal mocks; EURC is trimmed to ≈ $1000 at the €/$ peg.
export const FAUCET_TOKENS: readonly FaucetToken[] = [
  { symbol: "USDC", address: "0x3a98d8adC295d90171e9DA93D411dEa95674c867", decimals: 6, amount: 1_000n },
  { symbol: "USDT", address: "0x7110315D229C7CE655399703ACbA8E67f1d5C0c0", decimals: 6, amount: 1_000n },
  { symbol: "EURC", address: "0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7", decimals: 6, amount: 925n }, // ≈ $1000 @ 1.08
] as const;
