import type { CSSProperties, ReactNode } from "react";

type Tone = "neutral" | "accent" | "success" | "danger" | "info";

/**
 * Pill / tag — 5 tones (neutral / accent lime / success / danger / info).
 * Ported verbatim from the prototype's ui.jsx.
 */
export function Pill({
  children,
  tone = "neutral",
  style,
}: {
  children: ReactNode;
  tone?: Tone;
  style?: CSSProperties;
}) {
  const tones: Record<Tone, { bg: string; fg: string; bd: string }> = {
    neutral: { bg: "var(--surface-2)", fg: "var(--fg-2)", bd: "var(--border)" },
    accent: { bg: "rgba(200,242,74,.16)", fg: "var(--action)", bd: "rgba(200,242,74,.32)" },
    success: { bg: "var(--success-bg)", fg: "var(--success)", bd: "transparent" },
    danger: { bg: "var(--danger-bg)", fg: "var(--danger)", bd: "transparent" },
    info: { bg: "var(--info-bg)", fg: "var(--info)", bd: "transparent" },
  };
  const t = tones[tone];
  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 5,
        padding: "3px 9px",
        borderRadius: "var(--radius-pill)",
        fontSize: 12,
        fontWeight: 600,
        whiteSpace: "nowrap",
        background: t.bg,
        color: t.fg,
        border: `1px solid ${t.bd}`,
        ...style,
      }}
    >
      {children}
    </span>
  );
}
