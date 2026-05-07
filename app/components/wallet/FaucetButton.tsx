"use client";
import { useState } from "react";
import { useAccount, useChainId } from "wagmi";
import { arcTestnet } from "@arcoralabs/dex-sdk";
import { Modal } from "@/components/ui/modal";

interface ClaimResult {
  ok: true;
  recipient: `0x${string}`;
  txHashes: Record<string, `0x${string}`>;
}

const TOKEN_LIST = [
  { sym: "USDC", amt: "1,000" },
  { sym: "USDT", amt: "1,000" },
  { sym: "PYUSD", amt: "1,000" },
  { sym: "DAI", amt: "1,000" },
  { sym: "EURC", amt: "925" },
  { sym: "TRYC", amt: "34,500" },
  { sym: "BRLC", amt: "5,000" },
];

export function FaucetButton() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState(false);
  const [result, setResult] = useState<ClaimResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  const wrongChain = isConnected && chainId !== arcTestnet.id;
  const explorer = process.env.NEXT_PUBLIC_BLOCK_EXPLORER || "https://testnet.arcscan.app";

  async function claim() {
    if (!address) return;
    setPending(true);
    setError(null);
    setResult(null);
    try {
      const res = await fetch("/api/faucet", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ address }),
      });
      const data = (await res.json()) as
        | ClaimResult
        | { ok: false; error: string };
      if (!data.ok) {
        setError(data.error);
      } else {
        setResult(data);
      }
    } catch (e) {
      setError(`Network error: ${(e as Error).message}`);
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
          Mint a fresh batch of mock stablecoins to your connected wallet on Arc Testnet. One claim
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
            Switch to Arc Testnet to claim.
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

        {error ? (
          <p className="mt-3 text-xs text-center" style={{ color: "var(--color-danger)" }}>
            {error}
          </p>
        ) : null}
      </Modal>
    </>
  );
}
