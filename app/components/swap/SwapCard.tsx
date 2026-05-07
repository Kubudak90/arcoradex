"use client";
import { useEffect, useMemo, useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { erc20Abi } from "viem";
import {
  useTokens,
  useQuoteSwap,
  useSwap,
  usePoolStats,
} from "@arcoralabs/dex-sdk/react";
import { fmtUnits, tryParseUnits } from "@arcoralabs/dex-sdk";
import { TokenIcon } from "@/components/common/TokenIcon";
import { TokenPickerModal } from "./TokenPickerModal";
import { SlippageMenu } from "./SlippageMenu";
import { ConfirmSwapModal } from "./ConfirmSwapModal";

const PCT_CHIPS = [25, 50, 75, 100] as const;

export function SwapCard() {
  const { activeTokens } = useTokens();
  const { address: account, isConnected } = useAccount();
  const { stats: poolStats } = usePoolStats();

  const [tokenIn, setTokenIn] = useState<`0x${string}` | undefined>();
  const [tokenOut, setTokenOut] = useState<`0x${string}` | undefined>();
  const [amountStr, setAmountStr] = useState("");
  const [picker, setPicker] = useState<"in" | "out" | null>(null);
  const [slippageBps, setSlippageBps] = useState(50);
  const [deadlineMin, setDeadlineMin] = useState(20);
  const [slippageOpen, setSlippageOpen] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);

  // Default tokens on first load
  useEffect(() => {
    if (!tokenIn && activeTokens[0]) setTokenIn(activeTokens[0].address);
    if (!tokenOut && activeTokens[1]) setTokenOut(activeTokens[1].address);
  }, [activeTokens, tokenIn, tokenOut]);

  const inMeta = activeTokens.find((t) => t.address === tokenIn);
  const outMeta = activeTokens.find((t) => t.address === tokenOut);

  const amountIn = useMemo(
    () => (inMeta && amountStr ? tryParseUnits(amountStr, inMeta.decimals) : null),
    [amountStr, inMeta],
  );

  // Balance of tokenIn for the connected user
  const { data: balanceIn } = useReadContract({
    address: tokenIn,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!account && !!tokenIn },
  });

  const { data: quoted, isFetching } = useQuoteSwap({
    tokenIn,
    tokenOut,
    amountIn: amountIn ?? undefined,
  });

  const { mutateAsync: swapAsync, isPending, error, data: result, reset } = useSwap();

  // Clear input on success
  useEffect(() => {
    if (result) setAmountStr("");
  }, [result]);

  // Rate label
  const rate = useMemo(() => {
    if (!amountIn || !quoted || !inMeta || !outMeta) return null;
    const inFloat = Number(amountIn) / 10 ** inMeta.decimals;
    const outFloat = Number(quoted) / 10 ** outMeta.decimals;
    if (inFloat === 0) return null;
    return (outFloat / inFloat).toFixed(4);
  }, [amountIn, quoted, inMeta, outMeta]);

  function setAmountFromPct(pct: number) {
    if (!balanceIn || !inMeta) return;
    const target = ((balanceIn as bigint) * BigInt(pct)) / 100n;
    setAmountStr(fmtUnits(target, inMeta.decimals, inMeta.decimals));
  }

  function flipTokens() {
    setTokenIn(tokenOut);
    setTokenOut(tokenIn);
  }

  async function onConfirm() {
    if (!tokenIn || !tokenOut || !amountIn) return;
    try {
      await swapAsync({
        tokenIn,
        tokenOut,
        amountIn,
        slippageBps,
        deadline: BigInt(Math.floor(Date.now() / 1000) + deadlineMin * 60),
      });
      setConfirmOpen(false);
    } catch {
      // error surfaced via `error` from useSwap; modal stays open so user can retry
    }
  }

  const insufficient = !!amountIn && !!balanceIn && amountIn > (balanceIn as bigint);
  const ctaDisabled =
    !isConnected || !amountIn || amountIn === 0n || quoted == null || insufficient;

  return (
    <div>
      <div
        className="bg-surface rounded-[28px] p-5"
        style={{ boxShadow: "var(--shadow-md)", border: "1px solid var(--arc-ink-100)" }}
      >
        <div className="flex items-center justify-between mb-3.5">
          <div className="t-title-l">Swap</div>
          <div className="flex gap-1.5 items-center">
            {isFetching ? (
              <span className="t-label m-0 text-arc-ink-500" style={{ fontSize: 10 }}>
                Refreshing…
              </span>
            ) : null}
            <button
              onClick={() => setSlippageOpen(true)}
              title="Settings"
              className="inline-flex items-center justify-center h-10 w-10 rounded-full bg-arc-ink-50 hover:bg-arc-ink-100 transition-colors"
            >
              <span className="ms text-arc-ink-700" style={{ fontSize: 18 }}>
                tune
              </span>
            </button>
          </div>
        </div>

        {/* You pay */}
        <div
          className="bg-surface-tint border border-transparent rounded-[14px] px-4 py-3.5 transition-colors focus-within:border-arc-ink-200 focus-within:bg-surface"
        >
          <div className="flex justify-between text-xs text-arc-ink-500">
            <span>You pay</span>
            <span>
              Balance:{" "}
              <span className="t-mono">
                {balanceIn != null && inMeta ? fmtUnits(balanceIn as bigint, inMeta.decimals, 4) : "—"}
              </span>
            </span>
          </div>
          <div className="flex items-center justify-between gap-3 mt-1.5">
            <input
              value={amountStr}
              onChange={(e) => setAmountStr(e.target.value)}
              placeholder="0.00"
              inputMode="decimal"
              className="border-0 bg-transparent outline-none w-full text-arc-ink-900"
              style={{ fontFamily: "var(--font-brand)", fontSize: 32, fontWeight: 500 }}
            />
            <button
              onClick={() => setPicker("in")}
              className="inline-flex items-center gap-2 pl-1.5 pr-3 py-1.5 rounded-full bg-surface text-sm font-medium hover:bg-arc-ink-25 transition-colors"
              style={{ boxShadow: "0 1px 2px rgba(0,0,0,.06)" }}
            >
              {inMeta ? <TokenIcon symbol={inMeta.symbol} size={24} /> : null}
              {inMeta?.symbol ?? "Select"}
              <span className="ms text-arc-ink-400" style={{ fontSize: 18 }}>
                expand_more
              </span>
            </button>
          </div>
          {balanceIn != null && inMeta ? (
            <div className="flex justify-end gap-1.5 mt-2">
              {PCT_CHIPS.map((pct) => (
                <button
                  key={pct}
                  onClick={() => setAmountFromPct(pct)}
                  className="px-2.5 py-0.5 rounded-full text-[11px] font-medium bg-arc-ink-100 text-arc-ink-700 hover:bg-arc-blue-50 hover:text-arc-blue-700 transition-colors"
                >
                  {pct === 100 ? "MAX" : `${pct}%`}
                </button>
              ))}
            </div>
          ) : null}
        </div>

        {/* Swap arrow */}
        <div className="flex justify-center -my-2.5 relative z-10">
          <button
            onClick={flipTokens}
            className="w-9 h-9 rounded-full bg-surface flex items-center justify-center transition-transform hover:rotate-180"
            style={{
              border: "4px solid var(--surface)",
              boxShadow: "var(--shadow-sm)",
            }}
          >
            <span className="ms text-arc-ink-700" style={{ fontSize: 18 }}>
              swap_vert
            </span>
          </button>
        </div>

        {/* You receive */}
        <div className="bg-surface-tint border border-transparent rounded-[14px] px-4 py-3.5">
          <div className="text-xs text-arc-ink-500">You receive</div>
          <div className="flex items-center justify-between gap-3 mt-1.5">
            <input
              value={quoted != null && outMeta ? fmtUnits(quoted, outMeta.decimals, 6) : ""}
              readOnly
              placeholder="0.00"
              className="border-0 bg-transparent outline-none w-full text-arc-ink-700"
              style={{ fontFamily: "var(--font-brand)", fontSize: 32, fontWeight: 500 }}
            />
            <button
              onClick={() => setPicker("out")}
              className="inline-flex items-center gap-2 pl-1.5 pr-3 py-1.5 rounded-full bg-surface text-sm font-medium hover:bg-arc-ink-25 transition-colors"
              style={{ boxShadow: "0 1px 2px rgba(0,0,0,.06)" }}
            >
              {outMeta ? <TokenIcon symbol={outMeta.symbol} size={24} /> : null}
              {outMeta?.symbol ?? "Select"}
              <span className="ms text-arc-ink-400" style={{ fontSize: 18 }}>
                expand_more
              </span>
            </button>
          </div>
        </div>

        {/* Info rows */}
        <div className="px-1 pt-3.5 pb-1 flex flex-col gap-1 text-[13px]">
          <Row l="Rate" r={rate ? `1 ${inMeta?.symbol} = ${rate} ${outMeta?.symbol}` : "—"} />
          <button
            onClick={() => setSlippageOpen(true)}
            className="flex justify-between items-center text-left hover:text-arc-blue-700 -mx-1 px-1"
          >
            <span className="text-arc-ink-500">Slippage tolerance</span>
            <span className="t-mono text-arc-blue-600">
              {slippageBps / 100}% ›
            </span>
          </button>
          <Row
            l="Swap fee"
            r={poolStats ? `${poolStats.swapFeeBps / 100}%` : "—"}
          />
          <Row l="Network fee" r="~$0.001" />
        </div>

        {/* CTA */}
        <button
          onClick={() => !ctaDisabled && setConfirmOpen(true)}
          disabled={ctaDisabled}
          className="w-full inline-flex items-center justify-center h-13 rounded-full text-[15px] font-medium mt-3 transition-all"
          style={
            ctaDisabled
              ? { background: "var(--arc-ink-100)", color: "var(--arc-ink-400)", cursor: "not-allowed" }
              : { background: "var(--grad-arcora)", color: "white", boxShadow: "var(--shadow-glow)" }
          }
        >
          {!isConnected
            ? "Connect wallet"
            : !amountIn || amountIn === 0n
              ? "Enter an amount"
              : insufficient
                ? `Insufficient ${inMeta?.symbol} balance`
                : `Swap ${inMeta?.symbol} → ${outMeta?.symbol}`}
        </button>

        {/* Status messages */}
        {result?.event ? (
          <p className="text-xs text-center mt-3" style={{ color: "var(--color-success)" }}>
            ✓ Swapped {fmtUnits(result.event.amountIn, inMeta?.decimals ?? 18, 4)} {inMeta?.symbol} →{" "}
            {fmtUnits(result.event.amountOut, outMeta?.decimals ?? 18, 4)} {outMeta?.symbol}{" "}
            <a
              href={`${process.env.NEXT_PUBLIC_BLOCK_EXPLORER || "https://testnet.arcscan.app"}/tx/${result.hash}`}
              target="_blank"
              rel="noreferrer"
              className="underline"
            >
              tx
            </a>
          </p>
        ) : null}
        {error ? (
          <p className="text-xs text-center mt-3" style={{ color: "var(--color-danger)" }}>
            {error.message}
          </p>
        ) : null}
      </div>

      {/* Stats strip */}
      <div className="grid grid-cols-3 gap-3 mt-4">
        {[
          {
            l: "Pool TVL",
            v: poolStats
              ? `$${(Number(poolStats.navUsd1e18) / 1e18).toLocaleString(undefined, { maximumFractionDigits: 0 })}`
              : "—",
          },
          { l: "Swap fee", v: poolStats ? `${poolStats.swapFeeBps / 100}%` : "—" },
          {
            l: "LP price",
            v: poolStats
              ? `$${(Number(poolStats.lpPriceUsd1e18) / 1e18).toFixed(4)}`
              : "—",
          },
        ].map((s) => (
          <div
            key={s.l}
            className="px-3.5 py-3 bg-surface border border-arc-ink-100 rounded-[14px]"
          >
            <div className="t-label m-0">{s.l}</div>
            <div className="t-mono text-[18px] font-medium mt-0.5">{s.v}</div>
          </div>
        ))}
      </div>

      {/* Modals */}
      <TokenPickerModal
        open={picker !== null}
        onOpenChange={(o) => !o && setPicker(null)}
        tokens={activeTokens}
        exclude={picker === "in" ? tokenOut : tokenIn}
        onSelect={(addr) => {
          if (picker === "in") setTokenIn(addr);
          else if (picker === "out") setTokenOut(addr);
          setPicker(null);
        }}
      />
      <SlippageMenu
        open={slippageOpen}
        onOpenChange={setSlippageOpen}
        slippageBps={slippageBps}
        onSlippageChange={setSlippageBps}
        deadlineMin={deadlineMin}
        onDeadlineChange={setDeadlineMin}
      />
      <ConfirmSwapModal
        open={confirmOpen}
        onOpenChange={(o) => {
          setConfirmOpen(o);
          if (!o) reset();
        }}
        tokenIn={inMeta}
        tokenOut={outMeta}
        amountIn={amountIn ?? undefined}
        amountOutQuoted={quoted ?? undefined}
        slippageBps={slippageBps}
        onConfirm={onConfirm}
        isPending={isPending}
      />

      <style jsx>{`
        @keyframes spin {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
      `}</style>
    </div>
  );
}

function Row({ l, r }: { l: string; r: string }) {
  return (
    <div className="flex justify-between py-0.5">
      <span className="text-arc-ink-500">{l}</span>
      <span className="t-mono text-arc-ink-900">{r}</span>
    </div>
  );
}

