"use client";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useArcoraDexV2 } from "./useArcoraDexV2";
import type { DepositV2Args } from "../../actions/v2/depositV2";
import type { DepositResultV2 } from "../../types.v2";

export interface UseDepositV2Result {
  mutate: (
    args: DepositV2Args,
    opts?: { onSuccess?: (r: DepositResultV2) => void; onError?: (e: Error) => void },
  ) => void;
  mutateAsync: (args: DepositV2Args) => Promise<DepositResultV2>;
  isPending: boolean;
  error: Error | null;
  data: DepositResultV2 | undefined;
  reset: () => void;
}

export function useDepositV2(): UseDepositV2Result {
  const sdk = useArcoraDexV2();
  const qc = useQueryClient();

  const mutation = useMutation<DepositResultV2, Error, DepositV2Args>({
    mutationFn: (args) => sdk.deposit(args),
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
