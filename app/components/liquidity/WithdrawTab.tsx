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
        <label className="text-xs text-fg-muted block mb-1">Burn ADEX-LP</label>
        <Input
          type="text"
          inputMode="decimal"
          placeholder="0.0"
          value={lpStr}
          onChange={(e) => setLpStr(e.target.value)}
        />
        {lpBalance != null ? (
          <p className="text-xs text-fg-muted mt-1">
            Balance: {fmtUnits(lpBalance as bigint, 18, 4)} ADEX-LP{" "}
            <button
              onClick={() => setLpStr(fmtUnits(lpBalance as bigint, 18, 18))}
              className="ml-1 text-arcora-blue-500 hover:underline"
            >
              max
            </button>
          </p>
        ) : null}
      </div>

      <div>
        <label className="text-xs text-fg-muted block mb-1">Receive</label>
        <TokenSelect tokens={activeTokens} value={tokenOut} onChange={setTokenOut} />
      </div>

      <div className="rounded-md border border-border bg-bg-elevated p-3 text-sm space-y-1">
        <div>
          <span className="text-fg-muted">You receive (estimate)</span>
          <span className="float-right">
            {withdrawQuote && meta
              ? `${fmtUnits(withdrawQuote.amountOut, meta.decimals, 6)} ${meta.symbol}`
              : "—"}
          </span>
        </div>
        <div>
          <span className="text-fg-muted">Protocol fee (in {meta?.symbol})</span>
          <span className="float-right">
            {withdrawQuote && meta ? fmtUnits(withdrawQuote.protocolFee, meta.decimals, 6) : "—"}
          </span>
        </div>
      </div>

      {!isConnected ? (
        <p className="text-sm text-fg-muted text-center">Connect a wallet to withdraw.</p>
      ) : insufficient ? (
        <Button disabled className="w-full">
          Insufficient ADEX-LP balance
        </Button>
      ) : (
        <Button
          onClick={onWithdraw}
          disabled={!lpAmount || lpAmount === 0n || isPending || withdrawQuote == null}
          className="w-full"
        >
          {isPending ? "Withdrawing…" : "Withdraw"}
        </Button>
      )}

      {result?.event && meta ? (
        <p className="text-xs text-success text-center">
          Withdrew {fmtUnits(result.event.lpBurned, 18, 4)} ADEX-LP →{" "}
          {fmtUnits(result.event.amountOut, meta.decimals, 4)} {meta.symbol}
        </p>
      ) : null}
      {error ? <p className="text-xs text-danger text-center">{error.message}</p> : null}
    </div>
  );
}
