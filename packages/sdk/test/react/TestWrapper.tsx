"use client";
import { type ReactNode, useState } from "react";
import { WagmiProvider, createConfig, http } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { mock } from "wagmi/connectors";
import { privateKeyToAccount } from "viem/accounts";
import { ArcoraDexProvider } from "@/react/ArcoraDexProvider";
import { arcTestnet } from "@/chains/arcTestnet";
import type { ArcoraDexAddresses } from "@/addresses";

const ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

export function makeTestWrapper(rpcUrl: string, addresses: ArcoraDexAddresses) {
  const account = privateKeyToAccount(ANVIL_KEY);
  const config = createConfig({
    chains: [arcTestnet],
    transports: { [arcTestnet.id]: http(rpcUrl) },
    connectors: [mock({ accounts: [account.address] })],
  });

  return function TestWrapper({ children }: { children: ReactNode }) {
    const [qc] = useState(
      () => new QueryClient({ defaultOptions: { queries: { retry: false } } }),
    );
    return (
      <WagmiProvider config={config}>
        <QueryClientProvider client={qc}>
          <ArcoraDexProvider chain={arcTestnet} addresses={addresses}>
            {children}
          </ArcoraDexProvider>
        </QueryClientProvider>
      </WagmiProvider>
    );
  };
}
