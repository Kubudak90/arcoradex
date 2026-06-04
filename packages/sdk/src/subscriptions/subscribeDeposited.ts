import type { ArcoraDexClient } from "../client";
import type { DepositedEvent } from "../types";
import { poolAbi } from "../abi/pool";
import type { Unsubscribe, SubscribeOptions } from "./subscribeSwaps";

export function subscribeDeposited(
  client: ArcoraDexClient,
  handler: (e: DepositedEvent) => void,
  options?: SubscribeOptions,
): Unsubscribe {
  // (transactionHash, logIndex) dedupe + reorg handling — see subscribeSwaps.
  const seen = new Set<string>();

  return client.publicClient.watchContractEvent({
    address: client.addresses.pool,
    abi: poolAbi,
    eventName: "Deposited",
    fromBlock: options?.fromBlock,
    pollingInterval: options?.pollingInterval,
    onError: options?.onError,
    onLogs: (logs) => {
      for (const log of logs) {
        const a = log.args;
        if (!a.user || !a.token) continue;
        if (log.transactionHash == null || log.logIndex == null) continue;

        const key = `${log.transactionHash}:${log.logIndex}`;
        if (log.removed) {
          seen.delete(key);
          continue;
        }
        if (seen.has(key)) continue;
        seen.add(key);

        handler({
          user: a.user,
          token: a.token,
          amountIn: a.amountIn!,
          lpMinted: a.lpMinted!,
          navBefore1e18: a.navBefore1e18!,
          navAfter1e18: a.navAfter1e18!,
          blockNumber: log.blockNumber!,
          txHash: log.transactionHash,
          logIndex: log.logIndex,
        });
      }
    },
  });
}
