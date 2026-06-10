"use client";
import { useChainId } from "wagmi";
import type { Chain } from "viem";
import { chainById, explorerFor, isSupportedChain } from "@/lib/chain";

/**
 * Reactive active chain — the wallet's current chain when supported, else the
 * default. Client components use this so swap/liquidity/pool, explorer links,
 * and wrong-chain prompts all track whichever chain the wallet is on.
 */
export function useActiveChain(): Chain {
  const chainId = useChainId();
  return chainById(chainId);
}

/** Reactive explorer base URL for the active chain. */
export function useExplorer(): string {
  const chainId = useChainId();
  return explorerFor(chainId);
}

/** True when the connected wallet is on a chain the app supports. */
export function useIsSupportedChain(): boolean {
  const chainId = useChainId();
  return isSupportedChain(chainId);
}
