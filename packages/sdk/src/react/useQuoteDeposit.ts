"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDex } from "./useArcoraDex";
import { useDebouncedValue } from "./useDebouncedValue";

export interface UseQuoteDepositArgs {
  token?: `0x${string}`;
  amount?: bigint;
}

export interface UseQuoteDepositOptions {
  debounceMs?: number;
  enabled?: boolean;
}

export interface UseQuoteDepositResult {
  data: bigint | null;
  isFetching: boolean;
  error: Error | null;
}

export function useQuoteDeposit(
  args: UseQuoteDepositArgs,
  options?: UseQuoteDepositOptions,
): UseQuoteDepositResult {
  const sdk = useArcoraDex();
  const debouncedAmount = useDebouncedValue(args.amount, options?.debounceMs ?? 400);

  const enabled =
    (options?.enabled ?? true) && !!args.token && !!debouncedAmount && debouncedAmount > 0n;

  const { data, isFetching, error } = useQuery({
    queryKey: ["arcora", "quoteDeposit", sdk.chain.id, args.token, debouncedAmount?.toString()],
    queryFn: () => sdk.quoteDeposit({ token: args.token!, amount: debouncedAmount! }),
    enabled,
  });

  return { data: data ?? null, isFetching, error: error as Error | null };
}
