"use client";
import { fmtUnits, fmtUSD } from "@arcoralabs/dex-sdk";
import type { TokenInfo } from "@arcoralabs/dex-sdk";
import { Modal } from "@/components/ui/modal";
import { TokenIcon } from "@/components/common/TokenIcon";

interface Props {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  tokenIn?: TokenInfo;
  tokenOut?: TokenInfo;
  amountIn?: bigint;
  amountOutQuoted?: bigint;
  slippageBps: number;
  onConfirm: () => void;
  isPending: boolean;
}

function formatRate(amountIn: bigint, amountOut: bigint, decIn: number, decOut: number): string {
  if (amountIn === 0n) return "—";
  const inFloat = Number(amountIn) / 10 ** decIn;
  const outFloat = Number(amountOut) / 10 ** decOut;
  const rate = outFloat / inFloat;
  return rate.toFixed(4);
}

export function ConfirmSwapModal({
  open,
  onOpenChange,
  tokenIn,
  tokenOut,
  amountIn,
  amountOutQuoted,
  slippageBps,
  onConfirm,
  isPending,
}: Props) {
  if (!tokenIn || !tokenOut || !amountIn || !amountOutQuoted) return null;

  const minOutFloat = Number(amountOutQuoted * BigInt(10_000 - slippageBps)) /
    Number(10_000n) /
    10 ** tokenOut.decimals;

  return (
    <Modal open={open} onOpenChange={onOpenChange} title="Confirm swap">
      <div className="space-y-3 mt-2">
        <div className="rounded-2xl border border-arc-ink-100 p-4 bg-surface-tint">
          <div className="t-label m-0 mb-1">You pay</div>
          <div className="flex items-center justify-between">
            <div className="t-display-m text-arc-ink-900 t-mono">
              {fmtUnits(amountIn, tokenIn.decimals, 6)}
            </div>
            <div className="flex items-center gap-2">
              <TokenIcon symbol={tokenIn.symbol} size={28} />
              <span className="t-title-m">{tokenIn.symbol}</span>
            </div>
          </div>
        </div>
        <div className="rounded-2xl border border-arc-ink-100 p-4 bg-surface-tint">
          <div className="t-label m-0 mb-1">You receive (estimate)</div>
          <div className="flex items-center justify-between">
            <div className="t-display-m text-arc-ink-900 t-mono">
              {fmtUnits(amountOutQuoted, tokenOut.decimals, 6)}
            </div>
            <div className="flex items-center gap-2">
              <TokenIcon symbol={tokenOut.symbol} size={28} />
              <span className="t-title-m">{tokenOut.symbol}</span>
            </div>
          </div>
        </div>

        <div className="rounded-2xl border border-arc-ink-100 p-4 space-y-1.5 text-[13px]">
          <div className="flex justify-between">
            <span className="text-arc-ink-500">Rate</span>
            <span className="t-mono text-arc-ink-900">
              1 {tokenIn.symbol} = {formatRate(amountIn, amountOutQuoted, tokenIn.decimals, tokenOut.decimals)}{" "}
              {tokenOut.symbol}
            </span>
          </div>
          <div className="flex justify-between">
            <span className="text-arc-ink-500">Slippage tolerance</span>
            <span className="t-mono text-arc-ink-900">{slippageBps / 100}%</span>
          </div>
          <div className="flex justify-between">
            <span className="text-arc-ink-500">Minimum received</span>
            <span className="t-mono text-arc-ink-900">
              {minOutFloat.toFixed(4)} {tokenOut.symbol}
            </span>
          </div>
          <div className="flex justify-between">
            <span className="text-arc-ink-500">Network fee</span>
            <span className="t-mono text-arc-ink-900">~$0.001</span>
          </div>
        </div>

        <p className="text-xs text-arc-ink-500 text-center pt-1">
          You may need to approve {tokenIn.symbol} first; both signatures will appear in your wallet.
        </p>

        <button
          onClick={onConfirm}
          disabled={isPending}
          className="w-full inline-flex items-center justify-center h-12 rounded-full text-[15px] font-medium text-white disabled:opacity-50 transition-all"
          style={{ background: "var(--grad-arcora)", boxShadow: "var(--shadow-glow)" }}
        >
          {isPending ? "Confirming…" : `Confirm swap`}
        </button>
      </div>
    </Modal>
  );
}

export function fmtUSDLite(amount: bigint, decimals: number, priceUsd: number): string {
  const float = Number(amount) / 10 ** decimals;
  return fmtUSD(BigInt(Math.round(float * priceUsd * 1e18)));
}
