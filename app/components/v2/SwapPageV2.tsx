"use client";
import { useEffect, useMemo, useState } from "react";
import { useAccount, useReadContract, useChainId, useSwitchChain } from "wagmi";
import { erc20Abi } from "viem";
import { fmtUnits, tryParseUnits } from "@arcoralabs/dex-sdk";
import {
  useQuoteSwapV2,
  useReserveHealth,
  useMaxSwapOut,
  useSwapV2,
} from "@arcoralabs/dex-sdk/react/v2";
import type { TokenInfoV2 } from "@arcoralabs/dex-sdk/v2";
import { Card } from "@/components/ds/Card";
import { Button } from "@/components/ds/Button";
import { Icon } from "@/components/ds/Icon";
import { CoinBadge } from "@/components/ds/CoinBadge";
import { TokenSelectModal } from "@/components/ds/TokenSelectModal";
import { tokenColor } from "@/components/ds/tokens";
import { iconBtnStyle } from "@/components/ds/iconBtnStyle";
import { ACTIVE_CHAIN, EXPLORER } from "@/lib/chain";
import { pushToast } from "@/components/layout/toast-store";
import { useTokensV2 } from "./useTokensV2";
import { useMaxGuard } from "./useMaxGuard";
import { ReserveHealthBar } from "./ReserveHealthBar";
import { DynamicFeeRow } from "./DynamicFeeRow";

const SLIPPAGE_PRESETS = [0.1, 0.5, 1.0] as const;

/** True when a SDK/query error is the §9 oracle-unsafe signal. */
function isOracleUnsafe(err: Error | null): boolean {
  return !!err && err.name === "OracleUnsafeError";
}

/**
 * SwapPageV2 — the prototype's CLASSIC swap card wired to the V2 SDK, with the
 * full §9 surface:
 *   - reserve-health bar for the OUTPUT token + its post-swap marker,
 *   - estimated dynamic (marginal) fee from the quote's feeUsd1e18,
 *   - a floor-safe Max (maxSwapOut + applyMaxGuard) with an over-max WARN that
 *     blocks submit,
 *   - quote refresh immediately before submit (the SDK action re-quotes; the CTA
 *     is additionally gated while the quote is stale/loading),
 *   - oracle-unsafe handling (swap disabled with a clear message).
 */
