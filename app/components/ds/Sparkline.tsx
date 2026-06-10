/**
 * Tiny sparkline polyline (Pool stat tiles). Ported verbatim from the
 * prototype's ui.jsx. Pure render — no hooks.
 */
export function Sparkline({
  data,
  w = 88,
  h = 28,
  color = "var(--action)",
}: {
  data: number[];
  w?: number;
  h?: number;
  color?: string;
}) {
  const min = Math.min(...data);
  const max = Math.max(...data);
  const rng = max - min || 1;
  const pts = data
    .map((v, i) => `${(i / (data.length - 1)) * w},${h - ((v - min) / rng) * h}`)
    .join(" ");
  return (
    <svg width={w} height={h} style={{ display: "block" }}>
      <polyline
        points={pts}
        fill="none"
        stroke={color}
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
