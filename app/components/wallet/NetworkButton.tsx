"use client";
import { useAccount, useChainId, useSwitchChain } from "wagmi";
import { ACTIVE_CHAIN, ADD_NETWORK_PARAMS } from "@/lib/chain";

export function NetworkButton() {
  const chainId = useChainId();
  const { isConnected } = useAccount();
  const { switchChainAsync, isPending } = useSwitchChain();
  const onChain = isConnected && chainId === ACTIVE_CHAIN.id;

  async function onClick() {
    try {
      if (isConnected) {
        await switchChainAsync({ chainId: ACTIVE_CHAIN.id });
        return;
      }
      const eth = (window as unknown as { ethereum?: { request: (a: unknown) => Promise<unknown> } })
        .ethereum;
      if (!eth) return;
      await eth.request({
        method: "wallet_addEthereumChain",
        params: [ADD_NETWORK_PARAMS],
      });
    } catch {
      // user rejected or wallet not present — no-op
    }
  }

  const label = isPending
    ? "Switching…"
    : onChain
      ? ACTIVE_CHAIN.name
      : isConnected
        ? `Switch to ${ACTIVE_CHAIN.name}`
        : `Add ${ACTIVE_CHAIN.name}`;

  return (
    <button
      onClick={onClick}
      disabled={isPending}
      className="hidden sm:inline-flex items-center gap-1.5 h-9 px-3.5 rounded-full text-[13px] font-medium bg-arc-ink-50 text-arc-ink-900 hover:bg-arc-ink-100 transition-colors disabled:opacity-60"
      title={onChain ? `Already on ${ACTIVE_CHAIN.name} — click to re-confirm` : `Force wallet to ${ACTIVE_CHAIN.name}`}
    >
      {onChain ? (
        <span className="dot live" />
      ) : (
        <span className="ms" style={{ fontSize: 16 }}>
          add_link
        </span>
      )}
      {label}
    </button>
  );
}
