import { shade } from "./tokens";

/**
 * Placeholder stablecoin disc — radial gradient from the token brand color,
 * with a short "$"-style label. Ported verbatim from the prototype's ui.jsx.
 * Label = sym with USD→$ then first 3 chars (e.g. USDC → "$C", EURC → "EUR").
 */
export function CoinBadge({
  sym,
  color,
  size = 28,
  ring,
}: {
  sym: string;
  color: string;
  size?: number;
  ring?: boolean;
}) {
  const label = sym.replace(/USD/i, "$").slice(0, 3);
  return (
    <span
      style={{
        width: size,
        height: size,
        borderRadius: "50%",
        flexShrink: 0,
        background: `radial-gradient(120% 120% at 30% 22%, ${color}, ${shade(color, -28)})`,
        display: "grid",
        placeItems: "center",
        fontFamily: "var(--font-mono)",
        fontWeight: 600,
        fontSize: size * 0.34,
        color: "#fff",
        boxShadow: ring
          ? `0 0 0 3px var(--surface), 0 0 0 4px ${color}55`
          : "inset 0 1px 1px rgba(255,255,255,.35)",
        letterSpacing: "-0.04em",
      }}
    >
      {label}
    </span>
  );
}
