"use client";
import { useMemo } from "react";
import { useAccount, useReadContract } from "wagmi";
import { erc20Abi } from "viem";
import { useArcoraDexV2 } from "@arcoralabs/dex-sdk/react/v2";
import type { PoolStatsV2 } from "@arcoralabs/dex-sdk/v2";

export interface LpPosition {
  /** Raw LP balance (18-dp LP token). null until the wallet read resolves. */
  balance: bigint | null;
  /** USD value of the position = lpPriceUsd1e18 × balance / 1e18 (1e18-scaled). */
  valueUsd1e18: bigint | null;
  /** Pool share = balance / lpSupply, as a fraction in [0,1]. */
  share: number | null;
  isConnected: boolean;
}

/**
 * GF-3: the connected wallet's LP balance + USD value + pool share.
 *
 * Drives the withdraw "Max" and the "Your position" card. Reads `balanceOf` on
 * the LP token (from `sdk.addresses.lp`); value/share derive from the supplied
 * pool stats (`lpPriceUsd1e18`, `lpSupply`) so it leans on the existing
 * `usePoolStatsV2` query rather than duplicating it.
 */
export function useLpPosition(stats: PoolStatsV2 | null): LpPosition {
  const sdk = useArcoraDexV2();
  const { address: account, isConnected } = useAccount();

  const { data: balance } = useReadContract({
    address: sdk.addresses.lp,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!account },
  });

  return useMemo(() => {
    const bal = (balance ?? null) as bigint | null;
    if (bal == null || stats == null) {
      return { balance: bal, valueUsd1e18: null, share: null, isConnected };
    }
    const valueUsd1e18 = (stats.lpPriceUsd1e18 * bal) / 10n ** 18n;
    const share = stats.lpSupply === 0n ? 0 : Number(bal) / Number(stats.lpSupply);
    return { balance: bal, valueUsd1e18, share, isConnected };
  }, [balance, stats, isConnected]);
}
