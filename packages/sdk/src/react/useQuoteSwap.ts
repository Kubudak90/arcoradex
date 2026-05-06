"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDex } from "./useArcoraDex";
import { useDebouncedValue } from "./useDebouncedValue";

export interface UseQuoteSwapArgs {
  tokenIn?: `0x${string}`;
  tokenOut?: `0x${string}`;
  amountIn?: bigint;
}

export interface UseQuoteSwapOptions {
  debounceMs?: number;
  enabled?: boolean;
}

export interface UseQuoteSwapResult {
  data: bigint | null;
  isFetching: boolean;
  error: Error | null;
}

export function useQuoteSwap(
  args: UseQuoteSwapArgs,
  options?: UseQuoteSwapOptions,
): UseQuoteSwapResult {
  const sdk = useArcoraDex();
  const debouncedAmount = useDebouncedValue(args.amountIn, options?.debounceMs ?? 400);

  const enabled =
    (options?.enabled ?? true) &&
    !!args.tokenIn &&
    !!args.tokenOut &&
    args.tokenIn !== args.tokenOut &&
    !!debouncedAmount &&
    debouncedAmount > 0n;

  const { data, isFetching, error } = useQuery({
    queryKey: [
      "arcora",
      "quoteSwap",
      sdk.chain.id,
      args.tokenIn,
      args.tokenOut,
      debouncedAmount?.toString(),
    ],
    queryFn: () =>
      sdk.quoteSwap({
        tokenIn: args.tokenIn!,
        tokenOut: args.tokenOut!,
        amountIn: debouncedAmount!,
      }),
    enabled,
  });

  return { data: data ?? null, isFetching, error: error as Error | null };
}
