"use client";
import { useEffect, useState } from "react";
import { fmtUnits } from "@arcoralabs/dex-sdk";
import type { TokenInfoV2 } from "@arcoralabs/dex-sdk/v2";
import { Icon } from "./Icon";
import { CoinBadge } from "./CoinBadge";
import { tokenColor } from "./tokens";
import { iconBtnStyle } from "./iconBtnStyle";

/**
 * Token-search modal — ported verbatim from the prototype's ui.jsx but typed
 * for the live `TokenInfoV2[]` set + a `balances` map (address-lowercase →
 * bigint). Renders the CoinBadge disc (color via `tokenColor(symbol)`),
 * symbol/name, the formatted balance, and searches by symbol/name/address.
 * `exclude` is the other side's address (rendered disabled · "selected").
 */
export function TokenSelectModal({
  open,
  onClose,
  onPick,
  exclude,
  tokens,
  balances,
}: {
  open: boolean;
  onClose: () => void;
  onPick: (address: `0x${string}`) => void;
  exclude?: `0x${string}`;
  tokens: TokenInfoV2[];
  balances?: Record<string, bigint>;
}) {
  const [q, setQ] = useState("");

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reset the search field each time the modal re-opens
    if (open) setQ("");
  }, [open]);

  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    if (open) window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, [open, onClose]);

  if (!open) return null;

  const needle = q.toLowerCase().trim();
  const list = tokens.filter((t) =>
    `${t.symbol} ${t.name} ${t.address}`.toLowerCase().includes(needle),
  );
  const excludeLc = exclude?.toLowerCase();

  return (
    <div
      onClick={onClose}
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 200,
        display: "grid",
        placeItems: "center",
        background: "rgba(20,40,36,.42)",
        backdropFilter: "blur(4px)",
        animation: "ar-overlay .2s ease",
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          width: 440,
          maxWidth: "92vw",
          maxHeight: "78vh",
          display: "flex",
          flexDirection: "column",
          background: "var(--surface)",
          border: "1px solid var(--border)",
          borderRadius: "var(--radius-xl)",
          boxShadow: "var(--elev-4)",
          overflow: "hidden",
          animation: "ar-pop .26s var(--ease-standard)",
        }}
      >
        <div
          style={{
            padding: "18px 18px 12px",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
          }}
        >
          <div style={{ fontWeight: 700, fontSize: 16 }}>Select a token</div>
          <button onClick={onClose} style={iconBtnStyle} aria-label="Close">
            <Icon name="close" size={18} />
          </button>
        </div>
        <div style={{ padding: "0 18px 12px" }}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 8,
              height: 44,
              padding: "0 12px",
              background: "var(--surface-2)",
              border: "1px solid var(--border)",
              borderRadius: "var(--radius-md)",
            }}
          >
            <Icon name="search" size={17} style={{ color: "var(--fg-3)" }} />
            <input
              autoFocus
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="Search name or paste address"
              style={{
                flex: 1,
                border: "none",
                background: "transparent",
                outline: "none",
                color: "var(--fg-1)",
                fontSize: 14.5,
                fontFamily: "var(--font-sans)",
              }}
            />
          </div>
        </div>
        <div style={{ overflowY: "auto", padding: "4px 8px 12px" }}>
          {list.length === 0 && (
            <div
              style={{
                padding: "20px 12px",
                textAlign: "center",
                fontSize: 13.5,
                color: "var(--fg-3)",
              }}
            >
              No tokens match “{q}”.
            </div>
          )}
          {list.map((t) => {
            const addrLc = t.address.toLowerCase();
            const dis = addrLc === excludeLc;
            const bal = balances?.[addrLc];
            return (
              <button
                key={t.address}
                disabled={dis}
                onClick={() => {
                  onPick(t.address);
                  onClose();
                }}
                style={{
                  width: "100%",
                  display: "flex",
                  alignItems: "center",
                  gap: 12,
                  padding: "10px 12px",
                  background: "transparent",
                  border: "none",
                  borderRadius: "var(--radius-md)",
                  cursor: dis ? "not-allowed" : "pointer",
                  opacity: dis ? 0.4 : 1,
                  textAlign: "left",
                  transition: "background var(--dur-fast)",
                }}
                onMouseEnter={(e) => {
                  if (!dis) e.currentTarget.style.background = "var(--surface-2)";
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.background = "transparent";
                }}
              >
                <CoinBadge sym={t.symbol} color={tokenColor(t.symbol)} size={36} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontWeight: 600, fontSize: 14.5 }}>
                    {t.symbol}{" "}
                    {dis && (
                      <span style={{ color: "var(--fg-3)", fontWeight: 400 }}>· selected</span>
                    )}
                  </div>
                  <div style={{ fontSize: 12.5, color: "var(--fg-3)" }}>{t.name}</div>
                </div>
                <div style={{ textAlign: "right" }}>
                  <div
                    style={{
                      fontSize: 13.5,
                      fontWeight: 600,
                      fontFamily: "var(--font-mono)",
                    }}
                  >
                    {bal != null ? fmtUnits(bal, t.decimals, 2) : "0"}
                  </div>
                </div>
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}
