"use client";
import { useEffect, useState } from "react";
import { useAccount, useChainId, useSwitchChain } from "wagmi";
import type { Chain } from "viem";
import { Icon } from "@/components/ds/Icon";
import { chipNav } from "@/components/layout/chip-style";
import {
  SUPPORTED_CHAINS,
  addNetworkParams,
  chainById,
  isSupportedChain,
} from "@/lib/chain";

/**
 * Header chain switcher — replaces the single "Add Base Sepolia" chip. Lists
 * every supported V2 chain (Arc testnet + Base Sepolia), shows the active one
 * (colored dot + name), and switches the wallet via wagmi `switchChain`, with a
 * `wallet_addEthereumChain` fallback when the wallet doesn't know the network
 * (error 4902). When the wallet is on an UNSUPPORTED chain, the chip turns into
 * a warning prompt to switch to the default chain.
 *
 * Matches the prototype's nav-chip (`chipNav`) + the lime accent dropdown
 * (mirrors WalletDropdown / FaucetButton).
 */

// Per-chain dot color: lime accent for Arc (USDC-native), Circle blue for Base.
const CHAIN_DOT: Record<number, string> = {
  84532: "#2775CA",
  5042002: "var(--accent)",
};

function chainDot(id: number): string {
  return CHAIN_DOT[id] ?? "var(--fg-3)";
}

export function ChainSwitcher() {
  const chainId = useChainId();
  const { isConnected } = useAccount();
  const { switchChainAsync, isPending } = useSwitchChain();
  const [open, setOpen] = useState(false);

  const supported = isSupportedChain(chainId);
  const active: Chain = chainById(chainId);

  // Close the dropdown on any outside click.
  useEffect(() => {
    if (!open) return;
    const close = () => setOpen(false);
    window.addEventListener("click", close);
    return () => window.removeEventListener("click", close);
  }, [open]);

  async function selectChain(target: Chain) {
    setOpen(false);
    if (target.id === chainId) return;
    try {
      await switchChainAsync({ chainId: target.id as never });
    } catch (err) {
      // 4902 = wallet doesn't know this chain → add it, then it becomes active.
      const code = (err as { code?: number } | undefined)?.code;
      const eth = (
        window as unknown as { ethereum?: { request: (a: unknown) => Promise<unknown> } }
      ).ethereum;
      if ((code === 4902 || code === undefined) && eth) {
        try {
          await eth.request({
            method: "wallet_addEthereumChain",
            params: [addNetworkParams(target)],
          });
        } catch {
          // user rejected the add — no-op
        }
      }
      // any other error (user rejected the switch) → no-op
    }
  }

  return (
    <div style={{ position: "relative" }}>
      <button
        onClick={(e) => {
          e.stopPropagation();
          setOpen((o) => !o);
        }}
        disabled={isPending}
        style={{
          ...chipNav,
          ...(isConnected && !supported
            ? {
                borderColor: "color-mix(in srgb, var(--warning) 45%, transparent)",
                background: "var(--warning-bg)",
                color: "var(--warning)",
              }
            : null),
        }}
        onMouseEnter={(e) => {
          if (!(isConnected && !supported))
            e.currentTarget.style.background = "var(--surface-2)";
        }}
        onMouseLeave={(e) => {
          if (!(isConnected && !supported))
            e.currentTarget.style.background = "var(--surface)";
        }}
        title={
          isConnected && !supported
            ? "Unsupported network — switch to a supported chain"
            : `Network: ${active.name}`
        }
        aria-haspopup="listbox"
        aria-expanded={open}
      >
        {isConnected && !supported ? (
          <Icon name="info" size={15} />
        ) : (
          <span
            style={{
              width: 8,
              height: 8,
              borderRadius: "50%",
              background: chainDot(active.id),
              boxShadow: `0 0 0 3px color-mix(in srgb, ${chainDot(active.id)} 22%, transparent)`,
            }}
          />
        )}
        <span className="ar-hide-sm">
          {isPending
            ? "Switching…"
            : isConnected && !supported
              ? "Wrong network"
              : active.name}
        </span>
        <Icon name="chevronDown" size={14} style={{ color: "currentColor", opacity: 0.7 }} />
      </button>

      {open && (
        <div
          onClick={(e) => e.stopPropagation()}
          role="listbox"
          aria-label="Select network"
          style={{
            position: "absolute",
            top: 50,
            right: 0,
            width: 232,
            background: "var(--surface)",
            border: "1px solid var(--border)",
            borderRadius: "var(--radius-lg)",
            boxShadow: "var(--elev-3)",
            padding: 8,
            animation: "ar-pop .2s var(--ease-standard)",
            zIndex: 60,
          }}
        >
          <div className="overline" style={{ fontSize: 10, padding: "4px 8px 8px" }}>
            Network
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
            {SUPPORTED_CHAINS.map((c) => {
              const isActive = c.id === chainId;
              return (
                <button
                  key={c.id}
                  role="option"
                  aria-selected={isActive}
                  onClick={() => selectChain(c)}
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 10,
                    width: "100%",
                    height: 40,
                    padding: "0 10px",
                    borderRadius: "var(--radius-md)",
                    border: "1px solid transparent",
                    background: isActive ? "var(--surface-2)" : "transparent",
                    color: "var(--fg-1)",
                    cursor: "pointer",
                    fontSize: 13.5,
                    fontWeight: 600,
                    fontFamily: "var(--font-sans)",
                    textAlign: "left",
                    transition: "background var(--dur-fast)",
                  }}
                  onMouseEnter={(e) => (e.currentTarget.style.background = "var(--surface-2)")}
                  onMouseLeave={(e) =>
                    (e.currentTarget.style.background = isActive
                      ? "var(--surface-2)"
                      : "transparent")
                  }
                >
                  <span
                    style={{
                      width: 9,
                      height: 9,
                      borderRadius: "50%",
                      background: chainDot(c.id),
                      flexShrink: 0,
                    }}
                  />
                  <span style={{ flex: 1 }}>{c.name}</span>
                  {isActive && (
                    <Icon name="check" size={16} style={{ color: "var(--action)" }} />
                  )}
                </button>
              );
            })}
          </div>
          {isConnected && !supported && (
            <div
              style={{
                marginTop: 6,
                padding: "8px 10px",
                fontSize: 12,
                color: "var(--fg-3)",
                lineHeight: 1.45,
              }}
            >
              Your wallet is on an unsupported network. Pick one above to
              continue.
            </div>
          )}
        </div>
      )}
    </div>
  );
}
