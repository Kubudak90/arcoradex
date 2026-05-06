"use client";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { lpAbi } from "@/lib/abi/lp";
import { poolAbi } from "@/lib/abi/pool";
import { POOL_ADDRESS, LP_ADDRESS } from "@/lib/contracts";
import { fmtUnits, fmtUSD } from "@/lib/format";

export function PositionPanel() {
  const { address: account } = useAccount();

  const { data, isLoading } = useReadContracts({
    contracts: [
      { address: LP_ADDRESS, abi: lpAbi, functionName: "totalSupply" },
      { address: POOL_ADDRESS, abi: poolAbi, functionName: "totalReservesUSD" },
      { address: LP_ADDRESS, abi: lpAbi, functionName: "balanceOf", args: account ? [account] : undefined },
    ],
    query: { enabled: !!account },
  });

  const supply = data?.[0]?.status === "success" ? (data[0].result as bigint) : 0n;
  const nav = data?.[1]?.status === "success" ? (data[1].result as bigint) : 0n;
  const lpBal = data?.[2]?.status === "success" ? (data[2].result as bigint) : 0n;

  const userUsd = supply > 0n ? (lpBal * nav) / supply : 0n;
  const lpPriceUsd = supply > 0n ? (nav * 10n ** 18n) / supply : 0n;

  if (!account) return null;
  if (isLoading) {
    return (
      <Card>
        <p className="text-sm text-fg-muted">Loading position…</p>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Your position</CardTitle>
      </CardHeader>
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-6 text-sm">
        <div>
          <p className="text-xs text-fg-muted uppercase tracking-wide">Your ADEX-LP</p>
          <p className="text-xl font-semibold">{fmtUnits(lpBal, 18, 4)}</p>
        </div>
        <div>
          <p className="text-xs text-fg-muted uppercase tracking-wide">Position value</p>
          <p className="text-xl font-semibold">{fmtUSD(userUsd)}</p>
        </div>
        <div>
          <p className="text-xs text-fg-muted uppercase tracking-wide">1 ADEX-LP</p>
          <p className="text-xl font-semibold">{fmtUSD(lpPriceUsd)}</p>
        </div>
      </div>
    </Card>
  );
}
