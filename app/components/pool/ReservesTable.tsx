"use client";
import { useEffect, useState } from "react";
import { usePoolStats, useTokens, useArcoraDex } from "@arcoralabs/dex-sdk/react";
import { fmtUnits, fmtUSD } from "@arcoralabs/dex-sdk";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";

export function ReservesTable() {
  const sdk = useArcoraDex();
  const { tokens } = useTokens();
  const { stats } = usePoolStats({ refetchOnBlock: true });
  const [reserves, setReserves] = useState<Record<`0x${string}`, bigint>>({});

  useEffect(() => {
    let cancelled = false;
    sdk.getReserves().then((r) => {
      if (!cancelled) setReserves(r);
    });
    return () => {
      cancelled = true;
    };
  }, [sdk, stats?.navUsd1e18]);

  return (
    <Card>
      <CardHeader>
        <CardTitle>Pool reserves</CardTitle>
        <div className="text-right text-sm">
          <p className="text-fg-muted text-xs uppercase">NAV</p>
          <p className="font-semibold">{stats ? fmtUSD(stats.navUsd1e18) : "—"}</p>
        </div>
      </CardHeader>

      <div className="grid grid-cols-2 gap-6 mb-6 text-sm">
        <div>
          <p className="text-xs text-fg-muted uppercase">Total ADEX-LP</p>
          <p className="font-semibold">{stats ? fmtUnits(stats.lpSupply, 18, 4) : "—"}</p>
        </div>
        <div>
          <p className="text-xs text-fg-muted uppercase">Price (1 ADEX-LP)</p>
          <p className="font-semibold">{stats ? fmtUSD(stats.lpPriceUsd1e18) : "—"}</p>
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
            {tokens.map((t) => {
              const reserve = reserves[t.address] ?? 0n;
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
                  <td className="py-2 text-right text-fg-muted">{t.maxOracleDeviationBps} bps</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Card>
  );
}
