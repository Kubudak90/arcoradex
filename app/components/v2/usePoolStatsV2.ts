"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "@arcoralabs/dex-sdk/react/v2";
import type { PoolStatsV2 } from "@arcoralabs/dex-sdk/v2";

/**
 * Pool-level stats for the Pool page + swap stat tiles —
 * `{ navUsd1e18, lpSupply, lpPriceUsd1e18, protocolFeeShareBps, paused }`.
 *
 * The SDK ships no `usePoolStatsV2` hook, so this wraps `sdk.getPoolStats` in
 * react-query. The query key is chain-scoped to match the V2 mutation
 * invalidations (the swap/deposit/withdraw hooks invalidate
 * `["arcora","v2","poolStats", chainId]`), so it refreshes after each write.
 */
export function usePoolStatsV2(): { stats: PoolStatsV2 | null; isFetching: boolean } {
  const sdk = useArcoraDexV2();
  const { data, isFetching } = useQuery({
    queryKey: ["arcora", "v2", "poolStats", sdk.chain.id],
    queryFn: () => sdk.getPoolStats(),
  });
  return { stats: data ?? null, isFetching };
}
