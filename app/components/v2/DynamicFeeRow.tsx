"use client";
import { useState } from "react";
import { estimatedFeePct, feeBandsForToken } from "@arcoralabs/dex-sdk/v2";
import type { FeeBand } from "@arcoralabs/dex-sdk/v2";
import { Icon } from "@/components/ds/Icon";

/**
 * §9 Dynamic-fee detail row.
 *
 * Shows the marginal dynamic fee for the trade as a percentage derived from the
 * quote's `feeUsd1e18` over the (advisory) `grossUsd1e18` via the SDK's
 * `estimatedFeePct`. The fee is dynamic (marginal across the §7 health bands) —
 * not a static pool fee. On expand, lists the token's fee bands (sorted
 * healthiest-first by `feeBandsForToken`) as `"75-100% → 0.05%"` rows so the
 * user can see why the marginal fee changes with reserve health.
 *
 * The displayed percent is advisory; the contract computes the authoritative
 * fee at execution time.
 */
export function DynamicFeeRow({
  feeUsd1e18,
  grossUsd1e18,
  bands,
}: {
  feeUsd1e18: bigint;
  grossUsd1e18: bigint;
  bands?: FeeBand[];
}) {
  const [open, setOpen] = useState(false);
  const pct = estimatedFeePct(feeUsd1e18, grossUsd1e18);
  const sorted = bands && bands.length > 0 ? feeBandsForToken(bands) : [];
  const expandable = sorted.length > 0;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <button
        type="button"
        onClick={expandable ? () => setOpen((o) => !o) : undefined}
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          gap: 12,
          fontSize: 13,
          background: "transparent",
          border: "none",
          padding: 0,
          cursor: expandable ? "pointer" : "default",
          textAlign: "left",
          width: "100%",
        }}
      >
        <span style={{ color: "var(--fg-3)", display: "inline-flex", alignItems: "center", gap: 5 }}>
          Est. fee
          {expandable && (
            <Icon
              name={open ? "chevronDown" : "chevronRight"}
              size={13}
              style={{ color: "var(--fg-3)" }}
            />
          )}
        </span>
        <span
          style={{
            color: "var(--fg-2)",
            fontWeight: 500,
            fontFamily: "var(--font-mono)",
            fontSize: 12.5,
            whiteSpace: "nowrap",
          }}
        >
          {pct.toFixed(2)}%
        </span>
      </button>
      {open && expandable && (
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            gap: 5,
            padding: "8px 10px",
            background: "var(--surface-2)",
            border: "1px solid var(--border)",
            borderRadius: "var(--radius-md)",
          }}
        >
          {sorted.map((b, i) => {
            // §7: bands are descending by `upperHealthBps` (the inclusive upper
            // bound). Band `i` covers (lower, upper] where lower is the NEXT
            // band's upper bound (or 0 for the last band). See FeeBandMathV2.
            const upper = b.upperHealthBps;
            const lower = sorted[i + 1]?.upperHealthBps ?? 0;
            return (
              <div
                key={`${b.upperHealthBps}-${b.rateBps}`}
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  fontSize: 11.5,
                  fontFamily: "var(--font-mono)",
                  color: "var(--fg-3)",
                }}
              >
                <span>
                  {(lower / 100).toFixed(0)}–{(upper / 100).toFixed(0)}%
                </span>
                <span style={{ color: "var(--fg-2)" }}>{(b.rateBps / 100).toFixed(2)}%</span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
