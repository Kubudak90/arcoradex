"use client";
import { useMemo } from "react";
import { useSwapHistory, useTokens } from "@arcoralabs/dex-sdk/react";
import { fmtUnits, tokenLabel } from "@arcoralabs/dex-sdk";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { shortAddr } from "@/lib/utils";

const SCAN_LIMIT = 50;

export function SwapHistory() {
  const { tokens } = useTokens();
  const { events: rows, isLoading, error } = useSwapHistory({
    limit: SCAN_LIMIT,
    watch: true,
  });

  // address (lowercase) → decimals lookup so we can format raw event amounts correctly.
  const decimalsByAddr = useMemo(() => {
    const m = new Map<string, number>();
    for (const t of tokens) m.set(t.address.toLowerCase(), t.decimals);
    return m;
  }, [tokens]);
  const dec = (addr: string) => decimalsByAddr.get(addr.toLowerCase()) ?? 18;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Recent swaps</CardTitle>
        <span className="text-xs text-fg-muted">last {SCAN_LIMIT} swaps</span>
      </CardHeader>

      {error ? (
        <p className="text-sm text-danger">{error.message}</p>
      ) : isLoading ? (
        <p className="text-sm text-fg-muted">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-fg-muted">No swaps yet.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs uppercase text-fg-muted border-b border-border">
                <th className="pb-2">Trader</th>
                <th className="pb-2">In</th>
                <th className="pb-2">Out</th>
                <th className="pb-2 text-right">Tx</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const tIn = tokenLabel(r.tokenIn);
                const tOut = tokenLabel(r.tokenOut);
                return (
                  <tr
                    key={`${r.txHash}-${r.logIndex}`}
                    className="border-b border-border last:border-0"
                  >
                    <td className="py-2 font-mono text-xs">{shortAddr(r.user)}</td>
                    <td className="py-2">
                      {fmtUnits(r.amountIn, dec(r.tokenIn), 4)} {tIn.symbol}
                    </td>
                    <td className="py-2">
                      {fmtUnits(r.amountOut, dec(r.tokenOut), 4)} {tOut.symbol}
                    </td>
                    <td className="py-2 text-right">
                      <a
                        href={`${process.env.NEXT_PUBLIC_BLOCK_EXPLORER || "https://testnet.arcscan.app"}/tx/${r.txHash}`}
                        target="_blank"
                        rel="noreferrer"
                        className="text-arcora-blue-500 hover:underline font-mono text-xs"
                      >
                        {r.txHash.slice(0, 10)}…
                      </a>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}
