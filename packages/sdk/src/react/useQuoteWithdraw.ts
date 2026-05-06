"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDex } from "./useArcoraDex";
import { useDebouncedValue } from "./useDebouncedValue";

export interface UseQuoteWithdrawArgs {
  tokenOut?: `0x${string}`;
  lpAmount?: bigint;
}

export interface UseQuoteWithdrawOptions {
  debounceMs?: number;
  enabled?: boolean;
}

export interface UseQuoteWithdrawResult {
  data: { amountOut: bigint; protocolFee: bigint } | null;
  isFetching: boolean;
  error: Error | null;
}

export function useQuoteWithdraw(
  args: UseQuoteWithdrawArgs,
  options?: UseQuoteWithdrawOptions,
): UseQuoteWithdrawResult {
  const sdk = useArcoraDex();
  const debouncedLp = useDebouncedValue(args.lpAmount, options?.debounceMs ?? 400);

  const enabled =
    (options?.enabled ?? true) && !!args.tokenOut && !!debouncedLp && debouncedLp > 0n;

  const { data, isFetching, error } = useQuery({
    queryKey: ["arcora", "quoteWithdraw", sdk.chain.id, args.tokenOut, debouncedLp?.toString()],
    queryFn: () => sdk.quoteWithdraw({ tokenOut: args.tokenOut!, lpAmount: debouncedLp! }),
    enabled,
  });

  return { data: data ?? null, isFetching, error: error as Error | null };
}