export function SwapPageV2() {
  const { tokens } = useTokensV2();
  const { address: account, isConnected } = useAccount();
  const chainId = useChainId();
  const { switchChain, isPending: switchPending } = useSwitchChain();
  const wrongChain = isConnected && chainId !== ACTIVE_CHAIN.id;

  const [tokenIn, setTokenIn] = useState<`0x${string}` | undefined>();
  const [tokenOut, setTokenOut] = useState<`0x${string}` | undefined>();
  const [amountStr, setAmountStr] = useState("");
  const [picker, setPicker] = useState<"in" | "out" | null>(null);
  const [slippagePct, setSlippagePct] = useState(0.5);
  const [slippageOpen, setSlippageOpen] = useState(false);
  const [flipDeg, setFlipDeg] = useState(0);

  // Defaults derived at render time (no set-state-in-effect); explicit picks win.
  const effIn = tokenIn ?? tokens[0]?.address;
  const effOut = tokenOut ?? tokens[1]?.address;
  const inMeta = tokens.find((t) => t.address === effIn);
  const outMeta = tokens.find((t) => t.address === effOut);

  const amountIn = useMemo(
    () => (inMeta && amountStr ? tryParseUnits(amountStr, inMeta.decimals) : null),
    [amountStr, inMeta],
  );

  const { data: balanceIn } = useReadContract({
    address: effIn,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!account && !!effIn },
  });
  const { data: balanceOut } = useReadContract({
    address: effOut,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!account && !!effOut },
  });

  const {
    data: quote,
    isFetching,
    error: quoteError,
  } = useQuoteSwapV2({ tokenIn: effIn, tokenOut: effOut, amountIn: amountIn ?? undefined });
  const { data: health, error: healthError } = useReserveHealth({ tokenOut: effOut });
  const { data: maxOut, error: maxError } = useMaxSwapOut({ tokenOut: effOut });
  const swap = useSwapV2();

  const [txHash, setTxHash] = useState<`0x${string}` | null>(null);
  // Clear the success banner whenever the user starts a new trade.
  useEffect(() => {
    if (amountStr === "") return;
    setTxHash(null);
  }, [amountStr]);

  // §9: the output token's oracle is unsafe → swap is unavailable. The signal can
  // surface on any of the output-keyed reads or on the swap mutation itself.
  const oracleUnsafe =
    isOracleUnsafe(quoteError) ||
    isOracleUnsafe(healthError) ||
    isOracleUnsafe(maxError) ||
    isOracleUnsafe(swap.error);

  // §9: over-max — maxSwapOut returns the floor-safe max OUTPUT; flag when the
  // quoted output would exceed it (advisory; the contract enforces the floor).
  const maxNetOut = maxOut?.netOut ?? null;
  const guard = useMaxGuard(quote?.amountOut ?? null, maxNetOut);
  const overMax = guard.overMax;

  const insufficient = !!amountIn && balanceIn != null && amountIn > (balanceIn as bigint);

  // §9: MAX = the floor-safe input. maxSwapOut is the max OUTPUT; the simplest
  // faithful advisory approach is to seed the input from the user's balance and
  // let the over-max guard surface if the resulting output exceeds the safe max
  // (the contract is the final enforcement layer).
  function setMax() {
    if (balanceIn == null || !inMeta) return;
    setAmountStr(fmtUnits(balanceIn as bigint, inMeta.decimals, inMeta.decimals));
  }
  function setHalf() {
    if (balanceIn == null || !inMeta) return;
    setAmountStr(fmtUnits((balanceIn as bigint) / 2n, inMeta.decimals, inMeta.decimals));
  }

  function flipTokens() {
    setTokenIn(effOut);
    setTokenOut(effIn);
    setAmountStr("");
    setFlipDeg((d) => d + 180);
  }

  // §9: advisory display gross ≈ output value + fee. The SDK quote returns no
  // gross, so approximate it as amountOut(USD-ish, normalized to 1e18) + fee for
  // the est.-fee percent only. TODO(gross): swap in a real gross if a later SDK
  // rev returns it.
  const grossForDisplay = useMemo(() => {
    if (!quote || !outMeta) return 0n;
    // amountOut normalized to 1e18 (treat the stable ≈ $1 for display).
    const out1e18 =
      outMeta.decimals <= 18
        ? quote.amountOut * 10n ** BigInt(18 - outMeta.decimals)
        : quote.amountOut / 10n ** BigInt(outMeta.decimals - 18);
    return out1e18 + quote.feeUsd1e18;
  }, [quote, outMeta]);

  const ctaDisabled =
    !isConnected ||
    wrongChain ||
    oracleUnsafe ||
    overMax ||
    isFetching ||
    !amountIn ||
    amountIn === 0n ||
    quote == null ||
    insufficient ||
    swap.isPending;

  async function onSwap() {
    if (!effIn || !effOut || !amountIn) return;
    setTxHash(null);
    try {
      const res = await swap.mutateAsync({
        tokenIn: effIn,
        tokenOut: effOut,
        amountIn,
        slippageBps: Math.round(slippagePct * 100),
        deadline: BigInt(Math.floor(Date.now() / 1000) + 20 * 60),
      });
      setTxHash(res.hash);
      pushToast({
        kind: "success",
        title: "Swap confirmed",
        msg:
          inMeta && outMeta ? `${inMeta.symbol} → ${outMeta.symbol}` : undefined,
        hash: res.hash,
      });
      setAmountStr("");
    } catch (err) {
      // The inline error message below still surfaces; also toast it (unless
      // it's the oracle-unsafe signal, which has its own dedicated banner).
      const e = err as Error;
      if (e?.name !== "OracleUnsafeError") {
        pushToast({ kind: "error", title: "Swap failed", msg: e?.message });
      }
    }
  }

  const outStr =
    quote != null && outMeta ? fmtUnits(quote.amountOut, outMeta.decimals, 6) : "";
  const rate =
    amountIn && quote && inMeta && outMeta && amountIn > 0n
      ? (
          Number(quote.amountOut) /
          10 ** outMeta.decimals /
          (Number(amountIn) / 10 ** inMeta.decimals)
        ).toFixed(5)
      : null;

  return (
    <div style={{ width: "min(440px, 94vw)", margin: "0 auto" }}>
      <Card pad={20} elev={2}>
        {/* Header + slippage popover */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            marginBottom: 14,
            position: "relative",
          }}
        >
          <div style={{ fontWeight: 700, fontSize: 18, letterSpacing: "-0.01em" }}>Swap</div>
          <div style={{ display: "flex", alignItems: "center", gap: 8, position: "relative" }}>
            {isFetching && (
              <span
                style={{ fontSize: 11, color: "var(--fg-3)", fontFamily: "var(--font-mono)" }}
              >
                Refreshing…
              </span>
            )}
            <button
              onClick={(e) => {
                e.stopPropagation();
                setSlippageOpen((o) => !o);
              }}
              style={{ ...iconBtnStyle, border: "1px solid var(--border)" }}
              aria-label="Settings"
            >
              <Icon name="settings" size={17} />
            </button>
            {slippageOpen && (
              <SlippagePopover
                slippagePct={slippagePct}
                setSlippagePct={setSlippagePct}
                onClose={() => setSlippageOpen(false)}
              />
            )}
          </div>
        </div>

        {/* Fields */}
        <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          <FieldBox
            side="You pay"
            meta={inMeta}
            value={amountStr}
            onChange={(v) => setAmountStr(v.replace(/[^0-9.]/g, ""))}
            balance={balanceIn as bigint | undefined}
            connected={isConnected}
            onMax={setMax}
            onHalf={setHalf}
            onPickToken={() => setPicker("in")}
          />
          <FlipBtn onClick={flipTokens} deg={flipDeg} />
          <FieldBox
            side="You receive"
            meta={outMeta}
            value={outStr}
            readOnly
            balance={balanceOut as bigint | undefined}
            connected={isConnected}
            onPickToken={() => setPicker("out")}
          />
        </div>

        {/* Detail block — §9 surface */}
        <div
          style={{
            margin: "16px 0",
            padding: "14px 16px",
            background: "var(--surface-2)",
            borderRadius: "var(--radius-lg)",
            border: "1px solid var(--border)",
            display: "flex",
            flexDirection: "column",
            gap: 12,
          }}
        >
          {/* §9: reserve-health bar for the OUTPUT token + post-swap marker */}
          {health && !oracleUnsafe && (
            <ReserveHealthBar
              healthBps={health.healthBps}
              postHealthBps={quote?.postHealthBps}
              symbol={outMeta?.symbol}
            />
          )}

          <div style={{ display: "flex", flexDirection: "column", gap: 9 }}>
            <DetailRow
              label="Rate"
              value={
                rate ? (
                  <span style={{ fontFamily: "var(--font-mono)" }}>
                    1 {inMeta?.symbol} = {rate} {outMeta?.symbol}
                  </span>
                ) : (
                  "—"
                )
              }
            />
            {/* §9: estimated dynamic (marginal) fee from quote.feeUsd1e18 */}
            {quote ? (
              <DynamicFeeRow
                feeUsd1e18={quote.feeUsd1e18}
                grossUsd1e18={grossForDisplay}
                bands={outMeta?.bands}
              />
            ) : (
              <DetailRow label="Est. fee" value="—" />
            )}
            <DetailRow label="Slippage" value={`${slippagePct}%`} />
            <DetailRow label="Network fee" value="~$0.001" />
          </div>

          {/* §9: over-max warning — never submits */}
          {overMax && maxNetOut != null && outMeta && (
            <WarnRow>
              Amount exceeds the floor-safe maximum (
              {fmtUnits(maxNetOut, outMeta.decimals, 2)} {outMeta.symbol}) — reduce or it
              will revert.
            </WarnRow>
          )}
          {/* §9: oracle-unsafe — swap disabled with a clear message */}
          {oracleUnsafe && outMeta && (
            <WarnRow tone="danger">
              {outMeta.symbol} oracle is currently unsafe — swaps to this token are paused.
              Try a different token.
            </WarnRow>
          )}
        </div>

        {/* CTA */}
        {!isConnected ? (
          <Button variant="brand" size="lg" full icon="wallet">
            Connect wallet
          </Button>
        ) : wrongChain ? (
          <Button
            variant="primary"
            size="lg"
            full
            disabled={switchPending}
            onClick={() => switchChain({ chainId: ACTIVE_CHAIN.id })}
          >
            {switchPending ? "Switching…" : `Switch to ${ACTIVE_CHAIN.name}`}
          </Button>
        ) : swap.isPending ? (
          <Button variant="primary" size="lg" full disabled>
            <span
              className="ar-spin"
              style={{
                width: 18,
                height: 18,
                border: "2.5px solid rgba(22,36,26,.3)",
                borderTopColor: "var(--fg-on-accent)",
                borderRadius: "50%",
                display: "inline-block",
              }}
            />
            Swapping…
          </Button>
        ) : (
          <Button
            variant={ctaDisabled ? "secondary" : "primary"}
            size="lg"
            full
            icon={ctaDisabled ? undefined : "swap"}
            disabled={ctaDisabled}
            onClick={onSwap}
          >
            {ctaLabel({
              amountIn,
              insufficient,
              overMax,
              oracleUnsafe,
              isFetching,
              inSym: inMeta?.symbol,
              outSym: outMeta?.symbol,
            })}
          </Button>
        )}

        {/* Status */}
        {txHash && (
          <p
            style={{
              fontSize: 12,
              textAlign: "center",
              marginTop: 12,
              color: "var(--success)",
            }}
          >
            Swap confirmed ·{" "}
            <a
              href={`${EXPLORER}/tx/${txHash}`}
              target="_blank"
              rel="noreferrer"
              style={{ textDecoration: "underline" }}
            >
              view tx
            </a>
          </p>
        )}
        {swap.error && !oracleUnsafe && (
          <p
            style={{
              fontSize: 12,
              textAlign: "center",
              marginTop: 12,
              color: "var(--danger)",
            }}
          >
            {swap.error.message}
          </p>
        )}
      </Card>

      <TokenSelectModal
        open={picker !== null}
        onClose={() => setPicker(null)}
        tokens={tokens}
        exclude={picker === "in" ? effOut : effIn}
        onPick={(addr) => {
          if (picker === "in") setTokenIn(addr === effOut ? effIn : addr);
          else setTokenOut(addr === effIn ? effOut : addr);
          setPicker(null);
        }}
      />
    </div>
  );
}

