"use client";
import { useAccount, useConnect, useDisconnect, useChainId, useSwitchChain } from "wagmi";
import { arcTestnet } from "@/lib/wagmi";
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
        className="px-4 py-2 rounded-md bg-arcora-blue-500 text-white hover:bg-arcora-blue-600 transition disabled:opacity-50"
      >
        {switchPending ? "Switching…" : "Switch to Arc Testnet"}
      </button>
    );
  }

  if (isConnected) {
    return (
      <button
        onClick={() => disconnect()}
        className="px-4 py-2 rounded-md border border-border-strong text-fg hover:bg-bg-elevated transition"
      >
        {shortAddr(address)}
      </button>
    );
  }

  const injected = connectors.find((c) => c.id === "injected") || connectors[0];

  return (
    <button
      onClick={() => connect({ connector: injected })}
      disabled={isPending}
      className="px-4 py-2 rounded-md bg-arcora-blue-500 text-white hover:bg-arcora-blue-600 transition disabled:opacity-50"
    >
      {isPending ? "Connecting…" : "Connect Wallet"}
    </button>
  );
}
