"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDex } from "./useArcoraDex";
import type { TokenInfo } from "../types";

export interface UseTokensResult {
  tokens: TokenInfo[];
  activeTokens: TokenInfo[];
  isLoading: boolean;
  error: Error | null;
}

export function useTokens(): UseTokensResult {
  const sdk = useArcoraDex();
  const { data, isLoading, error } = useQuery({
    queryKey: ["arcora", "tokens", sdk.chain.id, sdk.addresses.registry],
    queryFn: () => sdk.getTokens(),
  });
  const tokens = data ?? [];
  const activeTokens = tokens.filter((t) => t.isActive);
  return { tokens, activeTokens, isLoading, error: error as Error | null };
}
