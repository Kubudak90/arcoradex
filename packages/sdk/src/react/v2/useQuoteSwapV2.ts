"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "./useArcoraDexV2";
import { useDebouncedValue } from "../useDebouncedValue";
import type { QuoteV2 } from "../../types.v2";

export function useQuoteSwapV2(
  args: { tokenIn?: `0x${string}`; tokenOut?: `0x${string}`; amountIn?: bigint },
  options?: { debounceMs?: number; enabled?: boolean },
) {
  const sdk = useArcoraDexV2();
  const amount = useDebouncedValue(args.amountIn, options?.debounceMs ?? 400);
  const enabled =
    (options?.enabled ?? true) && !!args.tokenIn && !!args.tokenOut &&
    args.tokenIn !== args.tokenOut && !!amount && amount > 0n;
  const { data, isFetching, error } = useQuery({
    queryKey: ["arcora", "v2", "quoteSwap", sdk.chain.id, args.tokenIn, args.tokenOut, amount?.toString()],
    queryFn: () => sdk.quoteSwapV2({ tokenIn: args.tokenIn!, tokenOut: args.tokenOut!, amountIn: amount! }),
    enabled,
  });
  return { data: (data ?? null) as QuoteV2 | null, isFetching, error: error as Error | null };
}
