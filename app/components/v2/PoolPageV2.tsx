"use client";
import { useMemo, useState } from "react";
import { fmtUnits, fmtUSD } from "@arcoralabs/dex-sdk";
import { feeBandsForToken } from "@arcoralabs/dex-sdk/v2";
import type { TokenInfoV2 } from "@arcoralabs/dex-sdk/v2";
import { Card } from "@/components/ds/Card";
import { Pill } from "@/components/ds/Pill";
import { Overline } from "@/components/ds/Overline";
import { Icon, type IconName } from "@/components/ds/Icon";
import { CoinBadge } from "@/components/ds/CoinBadge";
import { AnimatedNumber } from "@/components/ds/AnimatedNumber";
import { AreaChart } from "@/components/ds/AreaChart";
import { tokenColor } from "@/components/ds/tokens";
import { EXPLORER } from "@/lib/chain";
import { useTokensV2 } from "./useTokensV2";
import { usePoolStatsV2 } from "./usePoolStatsV2";
import { useReserves, reserveUsd1e18 } from "./useReserves";
import { useOraclePrices, type OraclePrice } from "./useOraclePrices";
import { usePoolFeed, type FeedRow } from "./usePoolFeed";
import { useGovernance, type GovernanceState, type SafeInfo } from "./useGovernance";
import { ReserveHealthBar } from "./ReserveHealthBar";

const RANGES = ["24H", "7D", "30D", "ALL"] as const;

/**
 * PoolPageV2 — the prototype pool analytics page wired to the live V2 ledger:
 *   - 4 stat tiles (TVL / LP supply / LP price / swap-fee schedule) from
 *     usePoolStatsV2 (no fabricated series — honest single-point TVL),
 *   - a Reserves panel with a per-token ReserveHealthBar, GF-2 oracle badge
 *     (live price + safe/unsafe → proportional-exit hint when unsafe), and GF-5
 *     per-token reserve floor/target + §7 marginal fee-band schedule,
 *   - GF-1 read-only protocol/governance status panel (paused, Timelock +
 *     getMinDelay, Gov/PG Safes + thresholds/owners, pauseGuardian),
 *   - a real Recent-transactions feed from on-chain Pool events.
 */