// ---- Pieces -------------------------------------------------------------

function ctaLabel({
  amountIn,
  insufficient,
  overMax,
  oracleUnsafe,
  isFetching,
  inSym,
  outSym,
}: {
  amountIn: bigint | null;
  insufficient: boolean;
  overMax: boolean;
  oracleUnsafe: boolean;
  isFetching: boolean;
  inSym?: string;
  outSym?: string;
}): string {
  if (oracleUnsafe) return "Swap unavailable";
  if (!amountIn || amountIn === 0n) return "Enter an amount";
  if (insufficient) return `Insufficient ${inSym} balance`;
  if (overMax) return "Exceeds floor-safe max";
  if (isFetching) return "Fetching quote…";
  return `Swap ${inSym} → ${outSym}`;
}

function FieldBox({
  side,
  meta,
  value,
  onChange,
  readOnly,
  balance,
  connected,
  onMax,
  onHalf,
  onPickToken,
}: {
  side: string;
  meta?: TokenInfoV2;
  value: string;
  onChange?: (v: string) => void;
  readOnly?: boolean;
  balance?: bigint;
  connected: boolean;
  onMax?: () => void;
  onHalf?: () => void;
  onPickToken: () => void;
}) {
  return (
    <div
      style={{
        background: "var(--surface-2)",
        borderRadius: "var(--radius-lg)",
        padding: "14px 16px",
      }}
    >
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          gap: 10,
          marginBottom: 8,
        }}
      >
        <span className="overline" style={{ whiteSpace: "nowrap" }}>
          {side}
        </span>
        {connected && (
          <span
            style={{
              fontSize: 12,
              color: "var(--fg-3)",
              fontFamily: "var(--font-mono)",
              whiteSpace: "nowrap",
            }}
          >
            Balance {balance != null && meta ? fmtUnits(balance, meta.decimals, 2) : "—"}
          </span>
        )}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <input
          value={value}
          onChange={onChange ? (e) => onChange(e.target.value) : undefined}
          readOnly={readOnly}
          placeholder="0.0"
          inputMode="decimal"
          style={{
            flex: 1,
            minWidth: 0,
            border: "none",
            background: "transparent",
            outline: "none",
            fontFamily: "var(--font-sans)",
            fontWeight: 600,
            fontSize: 30,
            letterSpacing: "-0.02em",
            color: value ? "var(--fg-1)" : "var(--fg-3)",
            padding: 0,
          }}
        />
        <TokenChip meta={meta} onClick={onPickToken} />
      </div>
      <div
        style={{
          display: "flex",
          justifyContent: "flex-end",
          alignItems: "center",
          marginTop: 8,
          minHeight: 20,
        }}
      >
        {!readOnly && connected && (
          <span style={{ display: "flex", gap: 6 }}>
            <MiniBtn onClick={onHalf}>50%</MiniBtn>
            <MiniBtn onClick={onMax}>MAX</MiniBtn>
          </span>
        )}
      </div>
    </div>
  );
}

