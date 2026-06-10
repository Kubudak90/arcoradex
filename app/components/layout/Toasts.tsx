"use client";
import { Icon } from "@/components/ds/Icon";
import { iconBtnStyle } from "@/components/ds/iconBtnStyle";
import { useExplorer } from "@/lib/useActiveChain";
import { useToasts, dismiss, type Toast } from "./toast-store";

/**
 * Toast host — bottom-right stack, ported from the prototype's `Toasts`.
 * Fed by the module-level toast store (`toast-store.ts`); success/info/error
 * icons, and a BaseScan tx link when the toast carries a `hash`.
 */
export function Toasts() {
  const items = useToasts();
  return (
    <div
      style={{
        position: "fixed",
        bottom: 24,
        right: 24,
        zIndex: 300,
        display: "flex",
        flexDirection: "column",
        gap: 10,
        width: 340,
        maxWidth: "90vw",
      }}
    >
      {items.map((t) => (
        <ToastCard key={t.id} t={t} />
      ))}
    </div>
  );
}

function ToastCard({ t }: { t: Toast }) {
  const explorer = useExplorer();
  const accent =
    t.kind === "success"
      ? "var(--success)"
      : t.kind === "error"
        ? "var(--danger)"
        : "var(--info)";
  const iconName = t.kind === "success" ? "checkCircle" : t.kind === "error" ? "info" : "info";
  const shortHash = t.hash ? `${t.hash.slice(0, 10)}…${t.hash.slice(-6)}` : null;
  return (
    <div
      style={{
        display: "flex",
        gap: 12,
        padding: "14px 16px",
        background: "var(--surface)",
        border: "1px solid var(--border)",
        borderRadius: "var(--radius-lg)",
        boxShadow: "var(--elev-3)",
        animation: "ar-toastin .34s var(--ease-emphasized)",
      }}
    >
      <span style={{ marginTop: 1, color: accent }}>
        <Icon name={iconName} size={20} />
      </span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 600, fontSize: 14 }}>{t.title}</div>
        {t.msg && (
          <div style={{ fontSize: 12.5, color: "var(--fg-2)", marginTop: 2 }}>{t.msg}</div>
        )}
        {shortHash && (
          <a
            href={`${explorer}/tx/${t.hash}`}
            target="_blank"
            rel="noreferrer"
            style={{
              fontSize: 11.5,
              color: "var(--fg-3)",
              fontFamily: "var(--font-mono)",
              marginTop: 5,
              display: "inline-flex",
              alignItems: "center",
              gap: 5,
              textDecoration: "none",
            }}
          >
            {shortHash} <Icon name="external" size={12} />
          </a>
        )}
      </div>
      <button
        onClick={() => dismiss(t.id)}
        aria-label="Dismiss"
        style={{ ...iconBtnStyle, width: 26, height: 26 }}
      >
        <Icon name="close" size={15} />
      </button>
    </div>
  );
}
