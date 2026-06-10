"use client";
import { type ReactNode, useEffect, useState } from "react";
import { WagmiProvider, createConfig, http, useConnect } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { mock } from "wagmi/connectors";
import { privateKeyToAccount } from "viem/accounts";
import { ArcoraDexV2Provider } from "@/react/v2/ArcoraDexV2Provider";
import { baseSepolia } from "@/chains/baseSepolia";
import type { ArcoraDexAddresses } from "@/addresses";

const ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

/** A baseSepolia alias whose default RPC URL points at the test anvil instance.
 *  The wagmi mock connector forwards `eth_sendTransaction` to
 *  `chain.rpcUrls.default.http[0]`, so we override it here so reads/writes hit
 *  the local anvil (which has the test account unlocked) rather than the real
 *  Base Sepolia RPC defined in src/chains/baseSepolia.ts. Note: the anvil
 *  fixture deploys V1 contracts only (the V2 anvil fixture is deferred — see
 *  the Task 9 note), so these wrapper-backed tests exercise provider wiring and
 *  the hooks' enabled-guard paths, NOT live V2 contract reads. The live V2
 *  contract surface is covered by test/integration/v2/addresses-live-v2.test.ts. */
function makeAnvilChain(rpcUrl: string) {
  return { ...baseSepolia, rpcUrls: { default: { http: [rpcUrl] } } } as typeof baseSepolia;
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

export function makeTestWrapperV2(rpcUrl: string, addresses: ArcoraDexAddresses) {
  const { config, chain } = makeConfigAndChain(rpcUrl);
  return function TestWrapperV2({ children }: { children: ReactNode }) {
    const [qc] = useState(
      () => new QueryClient({ defaultOptions: { queries: { retry: false } } }),
    );
    return (
      <WagmiProvider config={config}>
        <QueryClientProvider client={qc}>
          <ArcoraDexV2Provider chain={chain} addresses={addresses}>
            {children}
          </ArcoraDexV2Provider>
        </QueryClientProvider>
      </WagmiProvider>
    );
  };
}

/** Same as makeTestWrapperV2 but auto-connects the wagmi mock connector on mount,
 *  so write hooks (useSwapV2/useDepositV2/…) have a live walletClient. */
export function makeConnectedTestWrapperV2(rpcUrl: string, addresses: ArcoraDexAddresses) {
  const { config, chain } = makeConfigAndChain(rpcUrl);

  function AutoConnect({ children }: { children: ReactNode }) {
    const { connect, connectors } = useConnect();
    useEffect(() => {
      const c = connectors[0];
      if (c) connect({ connector: c });
    }, [connect, connectors]);
    return <>{children}</>;
  }

  return function ConnectedTestWrapperV2({ children }: { children: ReactNode }) {
    const [qc] = useState(
      () => new QueryClient({ defaultOptions: { queries: { retry: false } } }),
    );
    return (
      <WagmiProvider config={config}>
        <QueryClientProvider client={qc}>
          <AutoConnect>
            <ArcoraDexV2Provider chain={chain} addresses={addresses}>
              {children}
            </ArcoraDexV2Provider>
          </AutoConnect>
        </QueryClientProvider>
      </WagmiProvider>
    );
  };
}
