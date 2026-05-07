"use client";
import { useEffect, useMemo, useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { parseAbi } from "viem";
import {
  useTokens,
  useQuoteWithdraw,
  useWithdraw,
  useArcoraDex,
} from "@arcoralabs/dex-sdk/react";
import { fmtUnits, tryParseUnits } from "@arcoralabs/dex-sdk";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { TokenSelect } from "@/components/common/TokenSelect";

const SLIPPAGE_BPS = 50;
const lpAbi = parseAbi(["function balanceOf(address) view returns (uint256)"]);

export function WithdrawTab() {
  const { activeTokens } = useTokens();
  const { address: account, isConnected } = useAccount();
  const sdk = useArcoraDex();

  const [tokenOut, setTokenOut] = useState<`0x${string}` | undefined>();
  const [lpStr, setLpStr] = useState("");

  useEffect(() => {
    if (!tokenOut && activeTokens[0]) setTokenOut(activeTokens[0].address);
  }, [activeTokens, tokenOut]);

  const meta = activeTokens.find((t) => t.address === tokenOut);
  const lpAmount = useMemo(() => (lpStr ? tryParseUnits(lpStr, 18) : null), [lpStr]);

  const { data: lpBalance, refetch: refetchLp } = useReadContract({
    address: sdk.addresses.lp,
    abi: lpAbi,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!account },
  });

  const { data: withdrawQuote } = useQuoteWithdraw({
    tokenOut,
    lpAmount: lpAmount ?? undefined,
  });

  const insufficient =
    lpAmount != null && lpBalance != null && lpAmount > (lpBalance as bigint);

  const { mutate: withdraw, isPending, error, data: result } = useWithdraw();

  useEffect(() => {
    if (result) {
      setLpStr("");
      refetchLp();
    }
  }, [result, refetchLp]);

  function onWithdraw() {
    if (!tokenOut || !lpAmount) return;
    withdraw({ tokenOut, lpAmount, slippageBps: SLIPPAGE_BPS });
  }

  return (
    <div className="space-y-4">
      <div>
        <label className="t-label m-0 mb-2 block">Burn ADEX-LP</label>
        <Input
          type="text"
          inputMode="decimal"
          placeholder="0.00"
          value={lpStr}
          onChange={(e) => setLpStr(e.target.value)}
        />
        {lpBalance != null ? (
          <p className="text-xs text-arc-ink-500 mt-2">
            Balance: <span className="t-mono">{fmtUnits(lpBalance as bigint, 18, 4)}</span> ADEX-LP{" "}
            <button
              onClick={() => setLpStr(fmtUnits(lpBalance as bigint, 18, 18))}
              className="ml-1 text-arc-blue-600 hover:underline"
            >
              max
            </button>
          </p>
        ) : null}
      </div>

      <div>
        <label className="t-label m-0 mb-2 block">Receive</label>
        <TokenSelect tokens={activeTokens} value={tokenOut} onChange={setTokenOut} />
      </div>

      <div className="rounded-2xl border border-arc-ink-100 bg-surface-tint p-3.5 text-sm space-y-1.5">
        <div className="flex justify-between">
          <span className="text-arc-ink-500">You receive (estimate)</span>
          <span className="t-mono text-arc-ink-900">
            {withdrawQuote && meta
              ? `${fmtUnits(withdrawQuote.amountOut, meta.decimals, 6)} ${meta.symbol}`
              : "—"}
          </span>
        </div>
        <div className="flex justify-between">
          <span className="text-arc-ink-500">Protocol fee</span>
          <span className="t-mono text-arc-ink-900">
            {withdrawQuote && meta
              ? `${fmtUnits(withdrawQuote.protocolFee, meta.decimals, 6)} ${meta.symbol}`
              : "—"}
          </span>
        </div>
      </div>

      {!isConnected ? (
        <p className="text-sm text-arc-ink-500 text-center">Connect a wallet to withdraw.</p>
      ) : insufficient ? (
        <Button disabled size="lg" className="w-full">
          Insufficient ADEX-LP balance
        </Button>
      ) : (
        <Button
          variant="gradient"
          size="lg"
          onClick={onWithdraw}
          disabled={!lpAmount || lpAmount === 0n || isPending || withdrawQuote == null}
          className="w-full"
        >
          {isPending ? "Withdrawing…" : "Withdraw"}
        </Button>
      )}

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
    </div>
  );
}
