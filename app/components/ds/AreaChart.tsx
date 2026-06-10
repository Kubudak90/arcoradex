"use client";
import { useEffect, useId, useRef, useState } from "react";

/**
 * Area chart with a draw-in stroke animation + a fade-in fill. Self-heals by
 * clearing the one-shot animation once played so the layer de-promotes
 * (capture/PDF safe). Ported verbatim from the prototype's ui.jsx.
 */
export function AreaChart({
  data,
  w = 520,
  h = 160,
  color = "var(--action)",
  fill = true,
  animate = true,
  strokeW = 2,
}: {
  data: number[];
  w?: number;
  h?: number;
  color?: string;
  fill?: boolean;
  animate?: boolean;
  strokeW?: number;
}) {
  const [drawn, setDrawn] = useState(!animate);
  const min = Math.min(...data);
  const max = Math.max(...data);
  const pad = (max - min) * 0.12 || 1;
  const lo = min - pad;
  const hi = max + pad;
  const pts = data.map((v, i) => {
    const x = (i / (data.length - 1)) * w;
    const y = h - ((v - lo) / (hi - lo)) * h;
    return [x, y] as const;
  });
  const line = pts
    .map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1))
    .join(" ");
  const area = line + ` L${w} ${h} L0 ${h} Z`;
  const pathRef = useRef<SVGPathElement>(null);
  const [len, setLen] = useState(0);
  // DOM measurement (path total length) — external-system sync.
  useEffect(() => {
    if (pathRef.current) setLen(pathRef.current.getTotalLength());
  }, [data]);
  // clear one-shot animations once played so the layer de-promotes (capture/PDF safe)
  useEffect(() => {
    if (!animate) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- draw-in gating (no animation)
      setDrawn(true);
      return;
    }
    setDrawn(false);
    const t = setTimeout(() => setDrawn(true), 1300);
    return () => clearTimeout(t);
  }, [data, animate]);
  // Deterministic, SSR-stable gradient id (React's useId is identical on the
  // server and the client) — the prototype's `Math.random()` id caused a
  // hydration mismatch. Sanitize the colons so it's a valid SVG/url() id.
  const gid = "g" + useId().replace(/:/g, "");
  return (
    <svg
      width="100%"
      height={h}
      viewBox={`0 0 ${w} ${h}`}
      preserveAspectRatio="none"
      style={{ display: "block", overflow: "visible" }}
    >
      <defs>
        <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={color} stopOpacity="0.26" />
          <stop offset="100%" stopColor={color} stopOpacity="0" />
        </linearGradient>
      </defs>
      {fill && (
        <path
          d={area}
          fill={`url(#${gid})`}
          style={{
            opacity: drawn ? 1 : 0,
            animation: animate && !drawn ? "ar-fadein .7s .25s ease forwards" : "none",
          }}
        />
      )}
      <path
        ref={pathRef}
        d={line}
        fill="none"
        stroke={color}
        strokeWidth={strokeW}
        strokeLinecap="round"
        strokeLinejoin="round"
        style={
          len
            ? {
                strokeDasharray: len,
                strokeDashoffset: animate && !drawn ? len : 0,
                animation:
                  animate && !drawn ? "ar-draw 1.1s var(--ease-standard) forwards" : "none",
              }
            : undefined
        }
      />
    </svg>
  );
}