export function PoolPageV2() {
  const { tokens } = useTokensV2();
  const { stats } = usePoolStatsV2();
  const { reserves } = useReserves(tokens);
  const { prices } = useOraclePrices(tokens);
  const { rows } = usePoolFeed();
  const { gov } = useGovernance();

  const [range, setRange] = useState<(typeof RANGES)[number]>("7D");

  const tvlNum = stats ? Number(stats.navUsd1e18) / 1e18 : 0;
  const lpPriceNum = stats ? Number(stats.lpPriceUsd1e18) / 1e18 : 0;
  const lpSupplyNum = stats ? Number(stats.lpSupply) / 1e18 : 0;

  // The pool exposes no TVL history view; the §7 plan forbids fabricating a
  // series. Render an honest flat line at the current TVL so the chart shape
  // matches the prototype without inventing data.
  const tvlSeries = useMemo(() => Array.from({ length: 24 }, () => tvlNum), [tvlNum]);

  return (
    <div style={{ width: "min(1180px, 96vw)", margin: "0 auto" }}>
      {/* hero stats */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 14, marginBottom: 16 }}>
        <BigStat
          label="Pool TVL"
          icon="layers"
          value={<span>$<AnimatedNumber value={tvlNum} decimals={0} /></span>}
          subText={stats ? "Total reserves" : "Loading…"}
        />
        <BigStat
          label="LP supply"
          icon="activity"
          value={<AnimatedNumber value={lpSupplyNum} decimals={0} />}
          subText="LP tokens"
        />
        <BigStat
          label="LP price"
          icon="scale"
          value={<span>$<AnimatedNumber value={lpPriceNum} decimals={5} /></span>}
          subText="NAV per LP"
        />
        <BigStat
          label="Swap fee"
          icon="zap"
          value={<span>{feeRangeLabel(tokens)}</span>}
          subText={`${lpSharePct(stats?.protocolFeeShareBps)}% to LPs`}
        />
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1.4fr) minmax(0, 1fr)", gap: 16, alignItems: "start" }}>
        {/* TVL chart */}
        <Card pad={20}>
          <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", marginBottom: 18 }}>
            <div>
              <Overline>Total value locked</Overline>
              <div style={{ fontWeight: 800, fontSize: 30, letterSpacing: "-0.02em", marginTop: 4, fontFamily: "var(--font-mono)" }}>
                $<AnimatedNumber value={tvlNum} decimals={0} />
              </div>
              <Pill tone="neutral" style={{ marginTop: 6 }}>
                <Icon name="info" size={12} /> Live · history coming soon
              </Pill>
            </div>
            <div style={{ display: "flex", gap: 3, padding: 3, background: "var(--surface-2)", borderRadius: "var(--radius-md)" }}>
              {RANGES.map((r) => (
                <button
                  key={r}
                  onClick={() => setRange(r)}
                  style={{
                    padding: "6px 12px",
                    fontSize: 12,
                    fontWeight: 600,
                    fontFamily: "var(--font-mono)",
                    cursor: "pointer",
                    border: "none",
                    borderRadius: "var(--radius-sm)",
                    background: range === r ? "var(--surface)" : "transparent",
                    color: range === r ? "var(--fg-1)" : "var(--fg-3)",
                    boxShadow: range === r ? "var(--elev-1)" : "none",
                    transition: "all var(--dur-base)",
                  }}
                >
                  {r}
                </button>
              ))}
            </div>
          </div>
          <AreaChart key={range} data={tvlSeries} h={240} color="var(--action)" />
          <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 14, marginTop: 20, paddingTop: 18, borderTop: "1px solid var(--border)" }}>
            {([
              ["Active tokens", String(tokens.length)],
              ["To LPs", `${lpSharePct(stats?.protocolFeeShareBps)}%`],
              ["Status", stats?.paused ? "Paused" : "Operational"],
            ] as const).map(([l, v]) => (
              <div key={l}>
                <div className="overline" style={{ fontSize: 10 }}>{l}</div>
                <div style={{ fontWeight: 700, fontSize: 19, fontFamily: "var(--font-mono)", letterSpacing: "-0.02em", marginTop: 4 }}>{v}</div>
              </div>
            ))}
          </div>
        </Card>

        {/* Reserves — GF-2 oracle badges + GF-5 floor/target + fee bands */}
        <Card pad={20}>
          <Overline style={{ marginBottom: 14 }}>Reserves</Overline>
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            {tokens.length === 0 && (
              <div style={{ padding: "20px 0", textAlign: "center", fontSize: 13.5, color: "var(--fg-3)" }}>
                No active tokens.
              </div>
            )}
            {tokens.map((t) => (
              <ReserveRow
                key={t.address}
                token={t}
                raw={reserves[t.address.toLowerCase()] ?? 0n}
                price={prices[t.address.toLowerCase()]}
                totalUsd1e18={totalReserveUsd(tokens, reserves, prices)}
              />
            ))}
          </div>
        </Card>
      </div>

      {/* GF-1 governance status panel */}
      <div style={{ marginTop: 16 }}>
        <GovernancePanel gov={gov} paused={stats?.paused ?? null} />
      </div>

      {/* live feed */}
      <div style={{ marginTop: 16 }}>
        <LiveFeed rows={rows} tokens={tokens} />
      </div>
    </div>
  );
}

// ───────────────────────────── stat tile ────────────────────────────────

