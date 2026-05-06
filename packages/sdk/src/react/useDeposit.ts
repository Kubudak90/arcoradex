"use client";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useArcoraDex } from "./useArcoraDex";
import type { DepositArgs } from "../actions/deposit";
import type { DepositResult } from "../types";

export interface UseDepositResult {
  mutate: (
    args: DepositArgs,
    opts?: { onSuccess?: (r: DepositResult) => void; onError?: (e: Error) => void },
  ) => void;
  mutateAsync: (args: DepositArgs) => Promise<DepositResult>;
  isPending: boolean;
  error: Error | null;
  data: DepositResult | undefined;
  reset: () => void;
}

export function useDeposit(): UseDepositResult {
  const sdk = useArcoraDex();
  const qc = useQueryClient();

  const mutation = useMutation<DepositResult, Error, DepositArgs>({
    mutationFn: (args) => sdk.deposit(args),
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
