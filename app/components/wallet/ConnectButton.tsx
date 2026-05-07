"use client";
import { useAccount, useConnect, useDisconnect, useChainId, useSwitchChain } from "wagmi";
import { arcTestnet } from "@arcoralabs/dex-sdk";
import { shortAddr } from "@/lib/utils";

export function ConnectButton() {
  const { address, isConnected } = useAccount();
  const { connectors, connect, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const chainId = useChainId();
  const { switchChain, isPending: switchPending } = useSwitchChain();

  const wrongChain = isConnected && chainId !== arcTestnet.id;

  if (wrongChain) {
    return (
      <button
        onClick={() => switchChain({ chainId: arcTestnet.id })}
        disabled={switchPending}
        className="inline-flex items-center justify-center h-9 px-4 rounded-full text-sm font-medium text-white transition-all disabled:opacity-50"
        style={{ background: "var(--grad-arcora)", boxShadow: "var(--shadow-glow)" }}
      >
        {switchPending ? "Switching…" : "Switch to Arc Testnet"}
      </button>
    );
  }

  if (isConnected) {
    return (
      <button
        onClick={() => disconnect()}
        className="inline-flex items-center gap-2 h-9 px-4 rounded-full text-[13px] font-medium bg-arc-ink-50 text-arc-ink-900 hover:bg-arc-ink-100 transition-colors"
        style={{ fontFamily: "var(--font-mono)" }}
      >
        <span className="dot" />
        {shortAddr(address)}
      </button>
    );
  }

  const injected = connectors.find((c) => c.id === "injected") || connectors[0];

  return (
    <button
      onClick={() => connect({ connector: injected })}
      disabled={isPending}
      className="inline-flex items-center justify-center h-9 px-4 rounded-full text-sm font-medium text-white bg-arc-ink-900 hover:bg-arc-ink-800 transition-all disabled:opacity-50"
    >
      {isPending ? "Connecting…" : "Connect wallet"}
    </button>
  );
}
