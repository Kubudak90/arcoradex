"use client";
import { useEffect, useRef, useState } from "react";
import { usePublicClient } from "wagmi";
import { parseAbiItem } from "viem";
import { useArcoraDex } from "./useArcoraDex";
import type { SwappedEvent } from "../types";

export interface UseSwapHistoryOptions {
  limit?: number;
  watch?: boolean;
  /** Block to start scanning from. Default: head − blockRange (~9000 blocks back),
      so rate-limited RPCs (like Arc testnet's 10k getLogs cap) don't reject. */
  fromBlock?: bigint;
  /** When fromBlock is unset, scan this many blocks back from head. Default 9000. */
  blockRange?: bigint;
  /** Optional polling interval (ms) for the watch path. Useful for tests. */
  pollingInterval?: number;
}

export interface UseSwapHistoryResult {
  events: SwappedEvent[];
  isLoading: boolean;
  error: Error | null;
}

const SWAPPED_EVENT = parseAbiItem(
  "event Swapped(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 lpFeeUsd1e18, uint256 protocolFeeAmtOut, address recipient)",
);

export function useSwapHistory(options?: UseSwapHistoryOptions): UseSwapHistoryResult {
  const sdk = useArcoraDex();
  // Cast: wagmi's `Register` narrows `chainId` in consumer apps; SDK is chain-agnostic.
  const publicClient = usePublicClient({ chainId: sdk.chain.id as never });
  const limit = options?.limit ?? 50;
  const watch = options?.watch ?? true;
  const fromBlock = options?.fromBlock;
  const blockRange = options?.blockRange ?? 9000n;
  const pollingInterval = options?.pollingInterval;

  const [events, setEvents] = useState<SwappedEvent[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);
  const seenKeys = useRef<Set<string>>(new Set());

  // Initial historical load.
  useEffect(() => {
    if (!publicClient) return;
    let cancelled = false;
    (async () => {
      try {
        setIsLoading(true);
        let effectiveFromBlock = fromBlock;
        if (effectiveFromBlock === undefined) {
          const head = await publicClient.getBlockNumber();
          effectiveFromBlock = head > blockRange ? head - blockRange : 0n;
        }
        const logs = await publicClient.getLogs({
          address: sdk.addresses.pool,
          event: SWAPPED_EVENT,
          fromBlock: effectiveFromBlock,
        });
        if (cancelled) return;
        const parsed: SwappedEvent[] = logs
          .filter((l) => l.args.user && l.args.tokenIn && l.args.tokenOut)
          .map((l) => ({
            user: l.args.user!,
            tokenIn: l.args.tokenIn!,
            tokenOut: l.args.tokenOut!,
            amountIn: l.args.amountIn!,
            amountOut: l.args.amountOut!,
            lpFeeUsd1e18: l.args.lpFeeUsd1e18!,
            protocolFeeAmtOut: l.args.protocolFeeAmtOut!,
            recipient: l.args.recipient!,
            blockNumber: l.blockNumber!,
            txHash: l.transactionHash!,
            logIndex: l.logIndex!,
          }))
          .reverse() // newest first
          .slice(0, limit);
        for (const e of parsed) seenKeys.current.add(`${e.txHash}-${e.logIndex}`);
        setEvents(parsed);
        setIsLoading(false);
      } catch (e) {
        if (!cancelled) {
          setError(e as Error);
          setIsLoading(false);
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [publicClient, sdk.addresses.pool, limit, fromBlock, blockRange]);

  // Watch for new events via the SDK subscription.
  useEffect(() => {
    if (!watch) return;
    const unsub = sdk.subscribeSwaps(
      (event) => {
        const key = `${event.txHash}-${event.logIndex}`;
        if (seenKeys.current.has(key)) return;
        seenKeys.current.add(key);
        setEvents((prev) => [event, ...prev].slice(0, limit));
      },
      pollingInterval !== undefined ? { pollingInterval } : undefined,
    );
    return unsub;
  }, [sdk, watch, limit, pollingInterval]);

  return { events, isLoading, error };
}
