"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "@arcoralabs/dex-sdk/react/v2";
import type { TokenInfoV2 } from "@arcoralabs/dex-sdk/v2";

/**
 * The live V2 token universe (USDC/USDT/EURC on Base Sepolia 84532).
 *
 * The SDK ships no `useTokensV2` hook, so this wraps `sdk.getTokens` in
 * react-query (the plan's prescribed approach). Returns the active tokens, a
 * by-address (lowercased) lookup map, and the fetching flag. The query key is
 * chain-scoped so it matches the V2 mutation invalidations.
 */
export function useTokensV2(): {
  tokens: TokenInfoV2[];
  byAddr: Record<string, TokenInfoV2>;
  isFetching: boolean;
} {
  const sdk = useArcoraDexV2();
  const { data, isFetching } = useQuery({
    queryKey: ["arcora", "v2", "tokens", sdk.chain.id],
    queryFn: () => sdk.getTokens({ activeOnly: true }),
  });
  const tokens = data ?? [];
  const byAddr = Object.fromEntries(
    tokens.map((t) => [t.address.toLowerCase(), t]),
  ) as Record<string, TokenInfoV2>;
  return { tokens, byAddr, isFetching };
}
