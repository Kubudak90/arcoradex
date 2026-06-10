import type { CSSProperties, ReactNode } from "react";

/**
 * Overline label — wraps the `.overline` type role (mono, uppercase, caps
 * tracking, --fg-3). Ported verbatim from the prototype's ui.jsx.
 */
export function Overline({
  children,
  style,
}: {
  children: ReactNode;
  style?: CSSProperties;
}) {
  return (
    <div className="overline" style={style}>
      {children}
    </div>
  );
}
