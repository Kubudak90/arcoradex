"use client";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useArcoraDex } from "./useArcoraDex";
import type { SwapArgs } from "../actions/swap";
import type { SwapResult } from "../types";

export interface UseSwapResult {
  mutate: (
    args: SwapArgs,
    opts?: { onSuccess?: (r: SwapResult) => void; onError?: (e: Error) => void },
  ) => void;
  mutateAsync: (args: SwapArgs) => Promise<SwapResult>;
  isPending: boolean;
  error: Error | null;
  data: SwapResult | undefined;
  reset: () => void;
}

export function useSwap(): UseSwapResult {
  const sdk = useArcoraDex();
  const qc = useQueryClient();

  const mutation = useMutation<SwapResult, Error, SwapArgs>({
    mutationFn: (args) => sdk.swap(args),
    onSuccess: () => {
      // Invalidate read queries that depend on chain state.
      qc.invalidateQueries({ queryKey: ["arcora", "tokens", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "poolStats", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "position", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "quoteSwap", sdk.chain.id] });
    },
  });

  return {
    mutate: (args, opts) => mutation.mutate(args, opts),
    mutateAsync: (args) => mutation.mutateAsync(args),
    isPending: mutation.isPending,
    error: mutation.error,
    data: mutation.data,
    reset: mutation.reset,
  };
}
