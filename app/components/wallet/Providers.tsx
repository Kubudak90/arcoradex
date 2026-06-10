"use client";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import { ArcoraDexProvider } from "@arcoralabs/dex-sdk/react";
import { ArcoraDexV2Provider } from "@arcoralabs/dex-sdk/react/v2";
import { DEFAULT_ADDRESSES_V2 } from "@arcoralabs/dex-sdk/v2";
import { wagmiConfig } from "@/lib/wagmi";
import { ACTIVE_CHAIN } from "@/lib/chain";

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());
  // The V2 provider defaults chain=baseSepolia + DEFAULT_ADDRESSES_V2, so no
  // props are needed — the app is the universal Base Sepolia (84532) shell.
  //
  // The V1 ArcoraDexProvider is kept nested only transitionally: the old
  // Arc-blue pages still consume V1 hooks (useArcoraDex/useTokens/usePoolStats)
  // and are not removed until the page-rewire tasks. It is pinned to
  // ACTIVE_CHAIN — with the V2 address set (which reuses the V1 {pool,registry,
  // lp} shape) so the V1 sdk has valid addresses for chainId 84532 — so its
  // usePublicClient call resolves against the (now baseSepolia-only) wagmi
  // config and the sdk constructs without throwing during prerender. Once those
  // pages are deleted this nesting goes with them, leaving the V2 provider
  // alone.
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <ArcoraDexV2Provider>
          <ArcoraDexProvider
            chain={ACTIVE_CHAIN}
            addresses={DEFAULT_ADDRESSES_V2[ACTIVE_CHAIN.id]}
          >
            {children}
          </ArcoraDexProvider>
        </ArcoraDexV2Provider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
