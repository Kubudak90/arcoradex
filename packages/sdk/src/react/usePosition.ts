"use client";
import { useQuery } from "@tanstack/react-query";
import { useAccount } from "wagmi";
import { useArcoraDex } from "./useArcoraDex";
import type { UserPosition } from "../types";

export interface UsePositionResult {
  position: UserPosition | null;
  isLoading: boolean;
  error: Error | null;
}

export function usePosition(addr?: `0x${string}`): UsePositionResult {
  const sdk = useArcoraDex();
  const { address: connectedAddr } = useAccount();
  const target = addr ?? connectedAddr;

  const { data, isLoading, error } = useQuery({
    queryKey: ["arcora", "position", sdk.chain.id, target],
    queryFn: () => sdk.getPosition(target!),
    enabled: !!target,
  });

  return { position: data ?? null, isLoading, error: error as Error | null };
}
