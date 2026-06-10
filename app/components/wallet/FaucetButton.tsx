"use client";
import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { useAccount, useChainId } from "wagmi";
import { ACTIVE_CHAIN, EXPLORER } from "@/lib/chain";
import { Icon } from "@/components/ds/Icon";
import { Button } from "@/components/ds/Button";
import { CoinBadge } from "@/components/ds/CoinBadge";
import { tokenColor } from "@/components/ds/tokens";
import { iconBtnStyle } from "@/components/ds/iconBtnStyle";
import { chipNav } from "@/components/layout/chip-style";
import { FAUCET_TOKENS } from "@/lib/faucet-tokens";

interface ClaimResult {
  ok: true;
  recipient: `0x${string}`;
  txHashes: Record<string, `0x${string}`>;
}

// Three user-visible failure classes. The server already returns sensible
// error strings; we use these to attach a distinct icon + tone so 403 (bot)
// doesn't read the same as 429 (rate-limit) or 502 (mint failure).
type FaucetFailure =
  | { kind: "bot"; message: string }
  | { kind: "rate-limit"; message: string; retryAfterSec?: number }
  | { kind: "generic"; message: string };

interface ServerError {
  ok: false;
  error: string;
  retryAfterSec?: number;
}

function classifyFailure(status: number, data: ServerError): FaucetFailure {
  if (status === 403) return { kind: "bot", message: data.error };
  if (status === 429) return { kind: "rate-limit", message: data.error, retryAfterSec: data.retryAfterSec };
  return { kind: "generic", message: data.error };
}

function formatRetryAfter(sec: number | undefined): string | null {
  if (!sec || sec <= 0) return null;
  if (sec < 60) return `${sec}s`;
  if (sec < 3600) return `${Math.ceil(sec / 60)}m`;
  return `${Math.ceil(sec / 3600)}h`;
}

// M-11 (audit 2026-05-24): derive the displayed mint list from the same
// source of truth the server route mints from. Previously this was a hand-
// maintained duplicate that silently drifted from the canonical amounts.
const TOKEN_LIST = FAUCET_TOKENS.map((t) => ({
  sym: t.symbol,
  amt: t.amount.toLocaleString("en-US"),
}));

