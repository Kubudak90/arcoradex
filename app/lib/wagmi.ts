import { http, createConfig, fallback } from "wagmi";
import { injected, walletConnect } from "wagmi/connectors";
import { baseSepolia, arcTestnet } from "@arcoralabs/dex-sdk/v2";

// The app is MULTI-chain: both live V2 pools run the SAME V2 contracts, so the
// wallet can switch between Base Sepolia (84532) and Arc testnet (5042002) via
// the header chain switcher. We use the SDK's canonical chain definitions
// (rather than duplicate `defineChain`s) so the app and the V2 provider/SDK
// agree on chain id, RPC default, and explorer for every wallet/chain-id check.
//
// Per-chain RPCs are env-overridable; each falls back to the SDK chain default.
const BASE_RPC =
  process.env.NEXT_PUBLIC_RPC_URL || baseSepolia.rpcUrls.default.http[0];
const ARC_RPC =
  process.env.NEXT_PUBLIC_ARC_RPC_URL || arcTestnet.rpcUrls.default.http[0];

const WC_PROJECT_ID = process.env.NEXT_PUBLIC_WC_PROJECT_ID || "";

export const wagmiConfig = createConfig({
  chains: [baseSepolia, arcTestnet],
  transports: {
    [baseSepolia.id]: fallback([http(BASE_RPC)]),
    [arcTestnet.id]: fallback([http(ARC_RPC)]),
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
