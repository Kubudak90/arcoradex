import { http, createConfig, fallback } from "wagmi";
import { injected, walletConnect } from "wagmi/connectors";
import { arcTestnet } from "@arcoralabs/dex-sdk";

// H-5 (audit 2026-05-24): use the SDK's canonical arcTestnet definition
// rather than redefining it here. Two parallel `defineChain` calls were
// drifting (nativeCurrency, blockExplorer) and forcing every wallet
// component to pick between the SDK and the app for chain-id checks.
// The env-overridable RPC URL is still honoured — it's applied to the
// wagmi transport rather than to a duplicate chain object.

const RPC_URL =
  process.env.NEXT_PUBLIC_RPC_URL || arcTestnet.rpcUrls.default.http[0];

const WC_PROJECT_ID = process.env.NEXT_PUBLIC_WC_PROJECT_ID || "";

export const wagmiConfig = createConfig({
  chains: [arcTestnet],
  transports: {
    [arcTestnet.id]: fallback([http(RPC_URL)]),
  },
  connectors: [
    injected({ shimDisconnect: true }),
    ...(WC_PROJECT_ID
      ? [walletConnect({ projectId: WC_PROJECT_ID, showQrModal: true })]
      : []),
  ],
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
