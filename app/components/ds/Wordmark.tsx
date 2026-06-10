/**
 * Brand wordmark — the lime-disc mark + "arcora"+"dex" lowercase wordmark.
 * Ported verbatim from the prototype's ui.jsx.
 */
export function Wordmark({ size = 20 }: { size?: number }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 9, userSelect: "none" }}>
      <span
        style={{
          position: "relative",
          width: size * 1.3,
          height: size * 1.3,
          display: "inline-block",
        }}
      >
        <span
          style={{
            position: "absolute",
            inset: 0,
            borderRadius: "30%",
            background: "linear-gradient(140deg, var(--sn-sage), var(--accent))",
            transform: "rotate(8deg)",
            boxShadow: "0 4px 14px rgba(200,242,74,.28)",
          }}
        />
        <span
          style={{
            position: "absolute",
            inset: "22%",
            borderRadius: "26%",
            background: "var(--sn-ink)",
            display: "grid",
            placeItems: "center",
          }}
        >
          <span
            style={{
              width: "44%",
              height: "44%",
              borderRadius: "50%",
              border: "2.2px solid var(--accent)",
              borderTopColor: "transparent",
              transform: "rotate(-20deg)",
            }}
          />
        </span>
      </span>
      <span
        style={{
          fontWeight: 800,
          fontSize: size,
          letterSpacing: "-0.02em",
          color: "var(--fg-1)",
        }}
      >
        arcora<span style={{ color: "var(--action)" }}>dex</span>
      </span>
    </div>
  );
}
