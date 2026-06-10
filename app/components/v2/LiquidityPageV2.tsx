"use client";
import { useEffect, useMemo, useState } from "react";
import { useAccount, useReadContract, useChainId, useSwitchChain } from "wagmi";
import { erc20Abi } from "viem";
import { fmtUnits, fmtUSD, tryParseUnits } from "@arcoralabs/dex-sdk";
import {
  useQuoteWithdrawV2,
  useMaxWithdraw,
  useReserveHealth,
  useDepositV2,
  useWithdrawSingleV2,
  useWithdrawProportionalV2,
} from "@arcoralabs/dex-sdk/react/v2";
import type { TokenInfoV2 } from "@arcoralabs/dex-sdk/v2";
import { Card } from "@/components/ds/Card";
import { Button } from "@/components/ds/Button";
import { Pill } from "@/components/ds/Pill";
import { Overline } from "@/components/ds/Overline";
import { Icon } from "@/components/ds/Icon";
import { CoinBadge } from "@/components/ds/CoinBadge";
import { AnimatedNumber } from "@/components/ds/AnimatedNumber";
import { TokenSelectModal } from "@/components/ds/TokenSelectModal";
import { tokenColor } from "@/components/ds/tokens";
import { ACTIVE_CHAIN, EXPLORER } from "@/lib/chain";
import { pushToast } from "@/components/layout/toast-store";
import { useTokensV2 } from "./useTokensV2";
import { usePoolStatsV2 } from "./usePoolStatsV2";
import { useLpPosition } from "./useLpPosition";
import { useOraclePrices } from "./useOraclePrices";
import { useReserves } from "./useReserves";
import { reserveUsd1e18, depositCapHeadroom, exceedsCap, type CapHeadroom } from "./lp-math";
import { useMaxGuard } from "./useMaxGuard";
import { ReserveHealthBar } from "./ReserveHealthBar";
import { DynamicFeeRow } from "./DynamicFeeRow";

type Tab = "deposit" | "withdraw";
const SLIPPAGE_BPS = 50; // 0.5% — matches the swap card default.

/** True when an SDK/query error is the §11 oracle-unsafe signal. */
function isOracleUnsafe(err: Error | null): boolean {
  return !!err && err.name === "OracleUnsafeError";
}

/** USD-per-LP from the 1e18 LP price; null when supply is empty. */
function lpPriceNum(lpPriceUsd1e18: bigint | undefined): number | null {
  if (lpPriceUsd1e18 == null || lpPriceUsd1e18 === 0n) return null;
  return Number(lpPriceUsd1e18) / 1e18;
}

/**
 * LiquidityPageV2 — the prototype two-pane deposit/withdraw layout wired to the
 * V2 SDK, with §8.2 single-token withdraw (floor-gated Max + reserve-health +
 * dynamic fee), §8.3/§11 proportional emergency exit (auto-promoted on an unsafe
 * oracle), and the GF-3/GF-4 reachability fills:
 *   - GF-3: the connected wallet's LP balance + USD value + pool share (drives
 *     the withdraw Max),
 *   - GF-4: each token's depositCapUsd headroom, with deposit disabled +
 *     "cap reached" when at/near cap (contract DepositCapExceeded is the backstop).
 */
