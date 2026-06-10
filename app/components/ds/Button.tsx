"use client";
import {
  useState,
  type ButtonHTMLAttributes,
  type CSSProperties,
  type ReactNode,
} from "react";
import { Icon, type IconName } from "./Icon";

type Variant = "primary" | "brand" | "secondary" | "ghost" | "danger";
type Size = "sm" | "md" | "lg";

/**
 * Button — 5 variants (primary lime / brand / secondary / ghost / danger),
 * 3 sizes, hover/active state machine, and the --accent lime primary with the
 * `0 2px 12px rgba(200,242,74,.32)` glow. Ported verbatim from the prototype's
 * ui.jsx.
 */
export function Button({
  variant = "primary",
  size = "md",
  children,
  icon,
  iconRight,
  full,
  disabled,
  onClick,
  style,
  ...rest
}: {
  variant?: Variant;
  size?: Size;
  children?: ReactNode;
  icon?: IconName;
  iconRight?: IconName;
  full?: boolean;
  disabled?: boolean;
  onClick?: () => void;
  style?: CSSProperties;
} & Omit<ButtonHTMLAttributes<HTMLButtonElement>, "style" | "onClick">) {
  const [h, setH] = useState(false);
  const [a, setA] = useState(false);
  const sizes = {
    sm: { padding: "0 12px", height: 34, fontSize: 13, radius: "var(--radius-md)" },
    md: { padding: "0 16px", height: 42, fontSize: 14.5, radius: "var(--radius-md)" },
    lg: { padding: "0 20px", height: 54, fontSize: 16, radius: "var(--radius-lg)" },
  }[size];
  const variants: Record<Variant, { bg: string; fg: string; bd: string; sh: string }> = {
    primary: {
      bg: h ? "var(--accent-hover)" : "var(--accent)",
      fg: "var(--fg-on-accent)",
      bd: "transparent",
      sh: "0 2px 12px rgba(200,242,74,.32)",
    },
    brand: {
      bg: h ? "var(--brand-hover)" : "var(--brand)",
      fg: "var(--fg-on-brand)",
      bd: "transparent",
      sh: "var(--elev-1)",
    },
    secondary: {
      bg: h ? "var(--surface-2)" : "var(--surface)",
      fg: "var(--fg-1)",
      bd: "var(--border-strong)",
      sh: "none",
    },
    ghost: {
      bg: h ? "var(--surface-2)" : "transparent",
      fg: "var(--fg-2)",
      bd: "transparent",
      sh: "none",
    },
    danger: {
      bg: h ? "var(--danger)" : "var(--danger-bg)",
      fg: h ? "#fff" : "var(--danger)",
      bd: "transparent",
      sh: "none",
    },
  };
  const v = variants[variant];
  return (
    <button
      onClick={disabled ? undefined : onClick}
      onMouseEnter={() => setH(true)}
      onMouseLeave={() => {
        setH(false);
        setA(false);
      }}
      onMouseDown={() => setA(true)}
      onMouseUp={() => setA(false)}
      disabled={disabled}
      style={{
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        gap: 8,
        height: sizes.height,
        padding: sizes.padding,
        fontSize: sizes.fontSize,
        fontWeight: 600,
        fontFamily: "var(--font-sans)",
        borderRadius: sizes.radius,
        border: `1px solid ${v.bd}`,
        background: v.bg,
        color: v.fg,
        cursor: disabled ? "not-allowed" : "pointer",
        width: full ? "100%" : undefined,
        boxShadow: v.sh,
        opacity: disabled ? 0.5 : 1,
        whiteSpace: "nowrap",
        transform: a ? "scale(.985)" : "none",
        transition:
          "background var(--dur-fast), transform var(--dur-fast), box-shadow var(--dur-base)",
        letterSpacing: "-0.01em",
        ...style,
      }}
      {...rest}
    >
      {icon && <Icon name={icon} size={size === "lg" ? 20 : 17} />}
      {children}
      {iconRight && <Icon name={iconRight} size={size === "lg" ? 20 : 17} />}
    </button>
  );
}