function BigStat({
  label,
  value,
  subText,
  icon,
}: {
  label: string;
  value: React.ReactNode;
  subText: string;
  icon?: IconName;
}) {
  return (
    <Card pad={18}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <Overline>{label}</Overline>
        {icon && (
          <span style={{ color: "var(--fg-3)" }}>
            <Icon name={icon} size={16} />
          </span>
        )}
      </div>
      <div style={{ fontWeight: 800, fontSize: 26, letterSpacing: "-0.02em", margin: "8px 0 4px", fontFamily: "var(--font-mono)" }}>
        {value}
      </div>
      <span style={{ fontSize: 12.5, color: "var(--fg-3)", fontWeight: 600, whiteSpace: "nowrap" }}>{subText}</span>
    </Card>
  );
}

// ───────────────────────────── reserves row ─────────────────────────────

function ReserveRow({
  token,
  raw,
  price,
  totalUsd1e18,
}: {
  token: TokenInfoV2;
  raw: bigint;
  price?: OraclePrice;
  totalUsd1e18: bigint;
}) {
  const [open, setOpen] = useState(false);
  const hasPrice = price != null && price.price1e18 > 0n;
  const usd1e18 = hasPrice ? reserveUsd1e18(raw, token.decimals, price!.price1e18) : 0n;
  const weightPct = totalUsd1e18 === 0n ? 0 : (Number(usd1e18) / Number(totalUsd1e18)) * 100;
  const priceNum = hasPrice ? Number(price!.price1e18) / 1e18 : null;
  const safe = price?.safe ?? null;
  const bands = feeBandsForToken(token.bands);

  return (
    <div style={{ borderBottom: "1px solid var(--border-faint)" }}>
      <button
        onClick={() => setOpen((o) => !o)}
        style={{
          display: "flex",
          alignItems: "center",
          gap: 12,
          padding: "10px 0",
          width: "100%",
          background: "transparent",
          border: "none",
          cursor: "pointer",
          textAlign: "left",
        }}
      >
        <CoinBadge sym={token.symbol} color={tokenColor(token.symbol)} size={30} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
            <span style={{ fontWeight: 600, fontSize: 13.5 }}>{token.symbol}</span>
            {/* GF-2 oracle badge */}
            <OracleBadge safe={safe} />
          </div>
          <div style={{ fontSize: 11.5, color: "var(--fg-3)" }}>{token.name}</div>
        </div>
        <div style={{ textAlign: "right" }}>
          <div style={{ fontWeight: 600, fontFamily: "var(--font-mono)", fontSize: 13.5 }}>
            {hasPrice ? fmtUSD(usd1e18, 0) : "—"}
          </div>
          <div style={{ fontSize: 11, color: "var(--fg-3)", fontFamily: "var(--font-mono)" }}>
            {weightPct.toFixed(1)}% · {priceNum != null ? `$${priceNum.toFixed(4)}` : "—"}
          </div>
        </div>
        <Icon name={open ? "chevronDown" : "chevronRight"} size={15} style={{ color: "var(--fg-3)" }} />
      </button>

      {open && (
        <div style={{ padding: "4px 0 14px", display: "flex", flexDirection: "column", gap: 12 }}>
          <ReserveHealthBar healthBps={healthBpsFor(usd1e18, token)} symbol={token.symbol} />

          {/* §11 hint when the oracle is unsafe */}
          {safe === false && (
            <div
              style={{
                display: "flex",
                alignItems: "flex-start",
                gap: 8,
                padding: "9px 11px",
                background: "var(--danger-bg)",
                borderRadius: "var(--radius-md)",
                fontSize: 12,
                color: "var(--danger)",
                lineHeight: 1.4,
              }}
            >
              <Icon name="shield" size={14} style={{ flexShrink: 0, marginTop: 1 }} />
              <span>
                Oracle unsafe — oracle-priced swaps/withdrawals for {token.symbol} are paused. Exit
                proportionally on the Liquidity page.
              </span>
            </div>
          )}

          {/* GF-5: floor / target */}
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
            <MiniStat label="Reserve floor" value={fmtUSD(token.minimumReserveUsd, 0)} />
            <MiniStat label="Target reserve" value={fmtUSD(token.targetReserveUsd, 0)} />
            <MiniStat
              label="Deposit cap"
              value={token.depositCapUsd === 0n ? "Uncapped" : fmtUSD(token.depositCapUsd, 0)}
            />
            <MiniStat label="Reserve (raw)" value={fmtUnits(raw, token.decimals, 2)} />
          </div>

          {/* GF-5: §7 marginal fee-band schedule */}
          <div>
            <Overline style={{ marginBottom: 8 }}>Marginal fee schedule (§7)</Overline>
            <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
              {bands.map((b, i) => {
                const upper = b.upperHealthBps;
                const lower = bands[i + 1]?.upperHealthBps ?? 0;
                return (
                  <div
                    key={`${b.upperHealthBps}-${b.rateBps}`}
                    style={{
                      display: "flex",
                      justifyContent: "space-between",
                      fontSize: 12,
                      fontFamily: "var(--font-mono)",
                      color: "var(--fg-3)",
                    }}
                  >
                    <span>
                      {(lower / 100).toFixed(0)}–{(upper / 100).toFixed(0)}% health
                    </span>
                    <span style={{ color: "var(--fg-2)" }}>{(b.rateBps / 100).toFixed(2)}% fee</span>
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function OracleBadge({ safe }: { safe: boolean | null }) {
  if (safe == null) {
    return <Pill tone="neutral" style={{ fontSize: 10, padding: "2px 7px" }}>Oracle —</Pill>;
  }
  return safe ? (
    <Pill tone="success" style={{ fontSize: 10, padding: "2px 7px" }}>
      <span style={{ width: 5, height: 5, borderRadius: "50%", background: "var(--success)" }} /> Oracle safe
    </Pill>
  ) : (
    <Pill tone="danger" style={{ fontSize: 10, padding: "2px 7px" }}>
      <span style={{ width: 5, height: 5, borderRadius: "50%", background: "var(--danger)" }} /> Oracle unsafe
    </Pill>
  );
}

function MiniStat({ label, value }: { label: string; value: string }) {
  return (
    <div style={{ padding: "9px 11px", background: "var(--surface-2)", borderRadius: "var(--radius-md)", border: "1px solid var(--border)" }}>
      <div className="overline" style={{ fontSize: 10 }}>{label}</div>
      <div style={{ fontWeight: 600, fontSize: 13.5, fontFamily: "var(--font-mono)", letterSpacing: "-0.01em", marginTop: 3 }}>{value}</div>
    </div>
  );
}

// ───────────────────────────── governance (GF-1) ────────────────────────

function GovernancePanel({ gov, paused }: { gov: GovernanceState | null; paused: boolean | null }) {
  return (
    <Card pad={20}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 16 }}>
        <Overline>Protocol &amp; governance</Overline>
        {paused == null ? (
          <Pill tone="neutral">Status —</Pill>
        ) : paused ? (
          <Pill tone="danger">
            <Icon name="lock" size={12} /> Paused
          </Pill>
        ) : (
          <Pill tone="success">
            <span className="ar-pulse" style={{ width: 7, height: 7, borderRadius: "50%", background: "var(--success)" }} /> Operational
          </Pill>
        )}
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))", gap: 14 }}>
        {/* Timelock */}
        <GovCard title="Timelock controller">
          <GovRow label="Address" value={<AddrLink addr={gov?.timelock} />} />
          <GovRow
            label="Min delay"
            value={gov?.minDelaySeconds != null ? formatDelay(gov.minDelaySeconds) : "—"}
          />
        </GovCard>

        {/* Governance Safe */}
        <SafeCard title="Governance Safe" safe={gov?.govSafe} />

        {/* Pause-Guardian Safe */}
        <SafeCard title="Pause-Guardian Safe" safe={gov?.pgSafe} />

        {/* Pool pauseGuardian */}
        <GovCard title="Pool guardian">
          <GovRow label="pauseGuardian()" value={<AddrLink addr={gov?.pauseGuardian ?? undefined} />} />
          <GovRow label="Pause state" value={paused == null ? "—" : paused ? "Paused" : "Active"} />
        </GovCard>
      </div>
    </Card>
  );
}

function GovCard({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={{ padding: "14px 16px", background: "var(--surface-2)", borderRadius: "var(--radius-md)", border: "1px solid var(--border)" }}>
      <div style={{ fontWeight: 700, fontSize: 13.5, marginBottom: 10 }}>{title}</div>
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>{children}</div>
    </div>
  );
}

function SafeCard({ title, safe }: { title: string; safe?: SafeInfo }) {
  return (
    <GovCard title={title}>
      <GovRow label="Address" value={<AddrLink addr={safe?.address} />} />
      <GovRow
        label="Threshold"
        value={
          safe?.threshold != null && safe.owners != null
            ? `${safe.threshold} of ${safe.owners.length}`
            : safe?.threshold != null
              ? String(safe.threshold)
              : "—"
        }
      />
    </GovCard>
  );
}

function GovRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, fontSize: 12.5 }}>
      <span style={{ color: "var(--fg-3)", whiteSpace: "nowrap" }}>{label}</span>
      <span style={{ fontWeight: 600, fontFamily: "var(--font-mono)", fontSize: 12, textAlign: "right" }}>{value}</span>
    </div>
  );
}

