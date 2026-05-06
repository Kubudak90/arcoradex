import type { ArcoraDexClient } from "../client";
import type { DepositedEvent } from "../types";
import { poolAbi } from "../abi/pool";
import type { Unsubscribe } from "./subscribeSwaps";

export function subscribeDeposited(
  client: ArcoraDexClient,
  handler: (e: DepositedEvent) => void,
  options?: { fromBlock?: bigint; pollingInterval?: number },
): Unsubscribe {
  return client.publicClient.watchContractEvent({
    address: client.addresses.pool,
    abi: poolAbi,
    eventName: "Deposited",
    fromBlock: options?.fromBlock,
    pollingInterval: options?.pollingInterval,
    onLogs: (logs) => {
      for (const log of logs) {
        const a = log.args;
        if (!a.user || !a.token) continue;
        handler({
          user: a.user,
          token: a.token,
          amountIn: a.amountIn!,
          lpMinted: a.lpMinted!,
          navBefore1e18: a.navBefore1e18!,
          navAfter1e18: a.navAfter1e18!,
          blockNumber: log.blockNumber!,
          txHash: log.transactionHash!,
          logIndex: log.logIndex!,
        });
      }
    },
  });
}
