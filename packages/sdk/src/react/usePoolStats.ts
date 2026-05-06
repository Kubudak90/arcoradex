"use client";
import { useEffect, useMemo } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useBlockNumber } from "wagmi";
import { useArcoraDex } from "./useArcoraDex";
import type { PoolStats } from "../types";

export interface UsePoolStatsOptions {
  refetchOnBlock?: boolean;
}

export interface UsePoolStatsResult {
  stats: PoolStats | null;
  isLoading: boolean;
  error: Error | null;
}

export function usePoolStats(options?: UsePoolStatsOptions): UsePoolStatsResult {
  const sdk = useArcoraDex();
  const qc = useQueryClient();
  const queryKey = useMemo(
    () => ["arcora", "poolStats", sdk.chain.id, sdk.addresses.pool] as const,
    [sdk.chain.id, sdk.addresses.pool],
  );

  const { data: blockNumber } = useBlockNumber({
    watch: options?.refetchOnBlock ?? false,
    // Cast: wagmi's `Register` narrows `chainId` in consumer apps; SDK is chain-agnostic.
    chainId: sdk.chain.id as never,
  });

  useEffect(() => {
    if (blockNumber !== undefined) {
      qc.invalidateQueries({ queryKey });
    }
  }, [blockNumber, qc, queryKey]);

  const { data, isLoading, error } = useQuery({
    queryKey,
    queryFn: () => sdk.getPoolStats(),
  });

  return { stats: data ?? null, isLoading, error: error as Error | null };
}