function AddrLink({ addr }: { addr?: `0x${string}` }) {
  if (!addr) return <span style={{ color: "var(--fg-3)" }}>—</span>;
  return (
    <a
      href={`${EXPLORER}/address/${addr}`}
      target="_blank"
      rel="noreferrer"
      style={{ color: "var(--action)", textDecoration: "none", display: "inline-flex", alignItems: "center", gap: 4 }}
    >
      {shortAddr(addr)}
      <Icon name="external" size={11} style={{ color: "var(--fg-3)" }} />
    </a>
  );
}

// ───────────────────────────── live feed ────────────────────────────────

function LiveFeed({ rows, tokens }: { rows: FeedRow[]; tokens: TokenInfoV2[] }) {
  const byAddr = useMemo(
    () => Object.fromEntries(tokens.map((t) => [t.address.toLowerCase(), t])) as Record<string, TokenInfoV2>,
    [tokens],
  );
  return (
    <Card pad={0} elev={1} style={{ overflow: "hidden" }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "16px 18px", borderBottom: "1px solid var(--border)" }}>
        <div style={{ fontWeight: 700, fontSize: 15 }}>Recent transactions</div>
        <Pill tone="success">
          <span className="ar-pulse" style={{ width: 7, height: 7, borderRadius: "50%", background: "var(--success)" }} /> Live
        </Pill>
      </div>
      <div style={{ maxHeight: 520, overflowY: "auto" }}>
        {rows.length === 0 ? (
          <div style={{ padding: "28px 18px", textAlign: "center", fontSize: 13, color: "var(--fg-3)" }}>
            No recent on-chain activity in the last ~10k blocks.
          </div>
        ) : (
          rows.map((tx) => <TxRow key={tx.id} tx={tx} byAddr={byAddr} />)
        )}
      </div>
    </Card>
  );
}

