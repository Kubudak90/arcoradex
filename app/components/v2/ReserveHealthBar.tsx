import { healthBand, healthLabel, type HealthBand } from "@arcoralabs/dex-sdk/v2";
import { Overline } from "@/components/ds/Overline";

/** §9: band → fill color. Mirrors the spec §7 health bands. */
const BAND_COLOR: Record<HealthBand, string> = {
  "75-100": "var(--success)",
  "50-75": "var(--accent)",
  "25-50": "var(--warning)",
  "0-25": "var(--danger)",
};

/**
 * §9 Reserve-health bar for the OUTPUT token.
 *
 * Maps a reserve-health bps value (0..10000) to its §7 band/label/color and
 * renders a labeled track with a fill at the current health. When `postHealthBps`
 * is provided (from the quote's `postHealthBps`), a thin "after" marker is drawn
 * at the post-swap health plus a `↓ to {label}` hint when the trade lowers the
 * band.
 */
export function ReserveHealthBar({
  healthBps,
  postHealthBps,
  symbol,
}: {
  healthBps: number;
  postHealthBps?: number;
  symbol?: string;
}) {
  const band = healthBand(healthBps);
  const label = healthLabel(healthBps);
  const pct = clampPct(healthBps);
  const fill = BAND_COLOR[band];

  const hasPost = postHealthBps != null;
  const postPct = hasPost ? clampPct(postHealthBps) : null;
  const postLabel = hasPost ? healthLabel(postHealthBps) : null;
  const bandDropped = hasPost && postHealthBps < healthBps && postLabel !== label;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8 }}>
        <Overline>Reserve health{symbol ? ` · ${symbol}` : ""}</Overline>
        <span
          style={{
            fontFamily: "var(--font-mono)",
            fontSize: 12,
            fontWeight: 600,
            color: fill,
          }}
        >
          {label} · {(healthBps / 100).toFixed(1)}%
        </span>
      </div>
      <div
        style={{
          position: "relative",
          height: 8,
          borderRadius: "var(--radius-pill)",
          background: "var(--surface-2)",
          border: "1px solid var(--border)",
          overflow: "hidden",
        }}
      >
        <div
          style={{
            position: "absolute",
            inset: 0,
            width: `${pct}%`,
            background: fill,
            borderRadius: "var(--radius-pill)",
            transition: "width var(--dur-base)",
          }}
        />
        {postPct != null && (
          <div
            aria-label="post-swap reserve health"
            style={{
              position: "absolute",
              top: -2,
              bottom: -2,
              left: `calc(${postPct}% - 1px)`,
              width: 2,
              background: "var(--fg-1)",
              opacity: 0.8,
            }}
          />
        )}
      </div>
      {hasPost && (
        <div style={{ fontSize: 11.5, color: "var(--fg-3)", fontFamily: "var(--font-mono)" }}>
          After swap: {(postHealthBps / 100).toFixed(1)}%
          {bandDropped && (
            <span style={{ color: "var(--warning)" }}> · ↓ to {postLabel}</span>
          )}
        </div>
      )}
    </div>
  );
}

function clampPct(bps: number): number {
  return Math.max(0, Math.min(100, bps / 100));
}
