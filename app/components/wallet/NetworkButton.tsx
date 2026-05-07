"use client";
import { useAccount, useChainId, useSwitchChain } from "wagmi";
import { arcTestnet } from "@arcoralabs/dex-sdk";

const EXPLORER_URL =
  process.env.NEXT_PUBLIC_BLOCK_EXPLORER || "https://testnet.arcscan.app";

export function NetworkButton() {
  const chainId = useChainId();
  const { isConnected } = useAccount();
  const { switchChainAsync, isPending } = useSwitchChain();
  const onArc = isConnected && chainId === arcTestnet.id;

  async function onClick() {
    try {
      if (isConnected) {
        await switchChainAsync({ chainId: arcTestnet.id });
        return;
      }
      const eth = (window as unknown as { ethereum?: { request: (a: unknown) => Promise<unknown> } })
        .ethereum;
      if (!eth) return;
      await eth.request({
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId: `0x${arcTestnet.id.toString(16)}`,
            chainName: arcTestnet.name,
            nativeCurrency: arcTestnet.nativeCurrency,
            rpcUrls: arcTestnet.rpcUrls.default.http,
            blockExplorerUrls: [EXPLORER_URL],
          },
        ],
      });
    } catch {
      // user rejected or wallet not present — no-op
    }
  }

  if (onArc) {
    return (
      <a
        href={EXPLORER_URL}
        target="_blank"
        rel="noreferrer"
        className="hidden sm:inline-flex items-center gap-1.5 h-9 px-3.5 rounded-full text-[13px] font-medium bg-arc-ink-50 text-arc-ink-900 hover:bg-arc-ink-100 transition-colors"
        title="View Arc Testnet explorer"
      >
        <span className="dot live" />
        Arc Testnet
      </a>
    );
  }

  return (
    <button
      onClick={onClick}
      disabled={isPending}
      className="hidden sm:inline-flex items-center gap-1.5 h-9 px-3.5 rounded-full text-[13px] font-medium bg-arc-ink-50 text-arc-ink-900 hover:bg-arc-ink-100 transition-colors disabled:opacity-60"
      title={isConnected ? "Switch to Arc Testnet" : "Add Arc Testnet to your wallet"}
    >
      <span className="ms" style={{ fontSize: 16 }}>
        add_link
      </span>
      {isPending ? "Switching…" : isConnected ? "Switch network" : "Add Arc Testnet"}
    </button>
  );
}
