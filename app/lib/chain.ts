import { baseSepolia, arcTestnet } from "@arcoralabs/dex-sdk/v2";
import type { Chain } from "viem";

/**
 * Single source of truth for the supported chains + their explorers.
 *
 * The app is MULTI-chain: both live V2 pools (Base Sepolia 84532 + Arc testnet
 * 5042002) run the SAME V2 contracts, switchable via the header chain switcher.
 * The "active" chain derives from the wallet's current chain (wagmi
 * `useChainId()` via `useActiveChain`), falling back to the default when
 * disconnected/unsupported.
 *
 * This module is intentionally framework-agnostic (no `"use client"`, no hooks)
 * so the server-side faucet route and tests can import the constants/helpers.
 * The reactive `useActiveChain()` / `useExplorer()` hooks live in
 * `lib/useActiveChain.ts`.
 */
export const SUPPORTED_CHAINS = [baseSepolia, arcTestnet] as const;
export type SupportedChainId = (typeof SUPPORTED_CHAINS)[number]["id"];

/** Default chain when the wallet is disconnected or on an unsupported network. */
export const DEFAULT_CHAIN: Chain = baseSepolia;

/** Per-chain explorer base URLs (no trailing slash). */
export const EXPLORERS: Record<number, string> = {
  [baseSepolia.id]: "https://sepolia.basescan.org",
  [arcTestnet.id]: "https://testnet.arcscan.app",
};

export function isSupportedChain(id: number | undefined): id is SupportedChainId {
  return id != null && SUPPORTED_CHAINS.some((c) => c.id === id);
}

/** Resolve a chain object from an id, falling back to the default. */
export function chainById(id: number | undefined): Chain {
  return SUPPORTED_CHAINS.find((c) => c.id === id) ?? DEFAULT_CHAIN;
}

/** Explorer base URL for a chain id, falling back to the default chain's. */
export function explorerFor(id: number | undefined): string {
  return EXPLORERS[id ?? DEFAULT_CHAIN.id] ?? EXPLORERS[DEFAULT_CHAIN.id]!;
}

/** `wallet_addEthereumChain` params for a given supported chain. */
export function addNetworkParams(chain: Chain) {
  return {
    chainId: "0x" + chain.id.toString(16),
    chainName: chain.name,
    nativeCurrency: chain.nativeCurrency,
    rpcUrls: chain.rpcUrls.default.http as readonly string[],
    blockExplorerUrls: [explorerFor(chain.id)],
  } as const;
}

// ---------------------------------------------------------------------------
// Back-compat / server-safe constants. These point at the DEFAULT chain and are
// for non-reactive contexts only (e.g. the faucet API route, which runs
// server-side and is chain-pinned). Client components that must follow the
// wallet should use `useActiveChain()` / `useExplorer()` from
// `lib/useActiveChain.ts` instead.
// ---------------------------------------------------------------------------
export const ACTIVE_CHAIN = DEFAULT_CHAIN;
export const EXPLORER =
  process.env.NEXT_PUBLIC_BLOCK_EXPLORER ?? EXPLORERS[DEFAULT_CHAIN.id]!;
