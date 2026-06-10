import { http, createConfig, fallback } from "wagmi";
import { injected, walletConnect } from "wagmi/connectors";
import { baseSepolia } from "@arcoralabs/dex-sdk/v2";

// The app is the universal shell pointed at Base Sepolia (84532) — the live V2
// ledger. We use the SDK's canonical `baseSepolia` definition (rather than a
// duplicate `defineChain`) so the app and the V2 provider/SDK agree on the
// chain id, RPC default, and explorer for every wallet/chain-id check.
//
// The env-overridable RPC URL is honoured by applying it to the wagmi
// transport; it falls back to the SDK chain's default RPC.

const RPC_URL =
  process.env.NEXT_PUBLIC_RPC_URL || baseSepolia.rpcUrls.default.http[0];

const WC_PROJECT_ID = process.env.NEXT_PUBLIC_WC_PROJECT_ID || "";

export const wagmiConfig = createConfig({
  chains: [baseSepolia],
  transports: {
    [baseSepolia.id]: fallback([http(RPC_URL)]),
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
