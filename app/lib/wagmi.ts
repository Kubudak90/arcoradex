import { http, createConfig, fallback } from "wagmi";
import { defineChain } from "viem";
import { injected, walletConnect } from "wagmi/connectors";

const RPC_URL =
  process.env.NEXT_PUBLIC_RPC_URL || "https://rpc.testnet.arc.network";

const EXPLORER_URL =
  process.env.NEXT_PUBLIC_BLOCK_EXPLORER || "https://testnet.arcscan.app";

const WC_PROJECT_ID = process.env.NEXT_PUBLIC_WC_PROJECT_ID || "";

export const arcTestnet = defineChain({
  id: 5042002,
  name: "Arc Testnet",
  nativeCurrency: { name: "USD Coin", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: {
    default: { name: "Arc Explorer", url: EXPLORER_URL },
  },
  testnet: true,
});

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
