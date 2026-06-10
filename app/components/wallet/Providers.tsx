"use client";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import { ArcoraDexV2Provider } from "@arcoralabs/dex-sdk/react/v2";
import { wagmiConfig } from "@/lib/wagmi";

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());
  // The V2 provider defaults chain=baseSepolia + DEFAULT_ADDRESSES_V2, so no
  // props are needed — the app is the universal Base Sepolia (84532) shell.
  // The old V1 ArcoraDexProvider was removed with the Arc-blue UI (Task 12);
  // every page now consumes the V2 hooks only.
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <ArcoraDexV2Provider>{children}</ArcoraDexV2Provider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
