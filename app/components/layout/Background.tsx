"use client";

type BgStyle = "mesh" | "grid" | "solid";

/**
 * Animated backdrop — ported from the prototype's `Background`. Three radial
 * mesh blobs (sage / accent / green) that drift via `ar-float1..3`, plus an
 * optional masked grid. Rendered `position:fixed; inset:0; z-index:0` behind the
 * shell. Motion is gated by `prefers-reduced-motion` (the keyframes are paused
 * for that media query in globals.css; the `motion` prop is the explicit gate).
 */
export function Background({
  style = "mesh",
  motion = true,
}: {
  style?: BgStyle;
  motion?: boolean;
}) {
  if (style === "solid") return null;
  const blobs = [
    { c: "var(--sn-sage)", x: "8%", y: "12%", s: 520, o: 0.16, d: "ar-float1" },
    { c: "var(--accent)", x: "82%", y: "8%", s: 440, o: 0.12, d: "ar-float2" },
    { c: "var(--sn-green)", x: "70%", y: "78%", s: 560, o: 0.1, d: "ar-float3" },
  ];
  return (
    <div
      aria-hidden
      style={{ position: "fixed", inset: 0, zIndex: 0, overflow: "hidden", pointerEvents: "none" }}
    >
      {style === "grid" && (
        <div
          style={{
            position: "absolute",
            inset: 0,
            backgroundImage:
              "linear-gradient(var(--border-faint) 1px, transparent 1px), linear-gradient(90deg, var(--border-faint) 1px, transparent 1px)",
            backgroundSize: "44px 44px",
            maskImage: "radial-gradient(circle at 50% 35%, #000 0%, transparent 78%)",
            WebkitMaskImage: "radial-gradient(circle at 50% 35%, #000 0%, transparent 78%)",
            opacity: 0.5,
          }}
        />
      )}
      {blobs.map((b, i) => (
        <div
          key={i}
          style={{
            position: "absolute",
            left: b.x,
            top: b.y,
            width: b.s,
            height: b.s,
            background: `radial-gradient(circle, ${b.c}, transparent 68%)`,
            opacity: b.o,
            borderRadius: "50%",
            filter: "blur(40px)",
            transform: "translate(-50%,-50%)",
            animation: motion ? `${b.d} ${22 + i * 6}s ease-in-out infinite` : "none",
          }}
        />
      ))}
    </div>
  );
}
