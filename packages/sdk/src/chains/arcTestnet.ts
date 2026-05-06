import { defineChain } from "viem";

export const arcTestnet = /*#__PURE__*/ defineChain({
  id: 5042002,
  name: "Arc Testnet",
  nativeCurrency: { name: "USD Coin", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.testnet.arc.network"] } },
  blockExplorers: {
    default: { name: "Arc Explorer", url: "https://testnet.arcscan.app" },
  },
  testnet: true,
});
