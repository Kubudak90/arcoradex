import type { ArcoraDexClient } from "../client";
import type { SwappedEvent } from "../types";
import { poolAbi } from "../abi/pool";

export type Unsubscribe = () => void;

export function subscribeSwaps(
  client: ArcoraDexClient,
  handler: (e: SwappedEvent) => void,
  options?: { fromBlock?: bigint; pollingInterval?: number },
): Unsubscribe {
  return client.publicClient.watchContractEvent({
    address: client.addresses.pool,
    abi: poolAbi,
    eventName: "Swapped",
    fromBlock: options?.fromBlock,
    pollingInterval: options?.pollingInterval,
    onLogs: (logs) => {
      for (const log of logs) {
        const a = log.args;
        if (!a.user || !a.tokenIn || !a.tokenOut) continue;
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
          txHash: log.transactionHash!,
          logIndex: log.logIndex!,
        });
      }
    },
  });
}
