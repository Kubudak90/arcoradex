import type { CSSProperties } from "react";

/**
 * Shared nav-chip style — the prototype's `chipNav`. A 42px-tall pill with a
 * hairline border and surface background; the label collapses on small screens
 * via `.ar-hide-sm`. Used by the "Add Base Sepolia" chip and the Faucet chip in
 * the header. Hover swaps the background to `--surface-2`.
 */
export const chipNav: CSSProperties = {
  display: "inline-flex",
  alignItems: "center",
  gap: 7,
  height: 42,
  padding: "0 13px",
  whiteSpace: "nowrap",
  borderRadius: "var(--radius-md)",
  border: "1px solid var(--border)",
  background: "var(--surface)",
  color: "var(--fg-2)",
  cursor: "pointer",
  fontSize: 13,
  fontWeight: 600,
  fontFamily: "var(--font-sans)",
  transition: "background var(--dur-fast)",
};
