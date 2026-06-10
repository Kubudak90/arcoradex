"use client";
import { useAccount, useChainId, useSwitchChain } from "wagmi";
import { Icon } from "@/components/ds/Icon";
import { chipNav } from "@/components/layout/chip-style";
import { ACTIVE_CHAIN, ADD_NETWORK_PARAMS } from "@/lib/chain";

/**
 * "Add Base Sepolia" chip — ported from the prototype's nav chip (`chipNav` +
 * plus icon). Calls `wallet_addEthereumChain` to add 84532 to the wallet, with
 * a `switchChain` fallback when already connected. When the wallet is already on
 * the active chain the chip shows a live dot + the chain name.
 */
export function NetworkButton() {
  const chainId = useChainId();
  const { isConnected } = useAccount();
  const { switchChainAsync, isPending } = useSwitchChain();
  const onChain = isConnected && chainId === ACTIVE_CHAIN.id;

  async function onClick() {
    try {
      const eth = (
        window as unknown as { ethereum?: { request: (a: unknown) => Promise<unknown> } }
      ).ethereum;
      if (eth) {
        await eth.request({
          method: "wallet_addEthereumChain",
          params: [ADD_NETWORK_PARAMS],
        });
        return;
      }
      if (isConnected) await switchChainAsync({ chainId: ACTIVE_CHAIN.id });
    } catch {
      // user rejected or wallet not present — no-op
    }
  }

  return (
    <button
      onClick={onClick}
      disabled={isPending}
      style={chipNav}
      onMouseEnter={(e) => (e.currentTarget.style.background = "var(--surface-2)")}
      onMouseLeave={(e) => (e.currentTarget.style.background = "var(--surface)")}
      title={
        onChain
          ? `Connected to ${ACTIVE_CHAIN.name}`
          : `Add ${ACTIVE_CHAIN.name} to your wallet`
      }
    >
      {onChain ? (
        <span
          style={{
            width: 7,
            height: 7,
            borderRadius: "50%",
            background: "var(--success)",
            boxShadow: "0 0 0 3px var(--success-bg)",
          }}
        />
      ) : (
        <Icon name="plus" size={15} />
      )}
      <span className="ar-hide-sm">
        {isPending ? "Switching…" : onChain ? ACTIVE_CHAIN.name : `Add ${ACTIVE_CHAIN.name}`}
      </span>
    </button>
  );
}
