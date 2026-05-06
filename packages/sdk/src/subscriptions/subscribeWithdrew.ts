import type { ArcoraDexClient } from "../client";
import type { WithdrewEvent } from "../types";
import { poolAbi } from "../abi/pool";
import type { Unsubscribe } from "./subscribeSwaps";

export function subscribeWithdrew(
  client: ArcoraDexClient,
  handler: (e: WithdrewEvent) => void,
  options?: { fromBlock?: bigint; pollingInterval?: number },
): Unsubscribe {
  return client.publicClient.watchContractEvent({
    address: client.addresses.pool,
    abi: poolAbi,
    eventName: "Withdrew",
    fromBlock: options?.fromBlock,
    pollingInterval: options?.pollingInterval,
    onLogs: (logs) => {
      for (const log of logs) {
        const a = log.args;
        if (!a.user || !a.tokenOut) continue;
        handler({
          user: a.user,
          tokenOut: a.tokenOut,
          lpBurned: a.lpBurned!,
          amountOut: a.amountOut!,
          protocolFee: a.protocolFee!,
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
