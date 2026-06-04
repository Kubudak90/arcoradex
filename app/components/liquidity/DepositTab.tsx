"use client";
import { useMemo, useState } from "react";
import { useAccount, useReadContract, useChainId, useSwitchChain } from "wagmi";
import { erc20Abi } from "viem";
import { useTokens, useQuoteDeposit, useDeposit } from "@arcoralabs/dex-sdk/react";
import { fmtUnits, tryParseUnits, arcTestnet } from "@arcoralabs/dex-sdk";
import { TokenIcon } from "@/components/common/TokenIcon";
import { TokenPickerModal } from "@/components/swap/TokenPickerModal";

const SLIPPAGE_BPS = 50;
const PCT_CHIPS = [25, 50, 75, 100] as const;

export function DepositTab() {
  const { activeTokens } = useTokens();
  const { address: account, isConnected } = useAccount();
  // L-5 (audit 2026-05-31): chain gating (mirrors ConnectButton). arcTestnet.id
  // === 5042002.
  const chainId = useChainId();
  const { switchChain, isPending: switchPending } = useSwitchChain();
  const wrongChain = isConnected && chainId !== arcTestnet.id;
  const [token, setToken] = useState<`0x${string}` | undefined>();
  const [amountStr, setAmountStr] = useState("");
  const [pickerOpen, setPickerOpen] = useState(false);

  // Derive default at render time; explicit picker selection takes over via setToken.
  const effectiveToken = token ?? activeTokens[0]?.address;

  const meta = activeTokens.find((t) => t.address === effectiveToken);
  const amount = useMemo(
    () => (meta && amountStr ? tryParseUnits(amountStr, meta.decimals) : null),
    [amountStr, meta],
  );

  const { data: balance } = useReadContract({
    address: effectiveToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!account && !!effectiveToken },
  });

  const { data: lpQuote } = useQuoteDeposit({
    token: effectiveToken,
    amount: amount ?? undefined,
  });

  const { mutate: deposit, isPending, error, data: result } = useDeposit();

  function setFromPct(pct: number) {
    if (!balance || !meta) return;
    setAmountStr(fmtUnits(((balance as bigint) * BigInt(pct)) / 100n, meta.decimals, meta.decimals));
  }

  function onDeposit() {
    if (!effectiveToken || !amount) return;
    deposit(
      { token: effectiveToken, amount, slippageBps: SLIPPAGE_BPS },
      { onSuccess: () => setAmountStr("") },
    );
  }

  const insufficient = !!amount && !!balance && amount > (balance as bigint);
  const ctaDisabled =
    !isConnected || wrongChain || !amount || amount === 0n || lpQuote == null || insufficient;

  return (
    <div className="space-y-3.5">
      <div className="bg-surface-tint border border-transparent rounded-[14px] px-4 py-3.5 transition-colors focus-within:border-arc-ink-200 focus-within:bg-surface">
        <div className="flex justify-between text-xs text-arc-ink-500">
          <span>Deposit</span>
          <span>
            Balance:{" "}
            <span className="t-mono">
              {balance != null && meta ? fmtUnits(balance as bigint, meta.decimals, 4) : "—"}
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
        {balance != null && meta ? (
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

      <div className="rounded-[14px] border border-arc-ink-100 bg-surface px-4 py-3 text-sm flex justify-between">
        <span className="text-arc-ink-500">You receive (estimate)</span>
        <span className="t-mono text-arc-ink-900">
          {lpQuote != null ? `${fmtUnits(lpQuote, 18, 4)} ADEX-LP` : "—"}
        </span>
      </div>

      {/* L-5: switch-chain CTA when on the wrong network. */}
      {wrongChain ? (
        <button
          onClick={() => switchChain({ chainId: arcTestnet.id })}
          disabled={switchPending}
          className="w-full inline-flex items-center justify-center h-13 rounded-full text-[15px] font-medium text-white mt-1 transition-all disabled:opacity-50"
          style={{ background: "var(--grad-arcora)", boxShadow: "var(--shadow-glow)" }}
        >
          {switchPending ? "Switching…" : "Switch to Arc Testnet"}
        </button>
      ) : (
        <button
          onClick={onDeposit}
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
            : !amount || amount === 0n
              ? "Enter an amount"
              : insufficient
                ? `Insufficient ${meta?.symbol} balance`
                : isPending
                  ? "Depositing…"
                  : `Deposit ${meta?.symbol}`}
        </button>
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

      <TokenPickerModal
        open={pickerOpen}
        onOpenChange={setPickerOpen}
        tokens={activeTokens}
        onSelect={(addr) => {
          setToken(addr);
          setPickerOpen(false);
        }}
      />
    </div>
  );
}
