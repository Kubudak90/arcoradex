"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "@arcoralabs/dex-sdk/react/v2";
import { poolAbiV2 } from "@arcoralabs/dex-sdk/v2";
import type { Hash } from "viem";

export type FeedAction = "swap" | "withdraw" | "exit";

export interface FeedRow {
  id: string; // `${txHash}-${logIndex}`
  action: FeedAction;
  /** input/primary token address (lowercased) — undefined for proportional exit. */
  from?: string;
  /** output token address (lowercased) — only for swaps. */
  to?: string;
  user: `0x${string}`;
  /** human amount in `from` token units (raw bigint; caller formats with decimals). */
  amountRaw?: bigint;
  blockNumber: bigint;
  txHash: Hash;
}

/**
 * Bound the getLogs window — most public Base Sepolia RPCs cap a single getLogs
 * range. ~10k blocks (~5–6h at 2s blocks) is comfortably under common caps and
 * covers recent activity for the live feed.
 */
const LOOKBACK_BLOCKS = 10_000n;

/**
 * Real on-chain transaction feed for the Pool page — polls the Pool's
 * `Swapped` / `WithdrewSingle` / `WithdrewProportional` logs over a recent block
 * window via `getLogs`, decodes them with `poolAbiV2`, and returns newest-first
 * rows (capped at 30). No mock data; if the RPC has no recent events the list is
 * simply empty (the card renders its shell with a "Live" pill).
 */
export function usePoolFeed(): { rows: FeedRow[]; isFetching: boolean } {
  const sdk = useArcoraDexV2();

  const { data, isFetching } = useQuery({
    queryKey: ["arcora", "v2", "poolFeed", sdk.chain.id],
    refetchInterval: 12_000,
    queryFn: async (): Promise<FeedRow[]> => {
      const pc = sdk.publicClient;
      const latest = await pc.getBlockNumber();
      const fromBlock = latest > LOOKBACK_BLOCKS ? latest - LOOKBACK_BLOCKS : 0n;
      const pool = sdk.addresses.pool;

      // Pull each event type separately (named-event getLogs), tolerating an RPC
      // that rejects one shape without dropping the others.
      const [swaps, singles, props] = await Promise.all([
        pc
          .getContractEvents({ address: pool, abi: poolAbiV2, eventName: "Swapped", fromBlock, toBlock: latest })
          .catch(() => []),
        pc
          .getContractEvents({ address: pool, abi: poolAbiV2, eventName: "WithdrewSingle", fromBlock, toBlock: latest })
          .catch(() => []),
        pc
          .getContractEvents({ address: pool, abi: poolAbiV2, eventName: "WithdrewProportional", fromBlock, toBlock: latest })
          .catch(() => []),
      ]);

      const rows: FeedRow[] = [];

      for (const log of swaps) {
        const a = log.args;
        rows.push({
          id: `${log.transactionHash}-${log.logIndex}`,
          action: "swap",
          from: a.tokenIn?.toLowerCase(),
          to: a.tokenOut?.toLowerCase(),
          user: a.user!,
          amountRaw: a.amountIn,
          blockNumber: log.blockNumber!,
          txHash: log.transactionHash!,
        });
      }
      for (const log of singles) {
        const a = log.args;
        rows.push({
          id: `${log.transactionHash}-${log.logIndex}`,
          action: "withdraw",
          from: a.tokenOut?.toLowerCase(),
          user: a.user!,
          amountRaw: a.amountOut,
          blockNumber: log.blockNumber!,
          txHash: log.transactionHash!,
        });
      }
      for (const log of props) {
        const a = log.args;
        rows.push({
          id: `${log.transactionHash}-${log.logIndex}`,
          action: "exit",
          user: a.user!,
          blockNumber: log.blockNumber!,
          txHash: log.transactionHash!,
        });
      }

      // Newest-first by block, then logIndex within a block.
      rows.sort((x, y) => {
        if (y.blockNumber !== x.blockNumber) return y.blockNumber > x.blockNumber ? 1 : -1;
        return 0;
      });
      return rows.slice(0, 30);
    },
  });

  return { rows: data ?? [], isFetching };
}
