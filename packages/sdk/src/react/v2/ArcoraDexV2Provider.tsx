"use client";
import { createContext, useContext, useMemo, type ReactNode } from "react";
import { useAccount, useChainId, useConnectorClient, usePublicClient } from "wagmi";
import { createWalletClient, custom, walletActions, type Chain, type WalletClient } from "viem";
import { createArcoraDexV2, type ArcoraDexClientV2 } from "../../clientV2";
import { baseSepolia } from "../../chains/baseSepolia";
import { arcTestnet } from "../../chains/arcTestnet";
import { DEFAULT_ADDRESSES_V2 } from "../../addresses.v2";
import type { ArcoraDexAddresses } from "../../addresses";

const ArcoraDexV2Ctx = createContext<ArcoraDexClientV2 | null>(null);

export interface ArcoraDexV2ProviderProps {
  /** Pin the V2 client to a specific chain. When omitted, the provider is
   *  chain-REACTIVE: it follows the wallet's current chain (`useChainId()`)
   *  across every chain that has a V2 deployment, falling back to Base Sepolia
   *  when the wallet is disconnected or on an unsupported chain. */
  chain?: Chain;
  addresses?: ArcoraDexAddresses;
  children: ReactNode;
}

/** Chains the V2 provider can build a client for, by id. Sourced from the same
 *  `DEFAULT_ADDRESSES_V2` map so a chain is only "supported" if it has live V2
 *  addresses. */
const V2_CHAINS: Record<number, Chain> = {
  [baseSepolia.id]: baseSepolia,
  [arcTestnet.id]: arcTestnet,
};

export function ArcoraDexV2Provider({ chain, addresses, children }: ArcoraDexV2ProviderProps) {
  const wagmiChainId = useChainId();
  // Chain-reactive resolution: an explicit `chain` prop always wins (test
  // wrappers / embedders pin it). Otherwise follow the wallet's current chain
  // when it has a V2 deployment, falling back to Base Sepolia.
  const effectiveChain: Chain =
    chain ??
    (DEFAULT_ADDRESSES_V2[wagmiChainId] ? V2_CHAINS[wagmiChainId] : undefined) ??
    baseSepolia;
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

  const sdk = useMemo<ArcoraDexClientV2 | null>(() => {
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

    return createArcoraDexV2({
      chain: effectiveChain,
      transport,
      walletClient,
      addresses,
    });
  }, [effectiveChain, publicClient, connectorClient, isConnected, address, addresses, wagmiChainId]);

  return <ArcoraDexV2Ctx.Provider value={sdk}>{children}</ArcoraDexV2Ctx.Provider>;
}

export function useArcoraDexV2Context(): ArcoraDexClientV2 | null {
  return useContext(ArcoraDexV2Ctx);
}
