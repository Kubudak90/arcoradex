import type { ArcoraDexClient } from "../client";
import { poolAbi } from "../abi/pool";

export async function getProtocolFees(
  client: ArcoraDexClient,
  token: `0x${string}`,
): Promise<bigint> {
  return client.publicClient.readContract({
    address: client.addresses.pool,
    abi: poolAbi,
    functionName: "protocolFeesAccrued",
    args: [token],
  });
}