export function FaucetButton() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState(false);
  const [result, setResult] = useState<ClaimResult | null>(null);
  const [failure, setFailure] = useState<FaucetFailure | null>(null);
  const [mounted, setMounted] = useState(false);

  const wrongChain = isConnected && chainId !== ACTIVE_CHAIN.id;
  const explorer = EXPLORER;

  // Portal target — the header has a backdrop-filter, which creates a containing
  // block for `position: fixed`, so the overlay must portal to <body> to center
  // on the viewport (not the 64px-tall header). Mounted-gated for SSR safety.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- one-shot client mount flag for the portal
    setMounted(true);
  }, []);

  // Escape-to-close (matches the prototype TokenSelectModal).
  useEffect(() => {
    if (!open) return;
    const k = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, [open]);

  async function claim() {
    if (!address) return;
    setPending(true);
    setFailure(null);
    setResult(null);
    try {
      const res = await fetch("/api/faucet", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ address }),
      });
      const data = (await res.json()) as ClaimResult | ServerError;
      if (!data.ok) {
        setFailure(classifyFailure(res.status, data));
      } else {
        setResult(data);
      }
    } catch (e) {
      setFailure({ kind: "generic", message: `Network error: ${(e as Error).message}` });
    } finally {
      setPending(false);
    }
  }

  return (
    <>
      <button
        onClick={() => setOpen(true)}
        style={chipNav}
        onMouseEnter={(e) => (e.currentTarget.style.background = "var(--surface-2)")}
        onMouseLeave={(e) => (e.currentTarget.style.background = "var(--surface)")}
      >
        <Icon name="droplet" size={15} style={{ color: "var(--action)" }} />
        <span className="ar-hide-sm">Faucet</span>
      </button>

      {open &&
        mounted &&
        createPortal(
          <div
            onClick={() => setOpen(false)}
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
            role="dialog"
            aria-modal="true"
            aria-label="Test token faucet"
            style={{
              width: 440,
              maxWidth: "92vw",
              maxHeight: "86vh",
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
                padding: "18px 18px 6px",
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
              }}
            >
              <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                <span
                  style={{
                    width: 32,
                    height: 32,
                    display: "grid",
                    placeItems: "center",
                    borderRadius: "var(--radius-md)",
                    background: "rgba(200,242,74,.16)",
                    border: "1px solid rgba(200,242,74,.32)",
                    color: "var(--action)",
                  }}
                >
                  <Icon name="droplet" size={17} />
                </span>
                <div style={{ fontWeight: 700, fontSize: 16 }}>Test token faucet</div>
              </div>
              <button
                onClick={() => setOpen(false)}
                style={iconBtnStyle}
                aria-label="Close"
                onMouseEnter={(e) => (e.currentTarget.style.background = "var(--surface-2)")}
                onMouseLeave={(e) => (e.currentTarget.style.background = "transparent")}
              >
                <Icon name="close" size={18} />
              </button>
            </div>

            <div style={{ padding: "0 18px 18px", overflowY: "auto" }}>
              <p style={{ fontSize: 13.5, color: "var(--fg-3)", margin: "0 0 14px", lineHeight: 1.5 }}>
                Mint a fresh batch of mock stablecoins to your connected wallet on{" "}
                {ACTIVE_CHAIN.name}. One claim per 24 hours per address.
              </p>

              <div
                style={{
                  borderRadius: "var(--radius-lg)",
                  border: "1px solid var(--border)",
                  background: "var(--surface-2)",
                  padding: 14,
                }}
              >
                <div className="overline" style={{ fontSize: 10, marginBottom: 10 }}>
                  You receive
                </div>
                <div style={{ display: "flex", flexDirection: "column", gap: 9 }}>
                  {TOKEN_LIST.map((t) => (
                    <div
                      key={t.sym}
                      style={{ display: "flex", alignItems: "center", gap: 10 }}
                    >
                      <CoinBadge sym={t.sym} color={tokenColor(t.sym)} size={26} />
                      <span style={{ fontSize: 13.5, fontWeight: 600 }}>{t.sym}</span>
                      <span
                        style={{
                          marginLeft: "auto",
                          fontFamily: "var(--font-mono)",
                          fontSize: 13.5,
                          fontWeight: 600,
                        }}
                      >
                        {t.amt}
                      </span>
                    </div>
                  ))}
                </div>
              </div>

              {!isConnected ? (
                <p
                  style={{
                    fontSize: 13.5,
                    color: "var(--fg-3)",
                    textAlign: "center",
                    marginTop: 16,
                  }}
                >
                  Connect a wallet first.
                </p>
              ) : wrongChain ? (
                <p
                  style={{
                    fontSize: 13.5,
                    color: "var(--warning)",
                    textAlign: "center",
                    marginTop: 16,
                  }}
                >
                  Switch to {ACTIVE_CHAIN.name} to claim.
                </p>
              ) : result ? (
                <div style={{ marginTop: 16 }}>
                  <p
                    style={{
                      fontSize: 13,
                      color: "var(--success)",
                      textAlign: "center",
                      margin: "0 0 10px",
                      display: "flex",
                      alignItems: "center",
                      justifyContent: "center",
                      gap: 6,
                    }}
                  >
                    <Icon name="checkCircle" size={16} /> Claim broadcast. Tokens should appear
                    in seconds.
                  </p>
                  <div
                    style={{
                      borderRadius: "var(--radius-md)",
                      background: "var(--surface-2)",
                      border: "1px solid var(--border)",
                      padding: 12,
                      maxHeight: 160,
                      overflowY: "auto",
                    }}
                  >
                    {Object.entries(result.txHashes).map(([sym, hash]) => (
                      <div
                        key={sym}
                        style={{
                          display: "flex",
                          justifyContent: "space-between",
                          padding: "3px 0",
                          fontSize: 12.5,
                        }}
                      >
                        <span style={{ color: "var(--fg-2)" }}>{sym}</span>
                        <a
                          href={`${explorer}/tx/${hash}`}
                          target="_blank"
                          rel="noreferrer"
                          style={{
                            fontFamily: "var(--font-mono)",
                            color: "var(--action)",
                            textDecoration: "none",
                            display: "inline-flex",
                            alignItems: "center",
                            gap: 4,
                          }}
                        >
                          {hash.slice(0, 10)}… <Icon name="external" size={12} />
                        </a>
                      </div>
                    ))}
                  </div>
                </div>
              ) : (
                <div style={{ marginTop: 16 }}>
                  <Button
                    variant="primary"
                    size="lg"
                    full
                    icon="droplet"
                    disabled={pending}
                    onClick={claim}
                  >
                    {pending ? "Minting…" : "Claim test tokens"}
                  </Button>
                </div>
              )}

              {/* M-9 (audit 2026-05-24): a11y wrapper. role="alert" + aria-live so
                  screen readers announce the failure when it appears. The region
                  is rendered unconditionally so AT can pick up the live mutation. */}
              <div role="alert" aria-live="assertive" aria-atomic="true">
                {failure ? <FailureNotice failure={failure} /> : null}
              </div>
            </div>
          </div>
          </div>,
          document.body,
        )}
    </>
  );
}

function FailureNotice({ failure }: { failure: FaucetFailure }) {
  if (failure.kind === "bot") {
    return (
      <div
        style={{
          marginTop: 14,
          borderRadius: "var(--radius-md)",
          border: "1px solid color-mix(in srgb, var(--warning) 45%, transparent)",
          background: "var(--warning-bg)",
          padding: "10px 12px",
          display: "flex",
          alignItems: "flex-start",
          gap: 9,
        }}
      >
        <Icon name="shield" size={17} style={{ color: "var(--warning)", marginTop: 1 }} />
        <div style={{ fontSize: 12.5, color: "var(--fg-2)", lineHeight: 1.5 }}>
          <div style={{ fontWeight: 600, color: "var(--fg-1)", marginBottom: 2 }}>
            Request flagged as automated
          </div>
          <div>
            If you&apos;re on a VPN, headless browser, or a private window with strict
            anti-fingerprinting, switch to a normal browser and try again.
          </div>
        </div>
      </div>
    );
  }
  if (failure.kind === "rate-limit") {
    const remaining = formatRetryAfter(failure.retryAfterSec);
    return (
      <div
        style={{
          marginTop: 14,
          borderRadius: "var(--radius-md)",
          border: "1px solid var(--border)",
          background: "var(--surface-2)",
          padding: "10px 12px",
          display: "flex",
          alignItems: "flex-start",
          gap: 9,
        }}
      >
        <Icon name="clock" size={17} style={{ color: "var(--fg-3)", marginTop: 1 }} />
        <div style={{ fontSize: 12.5, color: "var(--fg-2)", lineHeight: 1.5 }}>
          <div style={{ fontWeight: 600, color: "var(--fg-1)", marginBottom: 2 }}>
            Cooldown active{remaining ? ` — try again in ${remaining}` : ""}
          </div>
          <div>{failure.message}</div>
        </div>
      </div>
    );
  }
  return (
    <p
      style={{
        marginTop: 14,
        fontSize: 12.5,
        textAlign: "center",
        color: "var(--danger)",
      }}
    >
      {failure.message}
    </p>
  );
}
