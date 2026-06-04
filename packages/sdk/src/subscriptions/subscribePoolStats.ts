import type { ArcoraDexClient } from "../client";
import type { PoolStats } from "../types";
import { getPoolStats } from "../actions/getPoolStats";
import type { Unsubscribe } from "./subscribeSwaps";

export interface SubscribePoolStatsOptions {
  /**
   * Optional error sink. A per-block getPoolStats() refresh that fails (RPC
   * hiccup, transient revert) reports here instead of being silently swallowed.
   * Backward compatible — when omitted, the handler simply retains its last
   * good value as before. The subscription keeps polling either way.
   */
  onError?: (error: Error) => void;
}

export function subscribePoolStats(
  client: ArcoraDexClient,
  handler: (s: PoolStats) => void,
  options?: SubscribePoolStatsOptions,
): Unsubscribe {
  return client.publicClient.watchBlockNumber({
    onBlockNumber: async () => {
      try {
        const stats = await getPoolStats(client);
        handler(stats);
      } catch (e) {
        // Don't tear down the subscription on a transient failure; surface it
        // to onError (if provided) so callers can observe instead of guessing.
        options?.onError?.(e instanceof Error ? e : new Error(String(e)));
      }
    },
    // watchBlockNumber's own polling errors also route to onError.
    onError: options?.onError,
  });
}
