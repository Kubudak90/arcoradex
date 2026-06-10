"use client";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useArcoraDexV2 } from "./useArcoraDexV2";
import type { SwapV2Args } from "../../actions/v2/swapV2";
import type { SwapResultV2 } from "../../types.v2";

export interface UseSwapV2Result {
  mutate: (
    args: SwapV2Args,
    opts?: { onSuccess?: (r: SwapResultV2) => void; onError?: (e: Error) => void },
  ) => void;
  mutateAsync: (args: SwapV2Args) => Promise<SwapResultV2>;
  isPending: boolean;
  error: Error | null;
  data: SwapResultV2 | undefined;
  reset: () => void;
}

export function useSwapV2(): UseSwapV2Result {
  const sdk = useArcoraDexV2();
  const qc = useQueryClient();

  const mutation = useMutation<SwapResultV2, Error, SwapV2Args>({
    mutationFn: (args) => sdk.swap(args),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["arcora", "v2", "poolStats", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "v2", "reserveHealth", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "v2", "quoteSwap", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "v2", "maxSwapOut", sdk.chain.id] });
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
