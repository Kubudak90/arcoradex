"use client";
import { useState } from "react";
import { useAccount, useChainId } from "wagmi";
import { ACTIVE_CHAIN, EXPLORER } from "@/lib/chain";
import { Modal } from "@/components/ui/modal";
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

  const wrongChain = isConnected && chainId !== ACTIVE_CHAIN.id;
  const explorer = EXPLORER;

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
        className="hidden sm:inline-flex items-center gap-1.5 h-9 px-3.5 rounded-full text-[13px] font-medium bg-arc-ink-50 text-arc-ink-900 hover:bg-arc-ink-100 transition-colors"
      >
        <span className="ms" style={{ fontSize: 16 }}>
          water_drop
        </span>
        Faucet
      </button>

      <Modal open={open} onOpenChange={setOpen} title="Test token faucet">
        <p className="text-sm text-arc-ink-500 m-0">
          Mint a fresh batch of mock stablecoins to your connected wallet on {ACTIVE_CHAIN.name}. One claim
          per 24 hours per address.
        </p>

        <div className="rounded-2xl border border-arc-ink-100 bg-surface-tint p-4 mt-4">
          <div className="t-label m-0 mb-2">You receive</div>
          <ul className="grid grid-cols-2 gap-y-1.5 text-sm m-0 p-0 list-none">
            {TOKEN_LIST.map((t) => (
              <li key={t.sym} className="flex justify-between gap-3">
                <span className="text-arc-ink-700">{t.sym}</span>
                <span className="t-mono text-arc-ink-900">{t.amt}</span>
              </li>
            ))}
          </ul>
        </div>

        {!isConnected ? (
          <p className="text-sm text-arc-ink-500 text-center mt-4">
            Connect a wallet first.
          </p>
        ) : wrongChain ? (
          <p className="text-sm text-center mt-4" style={{ color: "var(--color-warn)" }}>
            Switch to {ACTIVE_CHAIN.name} to claim.
          </p>
        ) : result ? (
          <div className="mt-4 space-y-2 text-xs">
            <p className="text-center" style={{ color: "var(--color-success)" }}>
              ✓ Claim broadcast. Tokens should appear in seconds.
            </p>
            <div className="rounded-xl bg-surface-tint p-3 max-h-40 overflow-y-auto">
              {Object.entries(result.txHashes).map(([sym, hash]) => (
                <div key={sym} className="flex justify-between py-0.5">
                  <span className="text-arc-ink-700">{sym}</span>
                  <a
                    href={`${explorer}/tx/${hash}`}
                    target="_blank"
                    rel="noreferrer"
                    className="t-mono text-arc-blue-600 hover:underline"
                  >
                    {hash.slice(0, 10)}…
                  </a>
                </div>
              ))}
            </div>
          </div>
        ) : (
          <button
            onClick={claim}
            disabled={pending}
            className="w-full inline-flex items-center justify-center h-12 rounded-full text-[15px] font-medium text-white mt-4 transition-all disabled:opacity-50"
            style={{ background: "var(--grad-arcora)", boxShadow: "var(--shadow-glow)" }}
          >
            {pending ? "Minting…" : "Claim test tokens"}
          </button>
        )}

        {/* M-9 (audit 2026-05-24): a11y wrapper. role="alert" + aria-live so
            screen readers announce the failure when it appears. The region
            is rendered unconditionally so AT can pick up the live mutation. */}
        <div role="alert" aria-live="assertive" aria-atomic="true">
          {failure ? <FailureNotice failure={failure} /> : null}
        </div>
      </Modal>
    </>
  );
}

function FailureNotice({ failure }: { failure: FaucetFailure }) {
  if (failure.kind === "bot") {
    return (
      <div
        className="mt-3 rounded-xl border px-3 py-2.5 flex items-start gap-2 text-xs"
        // Soft amber tone using the existing --color-warn token at low opacity.
        style={{ borderColor: "color-mix(in srgb, var(--color-warn) 50%, transparent)", background: "color-mix(in srgb, var(--color-warn) 10%, var(--surface))" }}
      >
        <span className="ms" style={{ fontSize: 18, color: "var(--color-warn)" }}>
          shield_person
        </span>
        <div className="text-left text-arc-ink-700">
          <div className="font-medium text-arc-ink-900 mb-0.5">Request flagged as automated</div>
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
        className="mt-3 rounded-xl border px-3 py-2.5 flex items-start gap-2 text-xs"
        style={{ borderColor: "var(--arc-ink-200)", background: "var(--surface-tint)" }}
      >
        <span className="ms" style={{ fontSize: 18, color: "var(--arc-ink-500)" }}>
          schedule
        </span>
        <div className="text-left text-arc-ink-700">
          <div className="font-medium text-arc-ink-900 mb-0.5">
            Cooldown active{remaining ? ` — try again in ${remaining}` : ""}
          </div>
          <div>{failure.message}</div>
        </div>
      </div>
    );
  }
  return (
    <p className="mt-3 text-xs text-center" style={{ color: "var(--color-danger)" }}>
      {failure.message}
    </p>
  );
}
