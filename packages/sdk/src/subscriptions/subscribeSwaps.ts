import type { ArcoraDexClient } from "../client";
import type { SwappedEvent } from "../types";
import { poolAbi } from "../abi/pool";

export type Unsubscribe = () => void;

export interface SubscribeOptions {
  fromBlock?: bigint;
  pollingInterval?: number;
  /**
   * Optional error sink. viem's watcher surfaces RPC/decoding failures here
   * instead of throwing; without this they were silently swallowed. Backward
   * compatible — omit it to keep the prior fire-and-forget behaviour.
   */
  onError?: (error: Error) => void;
}

export function subscribeSwaps(
  client: ArcoraDexClient,
  handler: (e: SwappedEvent) => void,
  options?: SubscribeOptions,
): Unsubscribe {
  // Dedupe + reorg handling. watchContractEvent can re-deliver the same log
  // (polling overlap) and, on a chain reorg, deliver the previously-emitted log
  // again with `removed: true`. We key by (transactionHash, logIndex):
  //   - removed log  → drop it AND forget the key, so if the tx is re-included
  //                     in the canonical chain its fresh log fires once more.
  //   - already seen → skip (idempotent delivery).
  //   - new          → record the key and invoke the handler exactly once.
  const seen = new Set<string>();
  const keyOf = (txHash: string, logIndex: number) => `${txHash}:${logIndex}`;

  return client.publicClient.watchContractEvent({
    address: client.addresses.pool,
    abi: poolAbi,
    eventName: "Swapped",
    fromBlock: options?.fromBlock,
    pollingInterval: options?.pollingInterval,
    onError: options?.onError,
    onLogs: (logs) => {
      for (const log of logs) {
        const a = log.args;
        if (!a.user || !a.tokenIn || !a.tokenOut) continue;
        if (log.transactionHash == null || log.logIndex == null) continue;

        const key = keyOf(log.transactionHash, log.logIndex);
        if (log.removed) {
          // Reorg rollback: undeliver by clearing the key so re-inclusion fires.
          seen.delete(key);
          continue;
        }
        if (seen.has(key)) continue;
        seen.add(key);

        handler({
          user: a.user,
          tokenIn: a.tokenIn,
          tokenOut: a.tokenOut,
          amountIn: a.amountIn!,
          amountOut: a.amountOut!,
          lpFeeUsd1e18: a.lpFeeUsd1e18!,
          protocolFeeAmtOut: a.protocolFeeAmtOut!,
          recipient: a.recipient!,
          blockNumber: log.blockNumber!,
          txHash: log.transactionHash,
          logIndex: log.logIndex,
        });
      }
    },
  });
}
