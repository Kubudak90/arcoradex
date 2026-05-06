import type { ArcoraDexClient } from "../client";
import type { PoolStats } from "../types";
import { poolAbi } from "../abi/pool";
import { lpAbi } from "../abi/lp";

export async function getPoolStats(client: ArcoraDexClient): Promise<PoolStats> {
  const pool = client.addresses.pool;
  const lp = client.addresses.lp;
  const [navUsd1e18, lpSupply, swapFeeBps, protocolFeeShareBps, paused] = await Promise.all([
    client.publicClient.readContract({ address: pool, abi: poolAbi, functionName: "totalReservesUSD" }),
    client.publicClient.readContract({ address: lp, abi: lpAbi, functionName: "totalSupply" }),
    client.publicClient.readContract({ address: pool, abi: poolAbi, functionName: "swapFeeBps" }),
    client.publicClient.readContract({ address: pool, abi: poolAbi, functionName: "protocolFeeShareBps" }),
    client.publicClient.readContract({ address: pool, abi: poolAbi, functionName: "paused" }),
  ]);
  const lpPriceUsd1e18 = lpSupply > 0n ? (navUsd1e18 * 10n ** 18n) / lpSupply : 0n;
  return { navUsd1e18, lpSupply, lpPriceUsd1e18, swapFeeBps, protocolFeeShareBps, paused };
}
