"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "./useArcoraDexV2";
import type { MaxSwapOut } from "../../types.v2";

export function useMaxSwapOut(
  args: { tokenOut?: `0x${string}` },
  options?: { enabled?: boolean },
) {
  const sdk = useArcoraDexV2();
  const enabled = (options?.enabled ?? true) && !!args.tokenOut;
  const { data, isFetching, error } = useQuery({
    queryKey: ["arcora", "v2", "maxSwapOut", sdk.chain.id, args.tokenOut],
    queryFn: () => sdk.maxSwapOut(args.tokenOut!),
    enabled,
  });
  return { data: (data ?? null) as MaxSwapOut | null, isFetching, error: error as Error | null };
}
