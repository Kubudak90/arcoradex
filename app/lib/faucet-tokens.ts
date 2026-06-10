// Per-chain token sets the faucet mints per claim. Both live V2 deployments
// (Base Sepolia 84532 + Arc testnet 5042002) expose the same three 6-decimal
// mock stables, at different addresses, all owned by the faucet signer
// (0xb5f3…08B6) on both chains. Amounts chosen so each mint is roughly
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

// Chain ids are literals (not SDK imports) so this module stays dependency-
// free for both the server route and the client FaucetButton. They must match
// the SDK chain definitions in packages/sdk/src/chains/.
export const BASE_SEPOLIA_CHAIN_ID = 84532;
export const ARC_TESTNET_CHAIN_ID = 5042002;

// Addresses: source of truth is packages/sdk/src/tokens/known.v2.ts.
export const FAUCET_TOKENS_BY_CHAIN: Record<number, readonly FaucetToken[]> = {
  // Base Sepolia (84532) — live V2 token set (deploy 2026-06-10).
  // EURC trimmed to ≈ $1000 at the €/$ peg ($1.08).
  [BASE_SEPOLIA_CHAIN_ID]: [
    { symbol: "USDC", address: "0x3a98d8adC295d90171e9DA93D411dEa95674c867", decimals: 6, amount: 1_000n },
    { symbol: "USDT", address: "0x7110315D229C7CE655399703ACbA8E67f1d5C0c0", decimals: 6, amount: 1_000n },
    { symbol: "EURC", address: "0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7", decimals: 6, amount: 925n }, // ≈ $1000 @ 1.08
  ],
  // Arc testnet (5042002) — live V2 token set (deploy 2026-06-11).
  // Flat 1000 per stable for simplicity; Arc's EURC mock prices ≈ $1.15, so
  // that leg is worth ≈ $1150 — acceptable drift for a testnet faucet.
  [ARC_TESTNET_CHAIN_ID]: [
    { symbol: "USDC", address: "0x168655bc42265d8721AD6BCe20435919A0160B79", decimals: 6, amount: 1_000n },
    { symbol: "USDT", address: "0xD05FE3e0A38508b182143E1eBf69C657a87cBe22", decimals: 6, amount: 1_000n },
    { symbol: "EURC", address: "0xb1D82C6ba72CfE115Baa0Cd33De78224D9370Eea", decimals: 6, amount: 1_000n },
  ],
};

/** Chain ids the faucet can mint on. */
export const FAUCET_SUPPORTED_CHAIN_IDS: readonly number[] = Object.keys(
  FAUCET_TOKENS_BY_CHAIN,
).map(Number);

/** Token set for a chain id, or `undefined` when the faucet doesn't mint there. */
export function faucetTokensFor(
  chainId: number | undefined,
): readonly FaucetToken[] | undefined {
  return chainId == null ? undefined : FAUCET_TOKENS_BY_CHAIN[chainId];
}

// Back-compat: the original flat export — the DEFAULT (Base Sepolia) set.
// Prefer `faucetTokensFor(chainId)` in chain-aware code paths.
export const FAUCET_TOKENS: readonly FaucetToken[] =
  FAUCET_TOKENS_BY_CHAIN[BASE_SEPOLIA_CHAIN_ID]!;
