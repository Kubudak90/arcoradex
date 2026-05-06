"use client";
import { useReadContract, useReadContracts } from "wagmi";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { useTokens } from "@/lib/hooks/useTokens";
import { poolAbi } from "@/lib/abi/pool";
import { lpAbi } from "@/lib/abi/lp";
import { POOL_ADDRESS, LP_ADDRESS } from "@/lib/contracts";
import { fmtUnits, fmtUSD } from "@/lib/format";

export function ReservesTable() {
  const { tokens } = useTokens();

  const { data: nav } = useReadContract({
    address: POOL_ADDRESS,
    abi: poolAbi,
    functionName: "totalReservesUSD",
  });
  const { data: supply } = useReadContract({
    address: LP_ADDRESS,
    abi: lpAbi,
    functionName: "totalSupply",
  });

  const { data: reservesData } = useReadContracts({
    contracts: tokens.map((t) => ({
      address: POOL_ADDRESS,
      abi: poolAbi,
      functionName: "reserves" as const,
      args: [t.address] as const,
    })),
    query: { enabled: tokens.length > 0 },
  });

  const navUsd = (nav as bigint) ?? 0n;
  const lpSupply = (supply as bigint) ?? 0n;
  const lpPriceUsd = lpSupply > 0n ? (navUsd * 10n ** 18n) / lpSupply : 0n;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Pool reserves</CardTitle>
        <div className="text-right text-sm">
          <p className="text-fg-muted text-xs uppercase">NAV</p>
          <p className="font-semibold">{fmtUSD(navUsd)}</p>
        </div>
      </CardHeader>

      <div className="grid grid-cols-2 gap-6 mb-6 text-sm">
        <div>
          <p className="text-xs text-fg-muted uppercase">Total ADEX-LP</p>
          <p className="font-semibold">{fmtUnits(lpSupply, 18, 4)}</p>
        </div>
        <div>
          <p className="text-xs text-fg-muted uppercase">Price (1 ADEX-LP)</p>
          <p className="font-semibold">{fmtUSD(lpPriceUsd)}</p>
        </div>
      </div>

      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase text-fg-muted border-b border-border">
              <th className="pb-2">Token</th>
              <th className="pb-2 text-right">Reserve</th>
              <th className="pb-2 text-right">Status</th>
              <th className="pb-2 text-right">Deviation</th>
            </tr>
          </thead>
          <tbody>
            {tokens.map((t, i) => {
              const reserve = reservesData?.[i]?.status === "success" ? (reservesData[i].result as bigint) : 0n;
              return (
                <tr key={t.address} className="border-b border-border last:border-0">
                  <td className="py-2">
                    <span className="font-medium">{t.symbol}</span>{" "}
                    <span className="text-fg-muted text-xs">{t.name}</span>
                  </td>
                  <td className="py-2 text-right font-mono">
                    {fmtUnits(reserve, t.decimals, 2)}
                  </td>
                  <td className="py-2 text-right">
                    {t.isActive ? (
                      <span className="text-success">Active</span>
                    ) : (
                      <span className="text-danger">Paused</span>
                    )}
                  </td>
                  <td className="py-2 text-right text-fg-muted">{t.deviationBps} bps</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Card>
  );
}
