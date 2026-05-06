import type { ArcoraDexClient } from "../client";
import type { PoolStats } from "../types";
import { getPoolStats } from "../actions/getPoolStats";
import type { Unsubscribe } from "./subscribeSwaps";

export function subscribePoolStats(
  client: ArcoraDexClient,
  handler: (s: PoolStats) => void,
): Unsubscribe {
  return client.publicClient.watchBlockNumber({
    onBlockNumber: async () => {
      try {
        const stats = await getPoolStats(client);
        handler(stats);
      } catch {
        // swallow; handler retains last good value
      }
    },
  });
}
