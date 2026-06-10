"use client";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useArcoraDexV2 } from "./useArcoraDexV2";
import type { WithdrawProportionalV2Args } from "../../actions/v2/withdrawProportionalV2";
import type { WithdrawProportionalResult } from "../../types.v2";

export interface UseWithdrawProportionalV2Result {
  mutate: (
    args: WithdrawProportionalV2Args,
    opts?: { onSuccess?: (r: WithdrawProportionalResult) => void; onError?: (e: Error) => void },
  ) => void;
  mutateAsync: (args: WithdrawProportionalV2Args) => Promise<WithdrawProportionalResult>;
  isPending: boolean;
  error: Error | null;
  data: WithdrawProportionalResult | undefined;
  reset: () => void;
}

export function useWithdrawProportionalV2(): UseWithdrawProportionalV2Result {
  const sdk = useArcoraDexV2();
  const qc = useQueryClient();

  const mutation = useMutation<WithdrawProportionalResult, Error, WithdrawProportionalV2Args>({
    mutationFn: (args) => sdk.withdrawProportional(args),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["arcora", "v2", "poolStats", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "v2", "reserveHealth", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "v2", "maxWithdraw", sdk.chain.id] });
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
