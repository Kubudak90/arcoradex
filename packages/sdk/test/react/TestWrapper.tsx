"use client";
import { type ReactNode, useEffect, useState } from "react";
import { WagmiProvider, createConfig, http, useConnect } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { mock } from "wagmi/connectors";
import { privateKeyToAccount } from "viem/accounts";
import { ArcoraDexProvider } from "@/react/ArcoraDexProvider";
import { arcTestnet } from "@/chains/arcTestnet";
import type { ArcoraDexAddresses } from "@/addresses";

const ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

/** A chain alias whose default RPC URL points at the test anvil instance.
 *  The wagmi mock connector forwards `eth_sendTransaction` to
 *  `chain.rpcUrls.default.http[0]`, so we override it here so writes hit
 *  the local anvil (which has the test account unlocked) rather than the
 *  real testnet RPC defined in src/chains/arcTestnet.ts. */
function makeAnvilChain(rpcUrl: string) {
  return { ...arcTestnet, rpcUrls: { default: { http: [rpcUrl] } } } as typeof arcTestnet;
}

function makeConfigAndChain(rpcUrl: string) {
  const account = privateKeyToAccount(ANVIL_KEY);
  const chain = makeAnvilChain(rpcUrl);
  const config = createConfig({
    chains: [chain],
    transports: { [chain.id]: http(rpcUrl) },
    connectors: [mock({ accounts: [account.address] })],
  });
  return { config, chain };
}

export function makeTestWrapper(rpcUrl: string, addresses: ArcoraDexAddresses) {
  const { config, chain } = makeConfigAndChain(rpcUrl);
  return function TestWrapper({ children }: { children: ReactNode }) {
    const [qc] = useState(
      () => new QueryClient({ defaultOptions: { queries: { retry: false } } }),
    );
    return (
      <WagmiProvider config={config}>
        <QueryClientProvider client={qc}>
          <ArcoraDexProvider chain={chain} addresses={addresses}>
            {children}
          </ArcoraDexProvider>
        </QueryClientProvider>
      </WagmiProvider>
    );
  };
}

/** Same as makeTestWrapper but auto-connects the wagmi mock connector on mount,
 *  so write hooks (useSwap/useDeposit/useWithdraw) have a live walletClient. */
export function makeConnectedTestWrapper(rpcUrl: string, addresses: ArcoraDexAddresses) {
  const { config, chain } = makeConfigAndChain(rpcUrl);

  function AutoConnect({ children }: { children: ReactNode }) {
    const { connect, connectors } = useConnect();
    useEffect(() => {
      const c = connectors[0];
      if (c) connect({ connector: c });
    }, [connect, connectors]);
    return <>{children}</>;
  }

  return function ConnectedTestWrapper({ children }: { children: ReactNode }) {
    const [qc] = useState(
      () => new QueryClient({ defaultOptions: { queries: { retry: false } } }),
    );
    return (
      <WagmiProvider config={config}>
        <QueryClientProvider client={qc}>
          <AutoConnect>
            <ArcoraDexProvider chain={chain} addresses={addresses}>
              {children}
            </ArcoraDexProvider>
          </AutoConnect>
        </QueryClientProvider>
      </WagmiProvider>
    );
  };
}
