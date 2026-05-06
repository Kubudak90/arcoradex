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
  const publicClient = usePublicClient({ chainId: effectiveChain.id });
  const { data: walletClient } = useWalletClient({ chainId: effectiveChain.id });

  const sdk = useMemo<ArcoraDexClient | null>(() => {
    if (!publicClient) return null;
    // Derive a transport that delegates to wagmi's publicClient — simpler than reconfiguring.
    const transport = custom(publicClient);
    return createArcoraDex({
      chain: effectiveChain,
      transport,
      account: walletClient?.account,
      addresses,
    });
  }, [effectiveChain, publicClient, walletClient, addresses, wagmiChainId]);

  return <ArcoraDexCtx.Provider value={sdk}>{children}</ArcoraDexCtx.Provider>;
}

export function useArcoraDexContext(): ArcoraDexClient | null {
  return useContext(ArcoraDexCtx);
}
