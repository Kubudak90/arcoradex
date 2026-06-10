"use client";
import { useEffect, useState } from "react";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useChainId,
  useSwitchChain,
  useReadContracts,
} from "wagmi";
import { erc20Abi } from "viem";
import { fmtUnits } from "@arcoralabs/dex-sdk";
import { Button } from "@/components/ds/Button";
import { Icon } from "@/components/ds/Icon";
import { CoinBadge } from "@/components/ds/CoinBadge";
import { tokenColor } from "@/components/ds/tokens";
import { ACTIVE_CHAIN } from "@/lib/chain";
import { shortAddr } from "@/lib/utils";
import { useTokensV2 } from "@/components/v2/useTokensV2";
import { pushToast } from "@/components/layout/toast-store";

/**
 * Wallet button + dropdown — ported from the prototype's `WalletButton`, wired
 * to wagmi against Base Sepolia (84532). Three states:
 *   - disconnected → lime primary "Connect wallet" (icon: wallet),
 *   - connecting   → disabled primary with the `ar-spin` spinner,
 *   - connected    → wallet chip (gradient disc + short addr + chevron) that
 *     opens a portfolio dropdown (live V2 token balances + Disconnect).
 *
 * A wrong-chain connection swaps the chip for a "Switch to Base Sepolia" button.
 */
export function ConnectButton() {
  const { address, isConnected } = useAccount();
  const { connectors, connect, isPending: connecting } = useConnect();
  const { disconnect } = useDisconnect();
  const chainId = useChainId();
  const { switchChain, isPending: switchPending } = useSwitchChain();
  const [open, setOpen] = useState(false);

  const wrongChain = isConnected && chainId !== ACTIVE_CHAIN.id;

  // Close the dropdown on any outside click.
  useEffect(() => {
    if (!open) return;
    const close = () => setOpen(false);
    window.addEventListener("click", close);
    return () => window.removeEventListener("click", close);
  }, [open]);

  if (connecting) {
    return (
      <Button variant="primary" size="md" disabled>
        <span
          className="ar-spin"
          style={{
            width: 15,
            height: 15,
            border: "2px solid rgba(22,36,26,.3)",
            borderTopColor: "var(--fg-on-accent)",
            borderRadius: "50%",
            display: "inline-block",
          }}
        />
        Connecting…
      </Button>
    );
  }

  if (!isConnected) {
    const injected = connectors.find((c) => c.id === "injected") ?? connectors[0];
    return (
      <Button
        variant="primary"
        size="md"
        icon="wallet"
        onClick={() => injected && connect({ connector: injected })}
      >
        Connect wallet
      </Button>
    );
  }

  if (wrongChain) {
    return (
      <Button
        variant="primary"
        size="md"
        disabled={switchPending}
        onClick={() => switchChain({ chainId: ACTIVE_CHAIN.id })}
      >
        {switchPending ? "Switching…" : `Switch to ${ACTIVE_CHAIN.name}`}
      </Button>
    );
  }

  return (
    <div style={{ position: "relative" }}>
      <button
        onClick={(e) => {
          e.stopPropagation();
          setOpen((o) => !o);
        }}
        style={{
          display: "inline-flex",
          alignItems: "center",
          gap: 9,
          height: 42,
          padding: "0 12px",
          borderRadius: "var(--radius-md)",
          border: "1px solid var(--border)",
          background: "var(--surface)",
          cursor: "pointer",
          boxShadow: "var(--elev-1)",
        }}
      >
        <span
          style={{
            width: 22,
            height: 22,
            borderRadius: "50%",
            background: "linear-gradient(135deg, var(--sn-sage), var(--accent))",
          }}
        />
        <span style={{ fontFamily: "var(--font-mono)", fontSize: 13, fontWeight: 600 }}>
          {shortAddr(address)}
        </span>
        <Icon name="chevronDown" size={15} style={{ color: "var(--fg-3)" }} />
      </button>
      {open && (
        <WalletDropdown
          onDisconnect={() => {
            disconnect();
            setOpen(false);
            pushToast({ kind: "info", title: "Wallet disconnected" });
          }}
        />
      )}
    </div>
  );
}

function WalletDropdown({ onDisconnect }: { onDisconnect: () => void }) {
  const { address } = useAccount();
  const { tokens } = useTokensV2();

  const { data: balances } = useReadContracts({
    contracts: tokens.map((t) => ({
      address: t.address,
      abi: erc20Abi,
      functionName: "balanceOf" as const,
      args: address ? [address] : undefined,
    })),
    query: { enabled: !!address && tokens.length > 0 },
  });

  const rows = tokens
    .map((t, i) => {
      const raw = balances?.[i]?.result as bigint | undefined;
      return { token: t, raw: raw ?? 0n };
    })
    .filter((r) => r.raw > 0n);

  return (
    <div
      onClick={(e) => e.stopPropagation()}
      style={{
        position: "absolute",
        top: 50,
        right: 0,
        width: 248,
        background: "var(--surface)",
        border: "1px solid var(--border)",
        borderRadius: "var(--radius-lg)",
        boxShadow: "var(--elev-3)",
        padding: 14,
        animation: "ar-pop .2s var(--ease-standard)",
        zIndex: 50,
      }}
    >
      <div className="overline" style={{ fontSize: 10 }}>
        Balances
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 8, marginTop: 10 }}>
        {rows.length === 0 ? (
          <div style={{ fontSize: 13, color: "var(--fg-3)" }}>No balances yet</div>
        ) : (
          rows.map(({ token, raw }) => (
            <div key={token.address} style={{ display: "flex", alignItems: "center", gap: 9 }}>
              <CoinBadge sym={token.symbol} color={tokenColor(token.symbol)} size={22} />
              <span style={{ fontSize: 13, fontWeight: 600 }}>{token.symbol}</span>
              <span
                style={{
                  marginLeft: "auto",
                  fontFamily: "var(--font-mono)",
                  fontSize: 13,
                }}
              >
                {fmtUnits(raw, token.decimals, 2)}
              </span>
            </div>
          ))
        )}
      </div>
      <button
        onClick={onDisconnect}
        style={{
          marginTop: 14,
          width: "100%",
          height: 36,
          borderRadius: "var(--radius-md)",
          border: "1px solid var(--border)",
          background: "transparent",
          color: "var(--fg-2)",
          cursor: "pointer",
          fontSize: 13,
          fontWeight: 600,
          fontFamily: "var(--font-sans)",
        }}
      >
        Disconnect
      </button>
    </div>
  );
}
