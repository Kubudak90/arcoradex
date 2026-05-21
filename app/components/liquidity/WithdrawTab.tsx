"use client";
import { useMemo, useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { parseAbi } from "viem";
import {
  useTokens,
  useQuoteWithdraw,
  useWithdraw,
  useArcoraDex,
} from "@arcoralabs/dex-sdk/react";
import { fmtUnits, tryParseUnits } from "@arcoralabs/dex-sdk";
import { TokenIcon } from "@/components/common/TokenIcon";
import { TokenPickerModal } from "@/components/swap/TokenPickerModal";

const SLIPPAGE_BPS = 50;
const PCT_CHIPS = [25, 50, 75, 100] as const;
const lpAbi = parseAbi(["function balanceOf(address) view returns (uint256)"]);

export function WithdrawTab() {
  const { activeTokens } = useTokens();
  const { address: account, isConnected } = useAccount();
  const sdk = useArcoraDex();

  const [tokenOut, setTokenOut] = useState<`0x${string}` | undefined>();
  const [lpStr, setLpStr] = useState("");
  const [pickerOpen, setPickerOpen] = useState(false);

  // Derive default at render time; explicit picker selection takes over via setTokenOut.
  const effectiveTokenOut = tokenOut ?? activeTokens[0]?.address;

  const meta = activeTokens.find((t) => t.address === effectiveTokenOut);
  const lpAmount = useMemo(() => (lpStr ? tryParseUnits(lpStr, 18) : null), [lpStr]);

  const { data: lpBalance, refetch: refetchLp } = useReadContract({
    address: sdk.addresses.lp,
    abi: lpAbi,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!account },
  });

  const { data: withdrawQuote } = useQuoteWithdraw({
    tokenOut: effectiveTokenOut,
    lpAmount: lpAmount ?? undefined,
  });

  const insufficient =
    lpAmount != null && lpBalance != null && lpAmount > (lpBalance as bigint);
  const { mutate: withdraw, isPending, error, data: result } = useWithdraw();

  function setFromPct(pct: number) {
    if (!lpBalance) return;
    setLpStr(fmtUnits(((lpBalance as bigint) * BigInt(pct)) / 100n, 18, 18));
  }

  function onWithdraw() {
    if (!effectiveTokenOut || !lpAmount) return;
    withdraw(
      { tokenOut: effectiveTokenOut, lpAmount, slippageBps: SLIPPAGE_BPS },
      {
        onSuccess: () => {
          setLpStr("");
          refetchLp();
        },
      },
    );
  }

  const ctaDisabled =
    !isConnected || !lpAmount || lpAmount === 0n || withdrawQuote == null || insufficient;

  return (
    <div className="space-y-3.5">
      <div className="bg-surface-tint border border-transparent rounded-[14px] px-4 py-3.5 transition-colors focus-within:border-arc-ink-200 focus-within:bg-surface">
        <div className="flex justify-between text-xs text-arc-ink-500">
          <span>Burn ADEX-LP</span>
          <span>
            Balance:{" "}
            <span className="t-mono">
              {lpBalance != null ? fmtUnits(lpBalance as bigint, 18, 4) : "—"}
            </span>
          </span>
        </div>
        <div className="flex items-center justify-between gap-3 mt-1.5">
          <input
            value={lpStr}
            onChange={(e) => setLpStr(e.target.value)}
            placeholder="0.00"
            inputMode="decimal"
            className="border-0 bg-transparent outline-none w-full text-arc-ink-900"
            style={{ fontFamily: "var(--font-brand)", fontSize: 32, fontWeight: 500 }}
          />
          <span
            className="inline-flex items-center gap-2 pl-1.5 pr-3 py-1.5 rounded-full bg-surface text-sm font-medium"
            style={{ boxShadow: "0 1px 2px rgba(0,0,0,.06)" }}
          >
            <span
              className="w-6 h-6 rounded-full inline-flex items-center justify-center text-white text-[10px] font-bold"
              style={{ background: "var(--grad-arcora)" }}
            >
              LP
            </span>
            ADEX-LP
          </span>
        </div>
        {lpBalance != null ? (
          <div className="flex justify-end gap-1.5 mt-2">
            {PCT_CHIPS.map((pct) => (
              <button
                key={pct}
                onClick={() => setFromPct(pct)}
                className="px-2.5 py-0.5 rounded-full text-[11px] font-medium bg-arc-ink-100 text-arc-ink-700 hover:bg-arc-blue-50 hover:text-arc-blue-700 transition-colors"
              >
                {pct === 100 ? "MAX" : `${pct}%`}
              </button>
            ))}
          </div>
        ) : null}
      </div>

      <div className="bg-surface-tint border border-transparent rounded-[14px] px-4 py-3.5">
        <div className="text-xs text-arc-ink-500">Receive in</div>
        <div className="flex items-center justify-between gap-3 mt-1.5">
          <span className="text-arc-ink-400" style={{ fontFamily: "var(--font-brand)", fontSize: 20 }}>
            {withdrawQuote && meta ? `${fmtUnits(withdrawQuote.amountOut, meta.decimals, 6)}` : "0.00"}
          </span>
          <button
            onClick={() => setPickerOpen(true)}
            className="inline-flex items-center gap-2 pl-1.5 pr-3 py-1.5 rounded-full bg-surface text-sm font-medium hover:bg-arc-ink-25 transition-colors"
            style={{ boxShadow: "0 1px 2px rgba(0,0,0,.06)" }}
          >
            {meta ? <TokenIcon symbol={meta.symbol} size={24} /> : null}
            {meta?.symbol ?? "Select"}
            <span className="ms text-arc-ink-400" style={{ fontSize: 18 }}>
              expand_more
            </span>
          </button>
        </div>
      </div>

      <div className="rounded-[14px] border border-arc-ink-100 bg-surface px-4 py-3 text-sm space-y-1">
        <div className="flex justify-between">
          <span className="text-arc-ink-500">Protocol fee</span>
          <span className="t-mono text-arc-ink-900">
            {withdrawQuote && meta
              ? `${fmtUnits(withdrawQuote.protocolFee, meta.decimals, 6)} ${meta.symbol}`
              : "—"}
          </span>
        </div>
      </div>

      <button
        onClick={onWithdraw}
        disabled={ctaDisabled}
        className="w-full inline-flex items-center justify-center h-13 rounded-full text-[15px] font-medium mt-1 transition-all"
        style={
          ctaDisabled
            ? { background: "var(--arc-ink-100)", color: "var(--arc-ink-400)", cursor: "not-allowed" }
            : { background: "var(--grad-arcora)", color: "white", boxShadow: "var(--shadow-glow)" }
        }
      >
        {!isConnected
          ? "Connect wallet"
          : !lpAmount || lpAmount === 0n
            ? "Enter an amount"
            : insufficient
              ? "Insufficient ADEX-LP balance"
              : isPending
                ? "Withdrawing…"
                : `Withdraw to ${meta?.symbol}`}
      </button>

      {result?.event && meta ? (
        <p className="text-xs text-center" style={{ color: "var(--color-success)" }}>
          ✓ Withdrew {fmtUnits(result.event.lpBurned, 18, 4)} ADEX-LP →{" "}
          {fmtUnits(result.event.amountOut, meta.decimals, 4)} {meta.symbol}
        </p>
      ) : null}
      {error ? (
        <p className="text-xs text-center" style={{ color: "var(--color-danger)" }}>
          {error.message}
        </p>
      ) : null}

      <TokenPickerModal
        open={pickerOpen}
        onOpenChange={setPickerOpen}
        tokens={activeTokens}
        onSelect={(addr) => {
          setTokenOut(addr);
          setPickerOpen(false);
        }}
      />
    </div>
  );
}
