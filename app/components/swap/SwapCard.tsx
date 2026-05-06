"use client";
import { useEffect, useMemo, useState } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
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

const SLIPPAGE_BPS = 50; // 0.5 %

export function SwapCard() {
  const { activeTokens, isLoading } = useTokens();
  const { address: account, isConnected } = useAccount();

  const [tokenIn, setTokenIn] = useState<`0x${string}` | undefined>();
  const [tokenOut, setTokenOut] = useState<`0x${string}` | undefined>();
  const [amountStr, setAmountStr] = useState("");

  // Default selection once tokens load
  useEffect(() => {
    if (!tokenIn && activeTokens[0]) setTokenIn(activeTokens[0].address);
    if (!tokenOut && activeTokens[1]) setTokenOut(activeTokens[1].address);
  }, [activeTokens, tokenIn, tokenOut]);

  const inMeta = activeTokens.find((t) => t.address === tokenIn);
  const outMeta = activeTokens.find((t) => t.address === tokenOut);

  const amountIn = useMemo(
    () => (inMeta && amountStr ? tryParseUnits(amountStr, inMeta.decimals) : null),
    [amountStr, inMeta]
  );

  // Quote
  const { data: quoted } = useReadContract({
    address: POOL_ADDRESS,
    abi: poolAbi,
    functionName: "quote",
    args: tokenIn && tokenOut && amountIn ? [tokenIn, tokenOut, amountIn] : undefined,
    query: {
      enabled: !!tokenIn && !!tokenOut && tokenIn !== tokenOut && amountIn != null && amountIn > 0n,
    },
  });

  // Balance + allowance
  const { balance, allowance, refetch: refetchAccount } = useTokenAccount(
    tokenIn,
    account,
    POOL_ADDRESS
  );

  const needsApproval = !!amountIn && allowance < amountIn;
  const insufficientBalance = !!amountIn && balance < amountIn;

  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  // After a successful swap, clear input + refresh balances
  useEffect(() => {
    if (isSuccess) {
      setAmountStr("");
      refetchAccount();
      reset();
    }
  }, [isSuccess, refetchAccount, reset]);

  function onApprove() {
    if (!tokenIn) return;
    writeContract({
      address: tokenIn,
      abi: erc20Abi,
      functionName: "approve",
      args: [POOL_ADDRESS, maxUint256],
    });
  }

  function onSwap() {
    if (!tokenIn || !tokenOut || !amountIn || quoted == null || !account) return;
    writeContract({
      address: POOL_ADDRESS,
      abi: poolAbi,
      functionName: "swap",
      args: [tokenIn, tokenOut, amountIn, minOut(quoted as bigint, SLIPPAGE_BPS), deadline(), account],
    });
  }

  return (
    <Card className="max-w-md mx-auto">
      <CardHeader>
        <CardTitle>Swap</CardTitle>
        <span className="text-xs text-fg-muted">slippage {SLIPPAGE_BPS / 100}%</span>
      </CardHeader>

      <div className="space-y-4">
        <div>
          <label className="text-xs text-fg-muted block mb-1">From</label>
          <div className="flex gap-2">
            <Input
              type="text"
              inputMode="decimal"
              placeholder="0.0"
              value={amountStr}
              onChange={(e) => setAmountStr(e.target.value)}
              className="flex-1"
            />
            <TokenSelect
              tokens={activeTokens}
              value={tokenIn}
              onChange={setTokenIn}
              exclude={tokenOut}
              className="w-44"
            />
          </div>
          {inMeta && account ? (
            <p className="text-xs text-fg-muted mt-1">
              Balance: {fmtUnits(balance, inMeta.decimals)} {inMeta.symbol}
            </p>
          ) : null}
        </div>

        <div>
          <label className="text-xs text-fg-muted block mb-1">To (estimated)</label>
          <div className="flex gap-2">
            <Input
              type="text"
              readOnly
              value={
                quoted != null && outMeta
                  ? fmtUnits(quoted as bigint, outMeta.decimals, 6)
                  : ""
              }
              className="flex-1"
            />
            <TokenSelect
              tokens={activeTokens}
              value={tokenOut}
              onChange={setTokenOut}
              exclude={tokenIn}
              className="w-44"
            />
          </div>
        </div>

        {!isConnected ? (
          <p className="text-sm text-fg-muted text-center pt-2">
            Connect a wallet on Arc Testnet to swap.
          </p>
        ) : isLoading ? (
          <p className="text-sm text-fg-muted text-center pt-2">Loading registry…</p>
        ) : insufficientBalance ? (
          <Button disabled className="w-full">
            Insufficient {inMeta?.symbol} balance
          </Button>
        ) : needsApproval ? (
          <Button onClick={onApprove} disabled={isPending || confirming} className="w-full">
            {isPending || confirming ? "Approving…" : `Approve ${inMeta?.symbol}`}
          </Button>
        ) : (
          <Button
            onClick={onSwap}
            disabled={!amountIn || amountIn === 0n || isPending || confirming || quoted == null}
            className="w-full"
          >
            {isPending || confirming ? "Swapping…" : "Swap"}
          </Button>
        )}

        {txHash ? (
          <p className="text-xs text-fg-muted text-center">
            Tx:{" "}
            <a
              href={`${process.env.NEXT_PUBLIC_BLOCK_EXPLORER || "https://testnet.arcscan.app"}/tx/${txHash}`}
              target="_blank"
              rel="noreferrer"
              className="text-arcora-blue-500 hover:underline"
            >
              {txHash.slice(0, 10)}…
            </a>
          </p>
        ) : null}
      </div>
    </Card>
  );
}
