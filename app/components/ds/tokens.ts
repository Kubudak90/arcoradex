/**
 * Design-system palette helpers + per-token brand colors.
 *
 * `shade()` is ported verbatim from the prototype's ui.jsx (used by CoinBadge
 * and composition bars for the radial-gradient darken). `tokenColor()` maps the
 * live V2 stablecoin symbols to their brand colors — USDC/USDT come from the
 * prototype's data.jsx, EURC uses the blue family per the plan — with a
 * deterministic hash fallback for any unknown symbol so new registry tokens
 * still get a stable disc color without a mock data file.
 */

/** Primary chartreuse accent (matches --accent / --chartreuse-400). */
export const ACCENT = "#C8F24A";

/** ServiceNow signature bright green (the live status / pulse hue). */
export const SN_GREEN = "#62D84E";

/**
 * Lighten/darken a #RRGGBB hex by a flat per-channel amount.
 * Ported verbatim from ui.jsx.
 */
export function shade(hex: string, amt: number): string {
  const n = parseInt(hex.slice(1), 16);
  let r = (n >> 16) + amt;
  let g = ((n >> 8) & 255) + amt;
  let b = (n & 255) + amt;
  r = Math.max(0, Math.min(255, r));
  g = Math.max(0, Math.min(255, g));
  b = Math.max(0, Math.min(255, b));
  return "#" + ((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1);
}

/** Brand colors for the live Base Sepolia V2 token universe. */
const BRAND_COLORS: Record<string, string> = {
  USDC: "#2775CA", // Circle blue (prototype data.jsx)
  USDT: "#26A17B", // Tether green (prototype data.jsx)
  EURC: "#2B6CB0", // Euro Coin — blue family (plan §Task 2 / resolved tokens)
};

/** Palette used by the deterministic fallback hash for unknown symbols. */
const FALLBACK_PALETTE = [
  "#4C9BE6",
  "#4ED8B0",
  "#E0A100",
  "#A6C84A",
  "#9A6BE0",
  "#E06A8C",
];

/**
 * Resolve a stable brand color for a token symbol. Known symbols use their
 * brand color; unknown symbols hash deterministically into FALLBACK_PALETTE so
 * the same symbol always renders the same disc color.
 */
export function tokenColor(symbol: string): string {
  const sym = symbol.toUpperCase();
  if (BRAND_COLORS[sym]) return BRAND_COLORS[sym];
  let hash = 0;
  for (let i = 0; i < sym.length; i++) {
    hash = (hash * 31 + sym.charCodeAt(i)) >>> 0;
  }
  return FALLBACK_PALETTE[hash % FALLBACK_PALETTE.length];
}
