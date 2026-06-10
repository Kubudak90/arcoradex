"use client";
import { useEffect, useRef, useState } from "react";

/**
 * Count-up number with a cubic ease-out rAF tween, plus a self-heal timeout
 * that snaps to the final value if rAF is paused (hidden doc / capture).
 * Ported verbatim from the prototype's ui.jsx.
 */
export function AnimatedNumber({
  value,
  decimals = 0,
  prefix = "",
  suffix = "",
  dur = 900,
  animate = true,
}: {
  value: number;
  decimals?: number;
  prefix?: string;
  suffix?: string;
  dur?: number;
  animate?: boolean;
}) {
  const [disp, setDisp] = useState(animate ? 0 : value);
  const prev = useRef(animate ? 0 : value);
  const raf = useRef(0);
  // rAF-driven tween — a genuine external-system (animation frame) sync, so the
  // setState calls here are the allowed effect shape.
  useEffect(() => {
    if (!animate) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- snap to final value when animation is disabled
      setDisp(value);
      prev.current = value;
      return;
    }
    const from = prev.current;
    const to = value;
    const start = performance.now();
    cancelAnimationFrame(raf.current);
    const tick = (now: number) => {
      const p = Math.min(1, (now - start) / dur);
      const e = 1 - Math.pow(1 - p, 3);
      setDisp(from + (to - from) * e);
      if (p < 1) raf.current = requestAnimationFrame(tick);
      else prev.current = to;
    };
    raf.current = requestAnimationFrame(tick);
    // self-heal: if rAF is paused (hidden doc / capture), snap to final value
    const fb = setTimeout(() => {
      setDisp(to);
      prev.current = to;
    }, dur + 320);
    return () => {
      cancelAnimationFrame(raf.current);
      clearTimeout(fb);
    };
  }, [value, animate, dur]);
  const txt = disp.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
  return (
    <span style={{ fontVariantNumeric: "tabular-nums" }}>
      {prefix}
      {txt}
      {suffix}
    </span>
  );
}
