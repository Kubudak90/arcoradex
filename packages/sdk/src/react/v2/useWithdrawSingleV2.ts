"use client";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useArcoraDexV2 } from "./useArcoraDexV2";
import type { WithdrawSingleV2Args } from "../../actions/v2/withdrawSingleV2";
import type { WithdrawSingleResult } from "../../types.v2";

export interface UseWithdrawSingleV2Result {
  mutate: (
    args: WithdrawSingleV2Args,
    opts?: { onSuccess?: (r: WithdrawSingleResult) => void; onError?: (e: Error) => void },
  ) => void;
  mutateAsync: (args: WithdrawSingleV2Args) => Promise<WithdrawSingleResult>;
  isPending: boolean;
  error: Error | null;
  data: WithdrawSingleResult | undefined;
  reset: () => void;
}

export function useWithdrawSingleV2(): UseWithdrawSingleV2Result {
  const sdk = useArcoraDexV2();
  const qc = useQueryClient();

  const mutation = useMutation<WithdrawSingleResult, Error, WithdrawSingleV2Args>({
    mutationFn: (args) => sdk.withdrawSingle(args),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["arcora", "v2", "poolStats", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "v2", "reserveHealth", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "v2", "maxWithdraw", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "v2", "quoteWithdraw", sdk.chain.id] });
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
