"use client";
import { useMemo } from "react";
import { useSwapHistory, useTokens } from "@arcoralabs/dex-sdk/react";
import { fmtUnits, tokenLabel } from "@arcoralabs/dex-sdk";
import { shortAddr } from "@/lib/utils";
import { TokenIcon } from "@/components/common/TokenIcon";

const LIMIT = 20;

export function RecentSwapsCard() {
  const { tokens } = useTokens();
  const { events: rows, isLoading, error } = useSwapHistory({ limit: LIMIT, watch: true });

  const decimalsByAddr = useMemo(() => {
    const m = new Map<string, number>();
    for (const t of tokens) m.set(t.address.toLowerCase(), t.decimals);
    return m;
  }, [tokens]);
  const dec = (addr: string) => decimalsByAddr.get(addr.toLowerCase()) ?? 18;

  return (
    <div
      className="bg-surface rounded-[20px] overflow-hidden"
      style={{ border: "1px solid var(--arc-ink-100)" }}
    >
      <div className="flex items-center justify-between px-5 py-4 border-b border-arc-ink-100">
        <div className="t-title-m">Recent transactions</div>
        <div className="flex gap-1.5 items-center text-xs text-arc-ink-500">
          <span className="dot live" />
          Live
        </div>
      </div>

      {error ? (
        <p className="px-5 py-6 text-sm" style={{ color: "var(--color-danger)" }}>
          {error.message}
        </p>
      ) : isLoading ? (
        <p className="px-5 py-6 text-sm text-arc-ink-500">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="px-5 py-12 text-sm text-arc-ink-500 text-center">No swaps yet.</p>
      ) : (
        rows.map((r) => {
          const tIn = tokenLabel(r.tokenIn);
          const tOut = tokenLabel(r.tokenOut);
          return (
            <div
              key={`${r.txHash}-${r.logIndex}`}
              className="flex items-center gap-3.5 px-5 py-3.5 border-b border-arc-ink-100 last:border-0"
            >
              <div
                className="w-9 h-9 rounded-full flex items-center justify-center flex-shrink-0"
                style={{ background: "var(--arc-blue-50)" }}
              >
                <span className="ms" style={{ fontSize: 18, color: "var(--arc-blue-600)" }}>
                  swap_horiz
                </span>
              </div>
              <div className="flex-1 min-w-0">
                <div className="text-sm flex items-center gap-1.5 flex-wrap">
                  <span className="text-arc-ink-500">Swap</span>
                  <TokenIcon symbol={tIn.symbol} size={16} />
                  <span className="t-mono">
                    {fmtUnits(r.amountIn, dec(r.tokenIn), 4)} {tIn.symbol}
                  </span>
                  <span className="text-arc-ink-400">→</span>
                  <TokenIcon symbol={tOut.symbol} size={16} />
                  <span className="t-mono">
                    {fmtUnits(r.amountOut, dec(r.tokenOut), 4)} {tOut.symbol}
                  </span>
                </div>
                <div
                  className="text-xs text-arc-ink-500 mt-0.5"
                  style={{ fontFamily: "var(--font-mono)" }}
                >
                  {shortAddr(r.user)} · block {r.blockNumber.toString()}
                </div>
              </div>
              <a
                href={`${process.env.NEXT_PUBLIC_BLOCK_EXPLORER || "https://testnet.arcscan.app"}/tx/${r.txHash}`}
                target="_blank"
                rel="noreferrer"
                className="text-arc-ink-400 hover:text-arc-ink-700 transition-colors"
                aria-label="Open in explorer"
              >
                <span className="ms" style={{ fontSize: 18 }}>
                  open_in_new
                </span>
              </a>
            </div>
          );
        })
      )}
    </div>
  );
}
