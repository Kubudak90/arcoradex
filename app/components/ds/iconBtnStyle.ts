import type { CSSProperties } from "react";

/**
 * Shared icon-button style — a 34px square, transparent, hairline-border-on-hover
 * ghost button. Ported verbatim from the prototype's ui.jsx (`iconBtnStyle`),
 * used by the TokenSelectModal close button and the swap header settings button.
 */
export const iconBtnStyle: CSSProperties = {
  display: "grid",
  placeItems: "center",
  width: 34,
  height: 34,
  borderRadius: "var(--radius-md)",
  background: "transparent",
  border: "1px solid transparent",
  color: "var(--fg-2)",
  cursor: "pointer",
  transition: "background var(--dur-fast)",
};
