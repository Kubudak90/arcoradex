"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "@arcoralabs/dex-sdk/react/v2";
import type { TokenInfoV2 } from "@arcoralabs/dex-sdk/v2";
import { parseAbi } from "viem";

/**
 * Minimal IOracleAdapterV2 surface — the Pool never exposes a raw oracle, but
 * each token's `adapter` does. `peekPrice` is the view-only price read (1e18 USD
 * + a binary `safe` flag) used by quotes/views, so it is consistent with what
 * the contract authorizes (§10/§11). A token is `safe` only when both
 * independent sources are fresh/valid/in-bounds; otherwise `safe == false` and
 * the Pool MUST NOT authorize an oracle-priced transfer on it (single-token
 * swap/withdraw paused → proportional exit only).
 */
export const oracleAdapterAbiV2 = parseAbi([
  "function peekPrice(address token) view returns (uint256 price1e18, bool safe)",
]);

export interface OraclePrice {
  /** 1e18-scaled USD price (last-known if unsafe; may be 0 if never seeded). */
  price1e18: bigint;
  /** True only when the token is safe for an oracle-priced operation. */
  safe: boolean;
}

/**
 * GF-2 data source: reads each active token's live oracle price + safe flag via
 * its `adapter.peekPrice(token)`. Returns a lowercase-address → OraclePrice map.
 *
 * Read-only. Refetched on an interval so the Pool/Liquidity oracle badges and
 * USD valuations stay live without a manual refresh. No mock data — purely the
 * on-chain adapter reads.
 */
export function useOraclePrices(tokens: TokenInfoV2[]): {
  prices: Record<string, OraclePrice>;
  isFetching: boolean;
} {
  const sdk = useArcoraDexV2();
  const addrKey = tokens.map((t) => t.address).join(",");

  const { data, isFetching } = useQuery({
    queryKey: ["arcora", "v2", "oraclePrices", sdk.chain.id, addrKey],
    enabled: tokens.length > 0,
    refetchInterval: 15_000,
    queryFn: async () => {
      const entries = await Promise.all(
        tokens.map(async (t) => {
          try {
            const [price1e18, safe] = await sdk.publicClient.readContract({
              address: t.adapter,
              abi: oracleAdapterAbiV2,
              functionName: "peekPrice",
              args: [t.address],
            });
            return [t.address.toLowerCase(), { price1e18, safe }] as const;
          } catch {
            // A reverting / unconfigured adapter is treated as unsafe with no
            // usable price — the proportional-exit path stays available.
            return [t.address.toLowerCase(), { price1e18: 0n, safe: false }] as const;
          }
        }),
      );
      return Object.fromEntries(entries) as Record<string, OraclePrice>;
    },
  });

  return { prices: data ?? {}, isFetching };
}
