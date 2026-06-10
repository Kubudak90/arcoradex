"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "@arcoralabs/dex-sdk/react/v2";
import { poolAbiV2 } from "@arcoralabs/dex-sdk/v2";
import type { TokenInfoV2 } from "@arcoralabs/dex-sdk/v2";

/**
 * Per-token on-chain reserves (raw token amount) read from `pool.reserves(token)`.
 *
 * Used to derive pool composition / weight bars (Liquidity) and the Reserves
 * panel USD column (Pool). The USD value of a reserve = rawReserve × oraclePrice
 * normalised by decimals; that conversion is done by the caller (which already
 * holds the oracle prices via `useOraclePrices`). Returns a lowercase-address →
 * raw bigint map. No mock data — straight contract reads.
 */
export function useReserves(tokens: TokenInfoV2[]): {
  reserves: Record<string, bigint>;
  isFetching: boolean;
} {
  const sdk = useArcoraDexV2();
  const addrKey = tokens.map((t) => t.address).join(",");

  const { data, isFetching } = useQuery({
    queryKey: ["arcora", "v2", "reserves", sdk.chain.id, addrKey],
    enabled: tokens.length > 0,
    refetchInterval: 20_000,
    queryFn: async () => {
      const entries = await Promise.all(
        tokens.map(async (t) => {
          const raw = await sdk.publicClient.readContract({
            address: sdk.addresses.pool,
            abi: poolAbiV2,
            functionName: "reserves",
            args: [t.address],
          });
          return [t.address.toLowerCase(), raw] as const;
        }),
      );
      return Object.fromEntries(entries) as Record<string, bigint>;
    },
  });

  return { reserves: data ?? {}, isFetching };
}

// Re-export the pure conversion from lp-math so callers can import it alongside
// the hook (the math itself is unit-tested in lp-math.ts).
export { reserveUsd1e18 } from "./lp-math";