function TxRow({ tx, byAddr }: { tx: FeedRow; byAddr: Record<string, TokenInfoV2> }) {
  const from = tx.from ? byAddr[tx.from] : undefined;
  const to = tx.to ? byAddr[tx.to] : undefined;
  const tone = tx.action === "swap" ? "accent" : tx.action === "withdraw" ? "info" : "neutral";
  const dotColor =
    tx.action === "swap" ? "var(--action)" : tx.action === "withdraw" ? "var(--info)" : "var(--warning)";
  const label = tx.action === "exit" ? "exit" : tx.action;
  const amountStr =
    tx.amountRaw != null && from ? fmtUnits(tx.amountRaw, from.decimals, 2) : tx.action === "exit" ? "pro-rata" : "—";

  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "92px 1fr auto auto",
        alignItems: "center",
        gap: 12,
        padding: "11px 16px",
        borderBottom: "1px solid var(--border-faint)",
      }}
    >
      <Pill tone={tone} style={{ textTransform: "capitalize", fontSize: 11 }}>
        <span style={{ width: 6, height: 6, borderRadius: "50%", background: dotColor }} />
        {label}
      </Pill>
      <div style={{ display: "flex", alignItems: "center", gap: 7, minWidth: 0 }}>
        {from ? (
          <>
            <CoinBadge sym={from.symbol} color={tokenColor(from.symbol)} size={22} />
            <span style={{ fontWeight: 600, fontSize: 13.5 }}>{from.symbol}</span>
          </>
        ) : (
          <span style={{ fontSize: 13.5, color: "var(--fg-3)" }}>All reserves</span>
        )}
        {to && (
          <>
            <Icon name="arrowRight" size={14} style={{ color: "var(--fg-3)" }} />
            <CoinBadge sym={to.symbol} color={tokenColor(to.symbol)} size={22} />
            <span style={{ fontWeight: 600, fontSize: 13.5 }}>{to.symbol}</span>
          </>
        )}
      </div>
      <span style={{ fontFamily: "var(--font-mono)", fontSize: 13, fontWeight: 600 }}>{amountStr}</span>
      <span style={{ display: "flex", alignItems: "center", gap: 8, justifyContent: "flex-end", minWidth: 132 }}>
        <span style={{ fontFamily: "var(--font-mono)", fontSize: 12, color: "var(--fg-3)" }}>{shortAddr(tx.user)}</span>
        <a href={`${EXPLORER}/tx/${tx.txHash}`} target="_blank" rel="noreferrer" aria-label="view transaction">
          <Icon name="external" size={13} style={{ color: "var(--fg-3)" }} />
        </a>
      </span>
    </div>
  );
}