export function LiquidityPageV2() {
  const { tokens } = useTokensV2();
  const { stats } = usePoolStatsV2();
  const { prices } = useOraclePrices(tokens);
  const { reserves } = useReserves(tokens);
  const pos = useLpPosition(stats);

  const { address: account, isConnected } = useAccount();
  const chainId = useChainId();
  const { switchChain, isPending: switchPending } = useSwitchChain();
  const wrongChain = isConnected && chainId !== ACTIVE_CHAIN.id;

  const [tab, setTab] = useState<Tab>("deposit");
  const [tokenAddr, setTokenAddr] = useState<`0x${string}` | undefined>();
  const [amt, setAmt] = useState("");
  const [picker, setPicker] = useState(false);
  const [proportional, setProportional] = useState(false);
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null);

  const effAddr = tokenAddr ?? tokens[0]?.address;
  const meta = tokens.find((t) => t.address === effAddr);
  const price = effAddr ? prices[effAddr.toLowerCase()] : undefined;
  const lpPrice = lpPriceNum(stats?.lpPriceUsd1e18);

  // Reset transient UI when switching tab/token/amount.
  useEffect(() => {
    setTxHash(null);
  }, [tab, effAddr, amt]);

  // ── Deposit math ──────────────────────────────────────────────────────
  const depositAmount = useMemo(
    () => (meta && amt ? tryParseUnits(amt, meta.decimals) : null),
    [amt, meta],
  );
  const { data: tokenBalance } = useReadContract({
    address: effAddr,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!account && !!effAddr },
  });

  // USD value of the entered deposit (token amount × oracle price).
  const depositUsd1e18 = useMemo(() => {
    if (!depositAmount || !meta || !price || price.price1e18 === 0n) return 0n;
    return reserveUsd1e18(depositAmount, meta.decimals, price.price1e18);
  }, [depositAmount, meta, price]);

  // GF-4: deposit-cap headroom = depositCapUsd − current reserve USD.
  const capState = useMemo<CapHeadroom | null>(() => {
    if (!meta) return null;
    const raw = reserves[meta.address.toLowerCase()] ?? 0n;
    const currentUsd1e18 =
      price && price.price1e18 > 0n ? reserveUsd1e18(raw, meta.decimals, price.price1e18) : 0n;
    return depositCapHeadroom(meta.depositCapUsd, currentUsd1e18);
  }, [meta, reserves, price]);
  const overCap = tab === "deposit" && exceedsCap(depositUsd1e18, capState);
  const capReached = tab === "deposit" && capState != null && capState.reached;

  // Advisory LP minted ≈ depositUsd / lpPrice (the V2 pool exposes no deposit quote).
  const lpMintedEst = useMemo(() => {
    if (depositUsd1e18 === 0n || !lpPrice) return 0;
    return Number(depositUsd1e18) / 1e18 / lpPrice;
  }, [depositUsd1e18, lpPrice]);
  const poolShareAfter =
    stats && stats.navUsd1e18 > 0n && depositUsd1e18 > 0n
      ? (Number(depositUsd1e18) / (Number(stats.navUsd1e18) + Number(depositUsd1e18))) * 100
      : 0;

  // ── Withdraw math ─────────────────────────────────────────────────────
  // The withdraw input is denominated in LP tokens (18 dp).
  const lpAmount = useMemo(
    () => (tab === "withdraw" && amt ? tryParseUnits(amt, 18) : null),
    [amt, tab],
  );
  const { data: quote, isFetching: quoteFetching, error: quoteError } = useQuoteWithdrawV2(
    { tokenOut: effAddr, lpAmount: lpAmount ?? undefined },
    { enabled: tab === "withdraw" && !proportional },
  );
  const { data: maxW, error: maxWError } = useMaxWithdraw(
    { tokenOut: effAddr, account },
    { enabled: tab === "withdraw" && !proportional && !!account },
  );
  const { data: health, error: healthError } = useReserveHealth(
    { tokenOut: effAddr },
    { enabled: tab === "withdraw" && !proportional },
  );

  const deposit = useDepositV2();
  const withdrawSingle = useWithdrawSingleV2();
  const withdrawProp = useWithdrawProportionalV2();

  // §11: detect oracle-unsafe on the withdraw token. Surfaces on any of the
  // output-keyed reads or on a single-withdraw attempt → promote proportional.
  const oracleUnsafe =
    tab === "withdraw" &&
    (isOracleUnsafe(quoteError) ||
      isOracleUnsafe(maxWError) ||
      isOracleUnsafe(healthError) ||
      isOracleUnsafe(withdrawSingle.error) ||
      (price != null && price.safe === false));
  // Auto-promote the proportional pane the moment we learn the oracle is unsafe.
  useEffect(() => {
    if (oracleUnsafe) setProportional(true);
  }, [oracleUnsafe]);

  // GF-3: the withdraw Max is the floor-safe max LP (from maxWithdraw), further
  // clamped to the wallet's LP balance.
  const maxLp = useMemo(() => {
    if (maxW == null) return null;
    if (pos.balance == null) return maxW.lpAmount;
    return maxW.lpAmount < pos.balance ? maxW.lpAmount : pos.balance;
  }, [maxW, pos.balance]);
  const guard = useMaxGuard(lpAmount, maxLp);
  const overMax = tab === "withdraw" && !proportional && guard.overMax;

  const depositInsufficient =
    tab === "deposit" && !!depositAmount && tokenBalance != null && depositAmount > (tokenBalance as bigint);
  const withdrawInsufficient =
    tab === "withdraw" && !!lpAmount && pos.balance != null && lpAmount > pos.balance;

  function setMax() {
    if (tab === "deposit") {
      if (tokenBalance == null || !meta) return;
      setAmt(fmtUnits(tokenBalance as bigint, meta.decimals, meta.decimals));
    } else {
      // Floor-safe LP max (clamped to balance); falls back to balance if max not loaded.
      const m = maxLp ?? pos.balance;
      if (m == null) return;
      setAmt(fmtUnits(m, 18, 18));
    }
  }

  // ── Submit handlers ───────────────────────────────────────────────────
  async function onDeposit() {
    if (!effAddr || !depositAmount) return;
    setTxHash(null);
    try {
      const res = await deposit.mutateAsync({
        token: effAddr,
        amount: depositAmount,
        minLpOut: 0n, // advisory UI; contract enforces via InsufficientLpOut.
        deadline: BigInt(Math.floor(Date.now() / 1000) + 20 * 60),
      });
      setTxHash(res.hash);
      pushToast({
        kind: "success",
        title: "Liquidity added",
        msg: meta
          ? `Deposited ${amt} ${meta.symbol} · +${fmtUnits(res.lpMinted, 18, 2)} LP`
          : undefined,
        hash: res.hash,
      });
      setAmt("");
    } catch (err) {
      const e = err as Error;
      pushToast({ kind: "error", title: "Deposit failed", msg: e?.message });
    }
  }

  async function onWithdrawSingle() {
    if (!effAddr || !lpAmount) return;
    setTxHash(null);
    try {
      const res = await withdrawSingle.mutateAsync({
        tokenOut: effAddr,
        lpAmount,
        slippageBps: SLIPPAGE_BPS,
        deadline: BigInt(Math.floor(Date.now() / 1000) + 20 * 60),
      });
      setTxHash(res.hash);
      pushToast({
        kind: "success",
        title: "Withdrawal complete",
        msg: meta ? `Withdrew ${amt} LP → ${fmtUnits(res.amountOut, meta.decimals, 2)} ${meta.symbol}` : undefined,
        hash: res.hash,
      });
      setAmt("");
    } catch (err) {
      const e = err as Error;
      // The oracle-unsafe banner takes over; promote proportional instead of toasting.
      if (e?.name === "OracleUnsafeError") {
        setProportional(true);
      } else {
        pushToast({ kind: "error", title: "Withdrawal failed", msg: e?.message });
      }
    }
  }

  async function onWithdrawProportional() {
    if (!lpAmount) return;
    setTxHash(null);
    try {
      const res = await withdrawProp.mutateAsync({
        lpAmount,
        deadline: BigInt(Math.floor(Date.now() / 1000) + 20 * 60),
      });
      setTxHash(res.hash);
      pushToast({
        kind: "success",
        title: "Proportional exit complete",
        msg: `Burned ${amt} LP for a pro-rata share of all reserves`,
        hash: res.hash,
      });
      setAmt("");
    } catch (err) {
      const e = err as Error;
      pushToast({ kind: "error", title: "Proportional exit failed", msg: e?.message });
    }
  }

  // ── Derived display values ────────────────────────────────────────────
  const balanceShown =
    tab === "deposit"
      ? tokenBalance != null && meta
        ? fmtUnits(tokenBalance as bigint, meta.decimals, 2)
        : "—"
      : pos.balance != null
        ? fmtUnits(pos.balance, 18, 2)
        : "—";
  const withdrawOut =
    quote != null && meta ? `${fmtUnits(quote.amountOut, meta.decimals, 2)} ${meta.symbol}` : "—";

  const busy = deposit.isPending || withdrawSingle.isPending || withdrawProp.isPending;

  return (
    <div
      style={{
        width: "min(1060px, 96vw)",
        margin: "0 auto",
        display: "grid",
        gridTemplateColumns: "minmax(0, 460px) minmax(0, 1fr)",
        gap: 20,
        alignItems: "start",
      }}
    >
      {/* LEFT — action card */}
      <Card pad={20} elev={2}>
        {/* Tab pill */}
        <div
          style={{
            display: "flex",
            gap: 4,
            padding: 4,
            background: "var(--surface-2)",
            borderRadius: "var(--radius-md)",
            marginBottom: 18,
          }}
        >
          {(["deposit", "withdraw"] as Tab[]).map((t) => (
            <button
              key={t}
              onClick={() => {
                setTab(t);
                setAmt("");
                setProportional(false);
              }}
              style={{
                flex: 1,
                height: 38,
                borderRadius: "var(--radius-sm)",
                border: "none",
                cursor: "pointer",
                fontSize: 14,
                fontWeight: 600,
                textTransform: "capitalize",
                fontFamily: "var(--font-sans)",
                background: tab === t ? "var(--surface)" : "transparent",
                color: tab === t ? "var(--fg-1)" : "var(--fg-3)",
                boxShadow: tab === t ? "var(--elev-1)" : "none",
                transition: "all var(--dur-base)",
              }}
            >
              {t}
            </button>
          ))}
        </div>

        {/* Amount field */}
        <div
          style={{
            background: "var(--surface-2)",
            border: "1px solid var(--border)",
            borderRadius: "var(--radius-lg)",
            padding: "14px 16px",
            marginBottom: 8,
          }}
        >
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
            <span className="overline">{tab === "deposit" ? "Deposit" : "Withdraw as"}</span>
            {isConnected && (
              <span style={{ fontSize: 12, color: "var(--fg-3)", fontFamily: "var(--font-mono)" }}>
                Balance {balanceShown}
              </span>
            )}
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <input
              value={amt}
              onChange={(e) => setAmt(e.target.value.replace(/[^0-9.]/g, ""))}
              placeholder="0.0"
              inputMode="decimal"
              style={{
                flex: 1,
                minWidth: 0,
                border: "none",
                background: "transparent",
                outline: "none",
                fontWeight: 600,
                fontSize: 30,
                letterSpacing: "-0.02em",
                color: amt ? "var(--fg-1)" : "var(--fg-3)",
                fontFamily: "var(--font-sans)",
              }}
            />
            <button
              onClick={() => setPicker(true)}
              style={{
                display: "inline-flex",
                alignItems: "center",
                gap: 8,
                height: 40,
                padding: "0 10px 0 7px",
                borderRadius: "var(--radius-pill)",
                border: "1px solid var(--border)",
                background: "var(--surface)",
                cursor: "pointer",
                boxShadow: "var(--elev-1)",
                flexShrink: 0,
              }}
            >
              {meta ? (
                <CoinBadge sym={meta.symbol} color={tokenColor(meta.symbol)} size={26} />
              ) : (
                <span style={{ width: 26, height: 26 }} />
              )}
              <span style={{ fontWeight: 700, fontSize: 15 }}>{meta?.symbol ?? "Select"}</span>
              {tab === "deposit" && <Icon name="chevronDown" size={16} style={{ color: "var(--fg-3)" }} />}
            </button>
          </div>
          <div
            style={{
              marginTop: 6,
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
              gap: 8,
            }}
          >
            <span style={{ fontSize: 12.5, color: "var(--fg-3)", fontFamily: "var(--font-mono)" }}>
              {tab === "deposit"
                ? `≈ ${fmtUSD(depositUsd1e18)}`
                : quote != null && meta
                  ? `≈ ${fmtUnits(quote.amountOut, meta.decimals, 2)} ${meta.symbol}`
                  : "≈ —"}
            </span>
            {isConnected && (
              <button
                onClick={setMax}
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
                MAX
              </button>
            )}
          </div>
        </div>

        {/* §8.2 single-token info banner */}
        {tab === "withdraw" && !proportional && meta && (
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 8,
              padding: "10px 14px",
              marginBottom: 8,
              background: "rgba(200,242,74,.1)",
              border: "1px solid rgba(200,242,74,.26)",
              borderRadius: "var(--radius-md)",
              fontSize: 12.5,
              color: "var(--fg-2)",
            }}
          >
            <Icon name="zap" size={15} style={{ color: "var(--action)" }} />
            Single-token withdraw — redeem entirely in {meta.symbol} at the oracle price, no manual
            rebalancing.
          </div>
        )}

        {/* §11 oracle-unsafe promotion banner */}
        {tab === "withdraw" && oracleUnsafe && meta && (
          <div
            style={{
              display: "flex",
              alignItems: "flex-start",
              gap: 8,
              padding: "10px 14px",
              marginBottom: 8,
              background: "var(--danger-bg)",
              borderRadius: "var(--radius-md)",
              fontSize: 12.5,
              lineHeight: 1.45,
              color: "var(--danger)",
            }}
          >
            <Icon name="shield" size={15} style={{ flexShrink: 0, marginTop: 1 }} />
            <span>
              {meta.symbol}&rsquo;s oracle is currently unsafe — single-token withdrawal is paused.
              You can still exit proportionally (a pro-rata share of all reserves).
            </span>
          </div>
        )}

        {/* Detail block */}
        <div
          style={{
            padding: "14px 16px",
            background: "var(--surface-2)",
            borderRadius: "var(--radius-lg)",
            border: "1px solid var(--border)",
            display: "flex",
            flexDirection: "column",
            gap: 11,
            margin: "8px 0 16px",
          }}
        >
          {tab === "deposit" ? (
            <>
              <StatLine label="LP tokens minted" value={`+${lpMintedEst.toLocaleString("en-US", { maximumFractionDigits: 2 })}`} tone="var(--action)" />
              <StatLine label="Pool share" value={`${poolShareAfter.toFixed(4)}%`} />
              <StatLine label="LP price" value={lpPrice != null ? `$${lpPrice.toFixed(5)}` : "—"} />
              {/* GF-4: deposit-cap headroom */}
              {capState != null && (
                <StatLine
                  label="Deposit cap headroom"
                  value={`${fmtUSD(capState.headroomUsd1e18 > 0n ? capState.headroomUsd1e18 : 0n)} / ${fmtUSD(capState.capUsd1e18)}`}
                  tone={capReached || overCap ? "var(--danger)" : "var(--fg-1)"}
                />
              )}
            </>
          ) : proportional ? (
            <>
              <StatLine label="You receive" value="Pro-rata share of all reserves" tone="var(--action)" />
              <StatLine label="LP burned" value={amt ? `${amt} LP` : "—"} />
              <StatLine label="Oracle pricing" value="Not required" />
              <StatLine label="Network fee" value="~$0.001" />
            </>
          ) : (
            <>
              {/* §9: reserve-health bar for the OUTPUT token + post-withdraw marker */}
              {health && (
                <ReserveHealthBar
                  healthBps={health.healthBps}
                  postHealthBps={quote?.postHealthBps}
                  symbol={meta?.symbol}
                />
              )}
              <StatLine label="You receive" value={withdrawOut} tone="var(--action)" />
              <StatLine
                label="Oracle price"
                value={price && price.price1e18 > 0n ? `$${(Number(price.price1e18) / 1e18).toFixed(4)}` : "—"}
              />
              {/* §9: estimated dynamic (marginal) fee from quote.feeUsd1e18 */}
              {quote ? (
                <DynamicFeeRow
                  feeUsd1e18={quote.feeUsd1e18}
                  grossUsd1e18={grossForWithdraw(quote.amountOut, meta, price?.price1e18) + quote.feeUsd1e18}
                  bands={meta?.bands}
                />
              ) : (
                <StatLine label="Est. fee" value="—" />
              )}
              <StatLine label="Network fee" value="~$0.001" />
            </>
          )}
        </div>

        {/* §9 over-max warning — never submits */}
        {overMax && maxLp != null && (
          <WarnRow>
            Amount exceeds the floor-safe maximum ({fmtUnits(maxLp, 18, 2)} LP) — reduce it or the
            withdrawal will revert.
          </WarnRow>
        )}
        {/* GF-4 cap-reached warning */}
        {(capReached || overCap) && capState != null && (
          <WarnRow tone="danger">
            {capReached
              ? `${meta?.symbol} has reached its deposit cap (${fmtUSD(capState.capUsd1e18)}). Deposits are paused for this token.`
              : `This deposit exceeds the remaining cap headroom (${fmtUSD(capState.headroomUsd1e18 > 0n ? capState.headroomUsd1e18 : 0n)}). Reduce the amount.`}
          </WarnRow>
        )}

        {/* Proportional-exit toggle (always available under the withdraw tab) */}
        {tab === "withdraw" && !oracleUnsafe && (
          <button
            onClick={() => setProportional((p) => !p)}
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              gap: 6,
              width: "100%",
              marginBottom: 12,
              padding: "8px 12px",
              background: "transparent",
              border: "1px dashed var(--border-strong)",
              borderRadius: "var(--radius-md)",
              color: "var(--fg-2)",
              fontSize: 12.5,
              fontWeight: 600,
              fontFamily: "var(--font-sans)",
              cursor: "pointer",
            }}
          >
            <Icon name="droplet" size={14} />
            {proportional ? "Use single-token withdraw" : "Emergency proportional exit"}
          </button>
        )}

        {/* CTA */}
        <ActionButton
          isConnected={isConnected}
          wrongChain={wrongChain}
          switchPending={switchPending}
          onSwitch={() => switchChain({ chainId: ACTIVE_CHAIN.id })}
          busy={busy}
          tab={tab}
          proportional={proportional}
          paused={stats?.paused === true}
          hasAmount={tab === "deposit" ? !!depositAmount && depositAmount > 0n : !!lpAmount && lpAmount > 0n}
          insufficient={depositInsufficient || withdrawInsufficient}
          insufficientSym={tab === "deposit" ? meta?.symbol : "LP"}
          overMax={overMax}
          capBlocked={capReached || !!overCap}
          quoteFetching={tab === "withdraw" && !proportional && quoteFetching}
          onDeposit={onDeposit}
          onWithdrawSingle={onWithdrawSingle}
          onWithdrawProportional={onWithdrawProportional}
        />

        {/* Status */}
        {txHash && (
          <p style={{ fontSize: 12, textAlign: "center", marginTop: 12, color: "var(--success)" }}>
            Confirmed ·{" "}
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
      </Card>

      {/* RIGHT — context cards */}
      <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
        <Card pad={20}>
          <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 14, marginBottom: 14 }}>
            <div style={{ minWidth: 0 }}>
              <Overline>LP rewards</Overline>
              <div style={{ fontWeight: 700, fontSize: 20, letterSpacing: "-0.01em", marginTop: 4, lineHeight: 1.25 }}>
                Earn 90% of every swap fee
              </div>
            </div>
            <Pill tone="accent" style={{ flexShrink: 0, whiteSpace: "nowrap" }}>
              <Icon name="trending" size={13} /> 90% to LPs
            </Pill>
          </div>
          <p style={{ margin: 0, fontSize: 13.5, color: "var(--fg-2)", lineHeight: 1.55 }}>
            ArcoraDEX routes{" "}
            <strong style={{ color: "var(--fg-1)" }}>{lpSharePct(stats?.protocolFeeShareBps)}%</strong> of the
            dynamic swap fee straight to public liquidity providers; the remainder funds the protocol
            treasury. Deposit any active stablecoin to start earning.
          </p>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 12, marginTop: 18 }}>
            {([
              ["Pool TVL", stats ? fmtUSD(stats.navUsd1e18, 0) : "—"],
              ["LP price", lpPrice != null ? `$${lpPrice.toFixed(4)}` : "—"],
              ["To LPs", `${lpSharePct(stats?.protocolFeeShareBps)}%`],
            ] as const).map(([l, v]) => (
              <div key={l} style={{ padding: "12px 14px", background: "var(--surface-2)", borderRadius: "var(--radius-md)", border: "1px solid var(--border)" }}>
                <div className="overline" style={{ fontSize: 10 }}>{l}</div>
                <div style={{ fontWeight: 700, fontSize: 18, fontFamily: "var(--font-mono)", letterSpacing: "-0.02em", marginTop: 4 }}>{v}</div>
              </div>
            ))}
          </div>
        </Card>

        {/* GF-3: your position */}
        {isConnected && (
          <Card pad={20}>
            <Overline>Your position</Overline>
            <div style={{ display: "flex", alignItems: "baseline", gap: 10, margin: "6px 0 16px" }}>
              <span style={{ fontWeight: 800, fontSize: 30, letterSpacing: "-0.02em" }}>
                $<AnimatedNumber value={pos.valueUsd1e18 != null ? Number(pos.valueUsd1e18) / 1e18 : 0} decimals={2} />
              </span>
            </div>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
              <div>
                <div className="overline" style={{ fontSize: 10 }}>LP balance</div>
                <div style={{ fontWeight: 600, fontFamily: "var(--font-mono)", marginTop: 3 }}>
                  {pos.balance != null ? fmtUnits(pos.balance, 18, 2) : "—"}
                </div>
              </div>
              <div>
                <div className="overline" style={{ fontSize: 10 }}>Pool share</div>
                <div style={{ fontWeight: 600, fontFamily: "var(--font-mono)", marginTop: 3 }}>
                  {pos.share != null ? `${(pos.share * 100).toFixed(4)}%` : "—"}
                </div>
              </div>
            </div>
          </Card>
        )}

        <Card pad={20}>
          <Overline style={{ marginBottom: 12 }}>Pool composition</Overline>
          <PoolComposition tokens={tokens} reserves={reserves} prices={prices} />
        </Card>
      </div>

      <TokenSelectModal
        open={picker}
        onClose={() => setPicker(false)}
        tokens={tokens}
        onPick={(addr) => {
          setTokenAddr(addr);
          setAmt("");
          setProportional(false);
          setPicker(false);
        }}
      />
    </div>
  );
}