function TokenChip({ meta, onClick }: { meta?: TokenInfoV2; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 8,
        flexShrink: 0,
        height: 40,
        padding: "0 10px 0 7px",
        borderRadius: "var(--radius-pill)",
        border: "1px solid var(--border)",
        background: "var(--surface)",
        cursor: "pointer",
        boxShadow: "var(--elev-1)",
      }}
    >
      {meta ? (
        <CoinBadge sym={meta.symbol} color={tokenColor(meta.symbol)} size={26} />
      ) : (
        <span style={{ width: 26, height: 26 }} />
      )}
      <span style={{ fontWeight: 700, fontSize: 15, letterSpacing: "-0.01em" }}>
        {meta?.symbol ?? "Select"}
      </span>
      <Icon name="chevronDown" size={16} style={{ color: "var(--fg-3)" }} />
    </button>
  );
}

function MiniBtn({ children, onClick }: { children: React.ReactNode; onClick?: () => void }) {
  return (
    <button
      onClick={onClick}
      style={{
        padding: "2px 8px",
        fontSize: 11,
        fontWeight: 700,
        fontFamily: "var(--font-mono)",
        color: "var(--action)",
        background: "rgba(200,242,74,.14)",
        border: "1px solid rgba(200,242,74,.3)",
        borderRadius: "var(--radius-sm)",
        cursor: "pointer",
      }}
    >
      {children}
    </button>
  );
}

