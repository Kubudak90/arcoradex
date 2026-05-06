"use client";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useArcoraDex } from "./useArcoraDex";
import type { WithdrawArgs } from "../actions/withdraw";
import type { WithdrawResult } from "../types";

export interface UseWithdrawResult {
  mutate: (
    args: WithdrawArgs,
    opts?: { onSuccess?: (r: WithdrawResult) => void; onError?: (e: Error) => void },
  ) => void;
  mutateAsync: (args: WithdrawArgs) => Promise<WithdrawResult>;
  isPending: boolean;
  error: Error | null;
  data: WithdrawResult | undefined;
  reset: () => void;
}

export function useWithdraw(): UseWithdrawResult {
  const sdk = useArcoraDex();
  const qc = useQueryClient();

  const mutation = useMutation<WithdrawResult, Error, WithdrawArgs>({
    mutationFn: (args) => sdk.withdraw(args),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["arcora", "poolStats", sdk.chain.id] });
      qc.invalidateQueries({ queryKey: ["arcora", "position", sdk.chain.id] });
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
