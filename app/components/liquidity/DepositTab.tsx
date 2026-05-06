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
import { useTokens, useTokenAccount } from "@/lib/hooks/useTokens";
import { poolAbi } from "@/lib/abi/pool";
import { erc20Abi } from "@/lib/abi/erc20";
import { POOL_ADDRESS } from "@/lib/contracts";
import { fmtUnits, tryParseUnits } from "@/lib/format";
import { minOut, deadline } from "@/lib/slippage";
import { maxUint256 } from "viem";

const SLIPPAGE_BPS = 50;

export function DepositTab() {
  const { activeTokens } = useTokens();
  const { address: account, isConnected } = useAccount();
  const [token, setToken] = useState<`0x${string}` | undefined>();
  const [amountStr, setAmountStr] = useState("");

  useEffect(() => {
    if (!token && activeTokens[0]) setToken(activeTokens[0].address);
  }, [activeTokens, token]);

  const meta = activeTokens.find((t) => t.address === token);
  const amount = useMemo(
    () => (meta && amountStr ? tryParseUnits(amountStr, meta.decimals) : null),
    [amountStr, meta]
  );

  const { data: lpQuote } = useReadContract({
    address: POOL_ADDRESS,
    abi: poolAbi,
    functionName: "quoteDeposit",
    args: token && amount ? [token, amount] : undefined,
    query: { enabled: !!token && !!amount && amount > 0n },
  });

  const { balance, allowance, refetch: refetchAcc } = useTokenAccount(token, account, POOL_ADDRESS);

  const needsApproval = !!amount && allowance < amount;
  const insufficient = !!amount && balance < amount;

  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  useEffect(() => {
    if (isSuccess) {
      setAmountStr("");
      refetchAcc();
      reset();
    }
  }, [isSuccess, refetchAcc, reset]);

  function onApprove() {
    if (!token) return;
    writeContract({
      address: token,
      abi: erc20Abi,
      functionName: "approve",
      args: [POOL_ADDRESS, maxUint256],
    });
  }

  function onDeposit() {
    if (!token || !amount || lpQuote == null) return;
    writeContract({
      address: POOL_ADDRESS,
      abi: poolAbi,
      functionName: "deposit",
      args: [token, amount, minOut(lpQuote as bigint, SLIPPAGE_BPS), deadline()],
    });
  }

  return (
    <div className="space-y-4">
      <div>
        <label className="text-xs text-fg-muted block mb-1">Deposit</label>
        <div className="flex gap-2">
          <Input
            type="text"
            inputMode="decimal"
            placeholder="0.0"
            value={amountStr}
            onChange={(e) => setAmountStr(e.target.value)}
            className="flex-1"
          />
          <TokenSelect tokens={activeTokens} value={token} onChange={setToken} className="w-44" />
        </div>
        {meta && account ? (
          <p className="text-xs text-fg-muted mt-1">
            Balance: {fmtUnits(balance, meta.decimals)} {meta.symbol}
          </p>
        ) : null}
      </div>

      <div className="rounded-md border border-border bg-bg-elevated p-3 text-sm">
        <span className="text-fg-muted">You receive (estimate)</span>
        <span className="float-right">
          {lpQuote != null ? `${fmtUnits(lpQuote as bigint, 18, 4)} ADEX-LP` : "—"}
        </span>
      </div>

      {!isConnected ? (
        <p className="text-sm text-fg-muted text-center">Connect a wallet to deposit.</p>
      ) : insufficient ? (
        <Button disabled className="w-full">Insufficient {meta?.symbol} balance</Button>
      ) : needsApproval ? (
        <Button onClick={onApprove} disabled={isPending || confirming} className="w-full">
          {isPending || confirming ? "Approving…" : `Approve ${meta?.symbol}`}
        </Button>
      ) : (
        <Button
          onClick={onDeposit}
          disabled={!amount || amount === 0n || isPending || confirming || lpQuote == null}
          className="w-full"
        >
          {isPending || confirming ? "Depositing…" : "Deposit"}
        </Button>
      )}
    </div>
  );
}