// ───────────────────────────── helpers ─────────────────────────────────

/** Advisory gross USD for the withdraw fee row = amountOut value (1e18). */
function grossForWithdraw(amountOut: bigint, meta: TokenInfoV2 | undefined, price1e18: bigint | undefined): bigint {
  if (!meta || !price1e18 || price1e18 === 0n) return 0n;
  return reserveUsd1e18(amountOut, meta.decimals, price1e18);
}

/** LP fee share % = 100 − protocolFeeShareBps/100. Defaults to 90% pre-load. */
function lpSharePct(protocolFeeShareBps: number | undefined): number {
  if (protocolFeeShareBps == null) return 90;
  return 100 - protocolFeeShareBps / 100;
}

function StatLine({ label, value, tone }: { label: string; value: React.ReactNode; tone?: string }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, fontSize: 13.5 }}>
      <span style={{ color: "var(--fg-3)", whiteSpace: "nowrap" }}>{label}</span>
      <span
        style={{
          fontWeight: 600,
          fontFamily: "var(--font-mono)",
          color: tone || "var(--fg-1)",
          whiteSpace: "nowrap",
          textAlign: "right",
          fontSize: 12.5,
        }}
      >
        {value}
      </span>
    </div>
  );
}

function WarnRow({ children, tone = "warning" }: { children: React.ReactNode; tone?: "warning" | "danger" }) {
  const color = tone === "danger" ? "var(--danger)" : "var(--warning)";
  const bg = tone === "danger" ? "var(--danger-bg)" : "var(--warning-bg)";
  return (
    <div
      style={{
        display: "flex",
        alignItems: "flex-start",
        gap: 8,
        padding: "10px 12px",
        marginBottom: 12,
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

function PoolComposition({
  tokens,
  reserves,
  prices,
}: {
  tokens: TokenInfoV2[];
  reserves: Record<string, bigint>;
  prices: Record<string, { price1e18: bigint }>;
}) {
  // Derive weights from on-chain reserve USD (raw × oracle price).
  const usdByAddr = tokens.map((t) => {
    const raw = reserves[t.address.toLowerCase()] ?? 0n;
    const p = prices[t.address.toLowerCase()];
    const usd = p && p.price1e18 > 0n ? reserveUsd1e18(raw, t.decimals, p.price1e18) : 0n;
    return { t, usd };
  });
  const total = usdByAddr.reduce((s, x) => s + x.usd, 0n);
  const weight = (usd: bigint) => (total === 0n ? 0 : Number(usd) / Number(total));

  return (
    <div>
      <div style={{ display: "flex", height: 10, borderRadius: "var(--radius-pill)", overflow: "hidden", marginBottom: 12, background: "var(--surface-2)" }}>
        {usdByAddr.map(({ t, usd }) => (
          <div
            key={t.address}
            title={`${t.symbol} ${(weight(usd) * 100).toFixed(1)}%`}
            style={{ width: `${weight(usd) * 100}%`, background: tokenColor(t.symbol) }}
          />
        ))}
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "8px 18px" }}>
        {usdByAddr.map(({ t, usd }) => (
          <div key={t.address} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13 }}>
            <span style={{ width: 9, height: 9, borderRadius: "50%", background: tokenColor(t.symbol), flexShrink: 0 }} />
            <span style={{ fontWeight: 600 }}>{t.symbol}</span>
            <span style={{ marginLeft: "auto", fontFamily: "var(--font-mono)", color: "var(--fg-3)" }}>
              {(weight(usd) * 100).toFixed(1)}%
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

function ActionButton(props: {
  isConnected: boolean;
  wrongChain: boolean;
  switchPending: boolean;
  onSwitch: () => void;
  busy: boolean;
  tab: Tab;
  proportional: boolean;
  paused: boolean;
  hasAmount: boolean;
  insufficient: boolean;
  insufficientSym?: string;
  overMax: boolean;
  capBlocked: boolean;
  quoteFetching: boolean;
  onDeposit: () => void;
  onWithdrawSingle: () => void;
  onWithdrawProportional: () => void;
}) {
  const {
    isConnected, wrongChain, switchPending, onSwitch, busy, tab, proportional, paused,
    hasAmount, insufficient, insufficientSym, overMax, capBlocked, quoteFetching,
    onDeposit, onWithdrawSingle, onWithdrawProportional,
  } = props;

  if (!isConnected) {
    return (
      <Button variant="brand" size="lg" full icon="wallet">
        Connect wallet
      </Button>
    );
  }
  if (wrongChain) {
    return (
      <Button variant="primary" size="lg" full disabled={switchPending} onClick={onSwitch}>
        {switchPending ? "Switching…" : `Switch to ${ACTIVE_CHAIN.name}`}
      </Button>
    );
  }
  if (busy) {
    return (
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
        {tab === "deposit" ? "Depositing…" : "Withdrawing…"}
      </Button>
    );
  }

  // §11: proportional withdraw stays available even when the pool is paused;
  // deposit is blocked when paused.
  const depositPaused = tab === "deposit" && paused;
  if (!hasAmount) {
    return <Button variant="secondary" size="lg" full disabled>Enter an amount</Button>;
  }
  if (insufficient) {
    return <Button variant="secondary" size="lg" full disabled>Insufficient {insufficientSym} balance</Button>;
  }
  if (depositPaused) {
    return <Button variant="secondary" size="lg" full disabled>Pool is paused</Button>;
  }
  if (tab === "deposit" && capBlocked) {
    return <Button variant="secondary" size="lg" full disabled>Deposit cap reached</Button>;
  }
  if (tab === "withdraw" && !proportional && overMax) {
    return <Button variant="secondary" size="lg" full disabled>Exceeds floor-safe max</Button>;
  }
  if (quoteFetching) {
    return <Button variant="secondary" size="lg" full disabled>Fetching quote…</Button>;
  }

  if (tab === "deposit") {
    return <Button variant="primary" size="lg" full icon="plus" onClick={onDeposit}>Add liquidity</Button>;
  }
  if (proportional) {
    return <Button variant="primary" size="lg" full icon="droplet" onClick={onWithdrawProportional}>Proportional exit</Button>;
  }
  return <Button variant="primary" size="lg" full icon="arrowDown" onClick={onWithdrawSingle}>Withdraw</Button>;
}
