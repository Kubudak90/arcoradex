import type { ArcoraDexClient } from "../client";
import type { UserPosition } from "../types";
import { lpAbi } from "../abi/lp";
import { poolAbi } from "../abi/pool";

export async function getPosition(
  client: ArcoraDexClient,
  addr: `0x${string}`,
): Promise<UserPosition> {
  const [lpBalance, lpSupply, navUsd1e18] = await Promise.all([
    client.publicClient.readContract({ address: client.addresses.lp, abi: lpAbi, functionName: "balanceOf", args: [addr] }),
    client.publicClient.readContract({ address: client.addresses.lp, abi: lpAbi, functionName: "totalSupply" }),
    client.publicClient.readContract({ address: client.addresses.pool, abi: poolAbi, functionName: "totalReservesUSD" }),
  ]);
  const usdValue1e18 = lpSupply > 0n ? (lpBalance * navUsd1e18) / lpSupply : 0n;
  const sharePct = lpSupply > 0n ? Number((lpBalance * 1_000_000n) / lpSupply) / 1_000_000 : 0;
  return { lpBalance, usdValue1e18, sharePct };
}
