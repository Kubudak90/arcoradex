"use client";
import { useEffect, useMemo, useState } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { TokenSelect } from "@/components/common/TokenSelect";
import { useTokens } from "@/lib/hooks/useTokens";
import { poolAbi } from "@/lib/abi/pool";
import { lpAbi } from "@/lib/abi/lp";
import { POOL_ADDRESS, LP_ADDRESS } from "@/lib/contracts";
import { fmtUnits, tryParseUnits } from "@/lib/format";
import { minOut, deadline } from "@/lib/slippage";

const SLIPPAGE_BPS = 50;

export function WithdrawTab() {
  const { activeTokens } = useTokens();
  const { address: account, isConnected } = useAccount();
  const [tokenOut, setTokenOut] = useState<`0x${string}` | undefined>();
  const [lpStr, setLpStr] = useState("");

  useEffect(() => {
    if (!tokenOut && activeTokens[0]) setTokenOut(activeTokens[0].address);
  }, [activeTokens, tokenOut]);

  const meta = activeTokens.find((t) => t.address === tokenOut);
  const lpAmount = useMemo(() => (lpStr ? tryParseUnits(lpStr, 18) : null), [lpStr]);

  const { data: lpBalance, refetch: refetchLp } = useReadContract({
    address: LP_ADDRESS,
    abi: lpAbi,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!account },
  });

  const { data: withdrawQuote } = useReadContract({
    address: POOL_ADDRESS,
    abi: poolAbi,
    functionName: "quoteWithdraw",
    args: tokenOut && lpAmount ? [tokenOut, lpAmount] : undefined,
    query: { enabled: !!tokenOut && !!lpAmount && lpAmount > 0n },
  });

  const insufficient = lpAmount != null && lpBalance != null && (lpAmount as bigint) > (lpBalance as bigint);

  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  useEffect(() => {
    if (isSuccess) {
      setLpStr("");
      refetchLp();
      reset();
    }
  }, [isSuccess, refetchLp, reset]);

  function onWithdraw() {
    if (!tokenOut || !lpAmount || withdrawQuote == null) return;
    const [amountOut] = withdrawQuote as readonly [bigint, bigint];
    writeContract({
      address: POOL_ADDRESS,
      abi: poolAbi,
      functionName: "withdraw",
      args: [tokenOut, lpAmount, minOut(amountOut, SLIPPAGE_BPS), deadline()],
    });
  }

  const [estOut, estFee] = (withdrawQuote as readonly [bigint, bigint] | undefined) ?? [undefined, undefined];

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
            {estOut != null && meta ? `${fmtUnits(estOut, meta.decimals, 6)} ${meta.symbol}` : "—"}
          </span>
        </div>
        <div>
          <span className="text-fg-muted">Protocol fee (in {meta?.symbol})</span>
          <span className="float-right">
            {estFee != null && meta ? fmtUnits(estFee, meta.decimals, 6) : "—"}
          </span>
        </div>
      </div>

      {!isConnected ? (
        <p className="text-sm text-fg-muted text-center">Connect a wallet to withdraw.</p>
      ) : insufficient ? (
        <Button disabled className="w-full">Insufficient ADEX-LP balance</Button>
      ) : (
        <Button
          onClick={onWithdraw}
          disabled={!lpAmount || lpAmount === 0n || isPending || confirming || withdrawQuote == null}
          className="w-full"
        >
          {isPending || confirming ? "Withdrawing…" : "Withdraw"}
        </Button>
      )}
    </div>
  );
}
