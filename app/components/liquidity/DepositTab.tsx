"use client";
import { useEffect, useMemo, useState } from "react";
import { useAccount } from "wagmi";
import { useTokens, useQuoteDeposit, useDeposit } from "@arcoralabs/dex-sdk/react";
import { fmtUnits, tryParseUnits } from "@arcoralabs/dex-sdk";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { TokenSelect } from "@/components/common/TokenSelect";

const SLIPPAGE_BPS = 50;

export function DepositTab() {
  const { activeTokens } = useTokens();
  const { isConnected } = useAccount();
  const [token, setToken] = useState<`0x${string}` | undefined>();
  const [amountStr, setAmountStr] = useState("");

  useEffect(() => {
    if (!token && activeTokens[0]) setToken(activeTokens[0].address);
  }, [activeTokens, token]);

  const meta = activeTokens.find((t) => t.address === token);
  const amount = useMemo(
    () => (meta && amountStr ? tryParseUnits(amountStr, meta.decimals) : null),
    [amountStr, meta],
  );

  const { data: lpQuote } = useQuoteDeposit({
    token,
    amount: amount ?? undefined,
  });

  const { mutate: deposit, isPending, error, data: result } = useDeposit();

  useEffect(() => {
    if (result) setAmountStr("");
  }, [result]);

  function onDeposit() {
    if (!token || !amount) return;
    deposit({ token, amount, slippageBps: SLIPPAGE_BPS });
  }

  return (
    <div className="space-y-4">
      <div>
        <label className="t-label m-0 mb-2 block">Deposit</label>
        <div className="flex gap-2">
          <Input
            type="text"
            inputMode="decimal"
            placeholder="0.00"
            value={amountStr}
            onChange={(e) => setAmountStr(e.target.value)}
            className="flex-1"
          />
          <TokenSelect tokens={activeTokens} value={token} onChange={setToken} className="w-40" />
        </div>
      </div>

      <div className="rounded-2xl border border-arc-ink-100 bg-surface-tint p-3.5 text-sm">
        <span className="text-arc-ink-500">You receive (estimate)</span>
        <span className="float-right t-mono text-arc-ink-900">
          {lpQuote != null ? `${fmtUnits(lpQuote, 18, 4)} ADEX-LP` : "—"}
        </span>
      </div>

      {!isConnected ? (
        <p className="text-sm text-arc-ink-500 text-center">Connect a wallet to deposit.</p>
      ) : (
        <Button
          variant="gradient"
          size="lg"
          onClick={onDeposit}
          disabled={!amount || amount === 0n || isPending || lpQuote == null}
          className="w-full"
        >
          {isPending ? "Depositing…" : "Deposit"}
        </Button>
      )}

      {result?.event ? (
        <p className="text-xs text-center" style={{ color: "var(--color-success)" }}>
          ✓ Deposited {fmtUnits(result.event.amountIn, meta?.decimals ?? 18, 4)} {meta?.symbol}, minted{" "}
          {fmtUnits(result.event.lpMinted, 18, 4)} ADEX-LP
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
