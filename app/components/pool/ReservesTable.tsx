"use client";
import { useQuery } from "@tanstack/react-query";
import { usePoolStats, useTokens, useArcoraDex } from "@arcoralabs/dex-sdk/react";
import { fmtUnits, fmtUSD } from "@arcoralabs/dex-sdk";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { TokenIcon } from "@/components/common/TokenIcon";

export function ReservesTable() {
  const sdk = useArcoraDex();
  const { tokens } = useTokens();
  const { stats } = usePoolStats({ refetchOnBlock: true });

  // M-10 (audit 2026-05-24): replaced the previous useEffect + setState data
  // fetch with TanStack Query so the reserves snapshot is cache-managed,
  // refetched whenever the on-block-updated NAV moves, and doesn't introduce
  // an extra render on mount. `stats?.navUsd1e18` in the queryKey naturally
  // invalidates the reserves read on every new block.
  const { data: reserves = {} } = useQuery({
    queryKey: ["arcora", "reserves", sdk.addresses.pool, stats?.navUsd1e18?.toString()],
    queryFn: () => sdk.getReserves(),
  });

  return (
    <Card>
      <CardHeader>
        <CardTitle>Pool reserves</CardTitle>
        <div className="text-right">
          <p className="t-label m-0">NAV</p>
          <p className="t-mono text-arc-ink-900 font-medium">
            {stats ? fmtUSD(stats.navUsd1e18) : "—"}
          </p>
        </div>
      </CardHeader>

      <div className="grid grid-cols-2 gap-6 mb-6">
        <div>
          <p className="t-label m-0">Total ADEX-LP</p>
          <p className="t-mono text-arc-ink-900 font-medium mt-1">
            {stats ? fmtUnits(stats.lpSupply, 18, 4) : "—"}
          </p>
        </div>
        <div>
          <p className="t-label m-0">Price (1 ADEX-LP)</p>
          <p className="t-mono text-arc-ink-900 font-medium mt-1">
            {stats ? fmtUSD(stats.lpPriceUsd1e18) : "—"}
          </p>
        </div>
      </div>

      <div className="overflow-x-auto -mx-6">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left border-b border-arc-ink-100">
              <th className="px-6 pb-2 t-label m-0">Token</th>
              <th className="px-6 pb-2 t-label m-0 text-right">Reserve</th>
              <th className="px-6 pb-2 t-label m-0 text-right">Status</th>
              <th className="px-6 pb-2 t-label m-0 text-right">Deviation</th>
            </tr>
          </thead>
          <tbody>
            {tokens.map((t) => {
              const reserve = reserves[t.address] ?? 0n;
              return (
                <tr
                  key={t.address}
                  className="border-b border-arc-ink-100 last:border-0 hover:bg-arc-ink-25 transition-colors"
                >
                  <td className="px-6 py-3">
                    <div className="flex items-center gap-2.5">
                      <TokenIcon symbol={t.symbol} size={24} />
                      <div>
                        <div className="font-medium text-arc-ink-900">{t.symbol}</div>
                        <div className="text-xs text-arc-ink-500">{t.name}</div>
                      </div>
                    </div>
                  </td>
                  <td className="px-6 py-3 text-right t-mono text-arc-ink-900">
                    {fmtUnits(reserve, t.decimals, 2)}
                  </td>
                  <td className="px-6 py-3 text-right">
                    {t.isActive ? (
                      <span
                        className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium"
                        style={{ background: "var(--arc-teal-50, #e6fbf6)", color: "var(--arc-teal-700)" }}
                      >
                        Active
                      </span>
                    ) : (
                      <span
                        className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium"
                        style={{ background: "#fee2e2", color: "var(--color-danger)" }}
                      >
                        Paused
                      </span>
                    )}
                  </td>
                  <td className="px-6 py-3 text-right text-arc-ink-500 t-mono">
                    {t.maxOracleDeviationBps} bps
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Card>
  );
}
