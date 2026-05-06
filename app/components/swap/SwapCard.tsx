"use client";
import { useEffect, useMemo, useState } from "react";
import { useAccount } from "wagmi";
import { useTokens, useQuoteSwap, useSwap } from "@arcoralabs/dex-sdk/react";
import { fmtUnits, tryParseUnits } from "@arcoralabs/dex-sdk";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { TokenSelect } from "@/components/common/TokenSelect";

const SLIPPAGE_BPS = 50; // 0.5 %

export function SwapCard() {
  const { activeTokens, isLoading } = useTokens();
  const { isConnected } = useAccount();

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
    [amountStr, inMeta],
  );

  const { data: quoted } = useQuoteSwap({
    tokenIn,
    tokenOut,
    amountIn: amountIn ?? undefined,
  });

  const { mutate: swap, isPending, error, data: result } = useSwap();

  // Clear input on success
  useEffect(() => {
    if (result) setAmountStr("");
  }, [result]);

  function onSwap() {
    if (!tokenIn || !tokenOut || !amountIn) return;
    swap({
      tokenIn,
      tokenOut,
      amountIn,
      slippageBps: SLIPPAGE_BPS,
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
        </div>

        <div>
          <label className="text-xs text-fg-muted block mb-1">To (estimated)</label>
          <div className="flex gap-2">
            <Input
              type="text"
              readOnly
              value={
                quoted != null && outMeta ? fmtUnits(quoted, outMeta.decimals, 6) : ""
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
        ) : (
          <Button
            onClick={onSwap}
            disabled={!amountIn || amountIn === 0n || isPending || quoted == null}
            className="w-full"
          >
            {isPending ? "Swapping…" : "Swap"}
          </Button>
        )}

        {result?.event ? (
          <p className="text-xs text-success text-center">
            Swapped {fmtUnits(result.event.amountIn, inMeta?.decimals ?? 18, 4)} {inMeta?.symbol} →{" "}
            {fmtUnits(result.event.amountOut, outMeta?.decimals ?? 18, 4)} {outMeta?.symbol}
          </p>
        ) : null}

        {result?.hash ? (
          <p className="text-xs text-fg-muted text-center">
            Tx:{" "}
            <a
              href={`${process.env.NEXT_PUBLIC_BLOCK_EXPLORER || "https://testnet.arcscan.app"}/tx/${result.hash}`}
              target="_blank"
              rel="noreferrer"
              className="text-arcora-blue-500 hover:underline"
            >
              {result.hash.slice(0, 10)}…
            </a>
          </p>
        ) : null}

        {error ? <p className="text-xs text-danger text-center">{error.message}</p> : null}
      </div>
    </Card>
  );
}
