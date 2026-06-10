"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "./useArcoraDexV2";
import type { ReserveHealth } from "../../types.v2";

export function useReserveHealth(
  args: { tokenOut?: `0x${string}` },
  options?: { enabled?: boolean },
) {
  const sdk = useArcoraDexV2();
  const enabled = (options?.enabled ?? true) && !!args.tokenOut;
  const { data, isFetching, error } = useQuery({
    queryKey: ["arcora", "v2", "reserveHealth", sdk.chain.id, args.tokenOut],
    queryFn: () => sdk.reserveHealth(args.tokenOut!),
    enabled,
  });
  return { data: (data ?? null) as ReserveHealth | null, isFetching, error: error as Error | null };
}
