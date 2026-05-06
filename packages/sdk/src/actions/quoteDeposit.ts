import type { ArcoraDexClient } from "../client";
import { poolAbi } from "../abi/pool";

export async function quoteDeposit(
  client: ArcoraDexClient,
  args: { token: `0x${string}`; amount: bigint },
): Promise<bigint> {
  return client.publicClient.readContract({
    address: client.addresses.pool,
    abi: poolAbi,
    functionName: "quoteDeposit",
    args: [args.token, args.amount],
  });
}
