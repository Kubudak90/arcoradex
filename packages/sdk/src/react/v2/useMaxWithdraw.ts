"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "./useArcoraDexV2";
import type { MaxWithdraw } from "../../types.v2";

export function useMaxWithdraw(
  args: { tokenOut?: `0x${string}`; account?: `0x${string}` },
  options?: { enabled?: boolean },
) {
  const sdk = useArcoraDexV2();
  const enabled = (options?.enabled ?? true) && !!args.tokenOut && !!args.account;
  const { data, isFetching, error } = useQuery({
    queryKey: ["arcora", "v2", "maxWithdraw", sdk.chain.id, args.tokenOut, args.account],
    queryFn: () => sdk.maxWithdraw(args.tokenOut!, args.account!),
    enabled,
  });
  return { data: (data ?? null) as MaxWithdraw | null, isFetching, error: error as Error | null };
}
