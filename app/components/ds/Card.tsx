"use client";
import { useState, type CSSProperties, type ReactNode } from "react";

/**
 * Glass surface card — surface bg, hairline border, --radius-lg, --elev-*
 * shadow, with an optional hover lift. Ported verbatim from the prototype's
 * ui.jsx.
 */
export function Card({
  children,
  style,
  pad = 20,
  elev = 1,
  hover,
  onClick,
}: {
  children: ReactNode;
  style?: CSSProperties;
  pad?: number | string;
  elev?: 0 | 1 | 2 | 3 | 4;
  hover?: boolean;
  onClick?: () => void;
}) {
  const [h, setH] = useState(false);
  return (
    <div
      onClick={onClick}
      onMouseEnter={() => setH(true)}
      onMouseLeave={() => setH(false)}
      style={{
        background: "var(--surface)",
        border: "1px solid var(--border)",
        borderRadius: "var(--radius-lg)",
        padding: pad,
        boxShadow: hover && h ? "var(--elev-3)" : `var(--elev-${elev})`,
        transform: hover && h ? "translateY(-2px)" : "none",
        transition:
          "box-shadow var(--dur-base), transform var(--dur-base), border-color var(--dur-base)",
        ...style,
      }}
    >
      {children}
    </div>
  );
}
