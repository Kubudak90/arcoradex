"use client";
import { useMemo, useState } from "react";
import { useAccount, useReadContracts } from "wagmi";
import type { TokenInfo } from "@arcoralabs/dex-sdk";
import { fmtUnits } from "@arcoralabs/dex-sdk";
import { erc20Abi } from "viem";
import { Modal } from "@/components/ui/modal";
import { TokenIcon } from "@/components/common/TokenIcon";

interface Props {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  tokens: TokenInfo[];
  onSelect: (addr: `0x${string}`) => void;
  exclude?: `0x${string}`;
}

export function TokenPickerModal({ open, onOpenChange, tokens, onSelect, exclude }: Props) {
  const { address } = useAccount();
  const [q, setQ] = useState("");

  const visibleTokens = useMemo(() => {
    const lower = q.trim().toLowerCase();
    return tokens
      .filter((t) => t.address !== exclude)
      .filter(
        (t) =>
          !lower ||
          t.symbol.toLowerCase().includes(lower) ||
          t.name.toLowerCase().includes(lower) ||
          t.address.toLowerCase().includes(lower),
      );
  }, [tokens, q, exclude]);

  const { data: balances } = useReadContracts({
    contracts: address
      ? visibleTokens.map((t) => ({
          address: t.address,
          abi: erc20Abi,
          functionName: "balanceOf" as const,
          args: [address] as const,
        }))
      : [],
    query: { enabled: !!address && visibleTokens.length > 0 },
  });

  return (
    <Modal open={open} onOpenChange={onOpenChange} title="Select a token">
      <div className="relative mb-4">
        <span
          className="ms absolute left-3.5 top-1/2 -translate-y-1/2 text-arc-ink-400"
          style={{ fontSize: 18 }}
        >
          search
        </span>
        <input
          autoFocus
          placeholder="Search name, symbol, or address"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          className="w-full h-11 pl-11 pr-4 rounded-full border border-arc-ink-200 bg-surface text-sm text-arc-ink-900 placeholder:text-arc-ink-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-arc-blue-200 focus-visible:border-arc-blue-400"
        />
      </div>

      <div className="max-h-[360px] overflow-y-auto -mx-2">
        {visibleTokens.length === 0 ? (
          <p className="text-arc-ink-500 text-sm text-center py-8">No tokens match</p>
        ) : (
          visibleTokens.map((t, i) => {
            const bal =
              balances?.[i]?.status === "success" ? (balances[i].result as bigint) : null;
            return (
              <button
                key={t.address}
                onClick={() => onSelect(t.address)}
                className="w-full flex items-center gap-3 px-3 py-3 rounded-2xl hover:bg-arc-ink-25 transition-colors text-left"
              >
                <TokenIcon symbol={t.symbol} size={32} />
                <div className="flex-1 min-w-0">
                  <div className="t-title-m text-arc-ink-900">{t.symbol}</div>
                  <div className="text-xs text-arc-ink-500 truncate">{t.name}</div>
                </div>
                {bal != null ? (
                  <div className="text-right">
                    <div className="t-mono text-sm text-arc-ink-900">
                      {fmtUnits(bal, t.decimals, 4)}
                    </div>
                    <div className="t-label text-[10px] m-0">balance</div>
                  </div>
                ) : null}
              </button>
            );
          })
        )}
      </div>
    </Modal>
  );
}
