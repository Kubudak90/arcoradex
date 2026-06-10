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

// Addresses: 2026-06-10 fresh Arc testnet redeploy (Branch C); supersedes
// 2026-06-06 (keys lost). Decimals/amounts unchanged from prior deploy.
export const FAUCET_TOKENS: readonly FaucetToken[] = [
  { symbol: "USDC",  address: "0x200380a191FdB530C73120674EAF00E8417D168B", decimals: 6,  amount: 1_000n },
  { symbol: "USDT",  address: "0xd93548768635d218478899448729eB9d6fCE9903", decimals: 6,  amount: 1_000n },
  { symbol: "PYUSD", address: "0xd3fea5191fbD9e5B7492DE0e8289897514421407", decimals: 6,  amount: 1_000n },
  { symbol: "DAI",   address: "0x89dD7f0D66e35F78794ee0215E380DD3269A2a0B", decimals: 18, amount: 1_000n },
  { symbol: "EURC",  address: "0xD4637b44879630dD0fE35FE86CC90EA192aeF008", decimals: 6,  amount: 925n }, // ≈ $1000 @ 1.08
  { symbol: "TRYC",  address: "0x0dA050E630A1801421AdEf52351b1a1123b38265", decimals: 6,  amount: 34_500n }, // ≈ $1000 @ 0.029
  { symbol: "BRLC",  address: "0x98422826dD9C22123991713810E1aC0B5d15179d", decimals: 6,  amount: 5_000n }, // ≈ $1000 @ 0.20
] as const;
