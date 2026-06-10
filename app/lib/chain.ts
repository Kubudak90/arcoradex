import { baseSepolia } from "@arcoralabs/dex-sdk/v2";

/**
 * Single source of truth for the active chain + explorer. Imported by the
 * Header network chip, ConnectButton, and the Faucet so the chain id / explorer
 * URL / wallet_addEthereumChain params all live in one place.
 *
 * The app is the universal shell pointed at Base Sepolia (84532, the live V2
 * ledger) — there is no per-chain branching.
 */
export const ACTIVE_CHAIN = baseSepolia;

export const EXPLORER =
  process.env.NEXT_PUBLIC_BLOCK_EXPLORER ?? "https://sepolia.basescan.org";

/** Params for `wallet_addEthereumChain` (the "Add Base Sepolia" chip). */
export const ADD_NETWORK_PARAMS = {
  chainId: "0x" + baseSepolia.id.toString(16), // 0x14a34
  chainName: baseSepolia.name,
  nativeCurrency: baseSepolia.nativeCurrency,
  rpcUrls: baseSepolia.rpcUrls.default.http,
  blockExplorerUrls: [EXPLORER],
} as const;