function FlipBtn({ onClick, deg }: { onClick: () => void; deg: number }) {
  return (
    <div style={{ display: "grid", placeItems: "center", height: 0, position: "relative", zIndex: 5 }}>
      <button
        onClick={onClick}
        aria-label="Switch direction"
        style={{
          width: 40,
          height: 40,
          borderRadius: "var(--radius-md)",
          display: "grid",
          placeItems: "center",
          background: "var(--surface)",
          border: "3px solid var(--bg)",
          color: "var(--fg-1)",
          cursor: "pointer",
          boxShadow: "var(--elev-2)",
          transform: `rotate(${deg}deg)`,
          transition: "transform .26s var(--ease-emphasized), color var(--dur-fast)",
        }}
        onMouseEnter={(e) => {
          e.currentTarget.style.color = "var(--accent)";
        }}
        onMouseLeave={(e) => {
          e.currentTarget.style.color = "var(--fg-1)";
        }}
      >
        <Icon name="swap" size={18} />
      </button>
    </div>
  );
}

function DetailRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div
      style={{
        display: "flex",
        justifyContent: "space-between",
        alignItems: "center",
        gap: 12,
        fontSize: 13,
      }}
    >
      <span style={{ color: "var(--fg-3)", flexShrink: 0, whiteSpace: "nowrap" }}>{label}</span>
      <span
        style={{
          color: "var(--fg-2)",
          fontWeight: 500,
          whiteSpace: "nowrap",
          fontSize: 12.5,
          textAlign: "right",
        }}
      >
        {value}
      </span>
    </div>
  );
}

