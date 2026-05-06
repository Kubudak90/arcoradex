"use client";
import { useEffect, useState } from "react";
import { usePublicClient } from "wagmi";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { poolAbi } from "@/lib/abi/pool";
import { POOL_ADDRESS, tokenLabel } from "@/lib/contracts";
import { fmtUnits } from "@/lib/format";
import { shortAddr } from "@/lib/utils";
import { parseAbiItem } from "viem";

const SCAN_BLOCKS = 50_000n;

interface Row {
  txHash: `0x${string}`;
  user: `0x${string}`;
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  amountIn: bigint;
  amountOut: bigint;
  blockNumber: bigint;
}

export function SwapHistory() {
  const client = usePublicClient();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!client) return;
    let cancelled = false;
    (async () => {
      try {
        const head = await client.getBlockNumber();
        const fromBlock = head > SCAN_BLOCKS ? head - SCAN_BLOCKS : 0n;
        const logs = await client.getLogs({
          address: POOL_ADDRESS,
          event: parseAbiItem(
            "event Swapped(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 lpFeeUsd1e18, uint256 protocolFeeAmtOut, address recipient)"
          ),
          fromBlock,
          toBlock: head,
        });
        if (cancelled) return;
        const out: Row[] = logs
          .map((l) => ({
            txHash: l.transactionHash!,
            user: l.args.user!,
            tokenIn: l.args.tokenIn!,
            tokenOut: l.args.tokenOut!,
            amountIn: l.args.amountIn!,
            amountOut: l.args.amountOut!,
            blockNumber: l.blockNumber!,
          }))
          .reverse()
          .slice(0, 30);
        setRows(out);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to load events");
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [client]);

  return (
    <Card>
      <CardHeader>
        <CardTitle>Recent swaps</CardTitle>
        <span className="text-xs text-fg-muted">last {SCAN_BLOCKS.toString()} blocks</span>
      </CardHeader>

      {error ? (
        <p className="text-sm text-danger">{error}</p>
      ) : rows == null ? (
        <p className="text-sm text-fg-muted">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-fg-muted">No swaps yet.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs uppercase text-fg-muted border-b border-border">
                <th className="pb-2">Trader</th>
                <th className="pb-2">In</th>
                <th className="pb-2">Out</th>
                <th className="pb-2 text-right">Tx</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const tIn = tokenLabel(r.tokenIn);
                const tOut = tokenLabel(r.tokenOut);
                return (
                  <tr key={r.txHash} className="border-b border-border last:border-0">
                    <td className="py-2 font-mono text-xs">{shortAddr(r.user)}</td>
                    <td className="py-2">
                      {fmtUnits(r.amountIn, 18, 4)} {tIn.symbol}
                    </td>
                    <td className="py-2">
                      {fmtUnits(r.amountOut, 18, 4)} {tOut.symbol}
                    </td>
                    <td className="py-2 text-right">
                      <a
                        href={`${process.env.NEXT_PUBLIC_BLOCK_EXPLORER || "https://testnet.arcscan.app"}/tx/${r.txHash}`}
                        target="_blank"
                        rel="noreferrer"
                        className="text-arcora-blue-500 hover:underline font-mono text-xs"
                      >
                        {r.txHash.slice(0, 10)}…
                      </a>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}
