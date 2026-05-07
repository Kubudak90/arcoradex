"use client";
import { createContext, useContext, useMemo, type ReactNode } from "react";
import { useAccount, useChainId, useConnectorClient, usePublicClient } from "wagmi";
import { createWalletClient, custom, walletActions, type Chain, type WalletClient } from "viem";
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
  const { address, isConnected } = useAccount();
  // Cast through `never` because wagmi's `Register` may narrow `chainId` to a
  // literal union in the consumer app, while we intentionally accept any
  // `Chain.id: number`.
  const chainId = effectiveChain.id as never;
  const publicClient = usePublicClient({ chainId });
  // useConnectorClient is wagmi's recommended hook for write operations — it
  // returns the connector's actual viem client (with the wallet's signing
  // transport), regardless of which chain the wallet currently reports.
  const { data: connectorClient } = useConnectorClient({ chainId });

  const sdk = useMemo<ArcoraDexClient | null>(() => {
    if (!publicClient) return null;
    // Read transport: delegate to wagmi's publicClient — simpler than reconfiguring.
    const transport = custom(publicClient);

    // The connector client is a base viem Client; extend it with walletActions
    // so writeContract/sendTransaction become available. Its transport already
    // points at the wallet's EIP-1193 provider, so signing flows correctly.
    // If wagmi hasn't surfaced the connector client yet, fall back to the
    // page's injected provider so a freshly hydrated page doesn't gate the
    // user out of swap/deposit/withdraw.
    let walletClient: WalletClient | undefined;
    if (connectorClient) {
      walletClient = connectorClient.extend(walletActions) as unknown as WalletClient;
    } else if (
      isConnected &&
      address &&
      typeof window !== "undefined" &&
      (window as unknown as { ethereum?: unknown }).ethereum
    ) {
      walletClient = createWalletClient({
        account: address,
        chain: effectiveChain,
        transport: custom((window as unknown as { ethereum: unknown }).ethereum as never),
      });
    }

    return createArcoraDex({
      chain: effectiveChain,
      transport,
      walletClient,
      addresses,
    });
  }, [effectiveChain, publicClient, connectorClient, isConnected, address, addresses, wagmiChainId]);

  return <ArcoraDexCtx.Provider value={sdk}>{children}</ArcoraDexCtx.Provider>;
}

export function useArcoraDexContext(): ArcoraDexClient | null {
  return useContext(ArcoraDexCtx);
}