function WarnRow({
  children,
  tone = "warning",
}: {
  children: React.ReactNode;
  tone?: "warning" | "danger";
}) {
  const color = tone === "danger" ? "var(--danger)" : "var(--warning)";
  const bg = tone === "danger" ? "var(--danger-bg)" : "var(--warning-bg)";
  return (
    <div
      style={{
        display: "flex",
        alignItems: "flex-start",
        gap: 8,
        padding: "10px 12px",
        background: bg,
        borderRadius: "var(--radius-md)",
        fontSize: 12.5,
        lineHeight: 1.4,
        color,
      }}
    >
      <Icon name="info" size={15} style={{ flexShrink: 0, marginTop: 1 }} />
      <span>{children}</span>
    </div>
  );
}

function SlippagePopover({
  slippagePct,
  setSlippagePct,
  onClose,
}: {
  slippagePct: number;
  setSlippagePct: (n: number) => void;
  onClose: () => void;
}) {
  useEffect(() => {
    const c = () => onClose();
    window.addEventListener("click", c);
    return () => window.removeEventListener("click", c);
  }, [onClose]);
  return (
    <div
      onClick={(e) => e.stopPropagation()}
      style={{
        position: "absolute",
        top: 46,
        right: 0,
        zIndex: 30,
        width: 256,
        background: "var(--surface)",
        border: "1px solid var(--border)",
        borderRadius: "var(--radius-lg)",
        boxShadow: "var(--elev-3)",
        padding: 16,
        animation: "ar-pop .2s var(--ease-standard)",
      }}
    >
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 10 }}>Slippage tolerance</div>
      <div style={{ display: "flex", gap: 6 }}>
        {SLIPPAGE_PRESETS.map((p) => (
          <button
            key={p}
            onClick={() => setSlippagePct(p)}
            style={{
              flex: 1,
              height: 36,
              borderRadius: "var(--radius-md)",
              fontSize: 13,
              fontWeight: 600,
              cursor: "pointer",
              fontFamily: "var(--font-mono)",
              border: slippagePct === p ? "1px solid var(--accent)" : "1px solid var(--border)",
              background: slippagePct === p ? "rgba(200,242,74,.16)" : "var(--surface-2)",
              color: slippagePct === p ? "var(--action)" : "var(--fg-2)",
            }}
          >
            {p}%
          </button>
        ))}
      </div>
      {slippagePct >= 3 && (
        <div style={{ marginTop: 10, fontSize: 12, color: "var(--warning)" }}>
          High slippage — your trade may be front-run.
        </div>
      )}
    </div>
  );
}
