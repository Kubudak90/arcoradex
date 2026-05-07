"use client";
import { createContext, useContext, useMemo, type ReactNode } from "react";
import { useAccount, useChainId, usePublicClient, useWalletClient } from "wagmi";
import { custom, type Chain } from "viem";
import { createArcoraDex, type ArcoraDexClient } from "../client";
import { arcTestnet } from "../chains/arcTestnet";
import type { ArcoraDexAddresses } from "../addresses";

const ArcoraDexCtx = createContext<ArcoraDexClient | null>(null);

export interface ArcoraDexProviderProps {
  chain?: Chain;
  addresses?: ArcoraDexAddresses;
  children: ReactNode;
}

export function ArcoraDexProvider({ chain, addresses, children }: ArcoraDexProviderProps) {
  const wagmiChainId = useChainId();
  const effectiveChain: Chain = chain ?? arcTestnet;
  // useAccount is read for parity with the `wagmiChainId` dep — write hooks key off walletClient.
  useAccount();
  // Cast through `any` because wagmi's `Register` may narrow `chainId` to a literal
  // union in the consumer app, while we intentionally accept any `Chain.id: number`.
  const chainId = effectiveChain.id as never;
  const publicClient = usePublicClient({ chainId });
  const { data: walletClient } = useWalletClient({ chainId });

  const sdk = useMemo<ArcoraDexClient | null>(() => {
    if (!publicClient) return null;
    // Derive a transport that delegates to wagmi's publicClient for read calls.
    // For writes, we hand wagmi's walletClient through unchanged so its
    // connector-backed transport handles signing.
    const transport = custom(publicClient);
    return createArcoraDex({
      chain: effectiveChain,
      transport,
      walletClient: walletClient ?? undefined,
      addresses,
    });
  }, [effectiveChain, publicClient, walletClient, addresses, wagmiChainId]);

  return <ArcoraDexCtx.Provider value={sdk}>{children}</ArcoraDexCtx.Provider>;
}

export function useArcoraDexContext(): ArcoraDexClient | null {
  return useContext(ArcoraDexCtx);
}
