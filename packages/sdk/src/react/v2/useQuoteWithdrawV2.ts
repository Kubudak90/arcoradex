"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "./useArcoraDexV2";
import { useDebouncedValue } from "../useDebouncedValue";
import type { QuoteV2 } from "../../types.v2";

export function useQuoteWithdrawV2(
  args: { tokenOut?: `0x${string}`; lpAmount?: bigint },
  options?: { debounceMs?: number; enabled?: boolean },
) {
  const sdk = useArcoraDexV2();
  const amount = useDebouncedValue(args.lpAmount, options?.debounceMs ?? 400);
  const enabled =
    (options?.enabled ?? true) && !!args.tokenOut && !!amount && amount > 0n;
  const { data, isFetching, error } = useQuery({
    queryKey: ["arcora", "v2", "quoteWithdraw", sdk.chain.id, args.tokenOut, amount?.toString()],
    queryFn: () => sdk.quoteWithdrawV2({ tokenOut: args.tokenOut!, lpAmount: amount! }),
    enabled,
  });
  return { data: (data ?? null) as QuoteV2 | null, isFetching, error: error as Error | null };
}
