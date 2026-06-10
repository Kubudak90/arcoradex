import type { ReadClientV2 } from "./_readClient";
import type { PoolStatsV2 } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { lpAbi } from "../../abi/lp";

export async function getPoolStatsV2(client: ReadClientV2): Promise<PoolStatsV2> {
  const pool = client.addresses.pool;
  const lp = client.addresses.lp;
  const [navUsd1e18, lpSupply, protocolFeeShareBps, paused] = await Promise.all([
    client.publicClient.readContract({ address: pool, abi: poolAbiV2, functionName: "totalReservesUSD" }),
    client.publicClient.readContract({ address: lp, abi: lpAbi, functionName: "totalSupply" }),
    client.publicClient.readContract({ address: pool, abi: poolAbiV2, functionName: "protocolFeeShareBps" }),
    client.publicClient.readContract({ address: pool, abi: poolAbiV2, functionName: "paused" }),
  ]);
  const lpPriceUsd1e18 = lpSupply === 0n ? 0n : (navUsd1e18 * 10n ** 18n) / lpSupply;
  return { navUsd1e18, lpSupply, lpPriceUsd1e18, protocolFeeShareBps: Number(protocolFeeShareBps), paused };
}
