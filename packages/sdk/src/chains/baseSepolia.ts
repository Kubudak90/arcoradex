import { defineChain } from "viem";

/**
 * Base Sepolia (chainId 84532) — the live V2 integration target.
 * Default RPC is the reliable publicnode endpoint: the deploy note
 * (docs/rollouts/2026-06-10-base-sepolia-v2-deploy.md) flagged heavy
 * read-after-write lag on the public `sepolia.base.org`, so reads default to
 * `base-sepolia-rpc.publicnode.com`. The app may override via env.
 */
export const baseSepolia = /*#__PURE__*/ defineChain({
  id: 84532,
  name: "Base Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://base-sepolia-rpc.publicnode.com"] },
  },
  blockExplorers: {
    default: { name: "BaseScan", url: "https://sepolia.basescan.org" },
  },
  testnet: true,
});
