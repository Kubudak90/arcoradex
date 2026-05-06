import type { ArcoraDexClient } from "../client";
import { poolAbi } from "../abi/pool";

export async function quoteSwap(
  client: ArcoraDexClient,
  args: { tokenIn: `0x${string}`; tokenOut: `0x${string}`; amountIn: bigint },
): Promise<bigint> {
  return client.publicClient.readContract({
    address: client.addresses.pool,
    abi: poolAbi,
    functionName: "quote",
    args: [args.tokenIn, args.tokenOut, args.amountIn],
  });
}