// ───────────────────────────── helpers ──────────────────────────────────

/** Total reserve USD across active tokens (1e18). */
function totalReserveUsd(
  tokens: TokenInfoV2[],
  reserves: Record<string, bigint>,
  prices: Record<string, OraclePrice>,
): bigint {
  let total = 0n;
  for (const t of tokens) {
    const raw = reserves[t.address.toLowerCase()] ?? 0n;
    const p = prices[t.address.toLowerCase()];
    if (p && p.price1e18 > 0n) total += reserveUsd1e18(raw, t.decimals, p.price1e18);
  }
  return total;
}

/**
 * Approximate display health bps from reserve USD vs the token's target — purely
 * for the per-token bar in the expanded reserve row (the swap/withdraw flows use
 * the authoritative on-chain `reserveHealth`). health ≈ min(reserve/target, 1).
 */
function healthBpsFor(reserveUsd1e18Val: bigint, token: TokenInfoV2): number {
  if (token.targetReserveUsd === 0n) return 10000;
  const ratio = Number((reserveUsd1e18Val * 10000n) / token.targetReserveUsd);
  return Math.max(0, Math.min(10000, ratio));
}

/** LP fee share % = 100 − protocolFeeShareBps/100. Defaults to 90% pre-load. */
function lpSharePct(protocolFeeShareBps: number | undefined): number {
  if (protocolFeeShareBps == null) return 90;
  return 100 - protocolFeeShareBps / 100;
}

/** §7: the fee schedule spans the min→max marginal rate across all tokens. */
function feeRangeLabel(tokens: TokenInfoV2[]): string {
  const rates = tokens.flatMap((t) => t.bands.map((b) => b.rateBps));
  if (rates.length === 0) return "—";
  const lo = Math.min(...rates) / 100;
  const hi = Math.max(...rates) / 100;
  return lo === hi ? `${lo.toFixed(2)}%` : `${lo.toFixed(2)}–${hi.toFixed(2)}%`;
}

function formatDelay(seconds: bigint): string {
  const s = Number(seconds);
  const h = s / 3600;
  if (Number.isInteger(h) && h % 24 === 0) return `${h / 24}d (${h}h)`;
  if (Number.isInteger(h)) return `${h}h`;
  return `${s}s`;
}

function shortAddr(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}
