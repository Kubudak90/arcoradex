import type { ArcoraDexClient } from "../client";
import { poolAbi } from "../abi/pool";

export async function quoteWithdraw(
  client: ArcoraDexClient,
  args: { tokenOut: `0x${string}`; lpAmount: bigint },
): Promise<{ amountOut: bigint; protocolFee: bigint }> {
  const result = await client.publicClient.readContract({
    address: client.addresses.pool,
    abi: poolAbi,
    functionName: "quoteWithdraw",
    args: [args.tokenOut, args.lpAmount],
  });
  return { amountOut: result[0], protocolFee: result[1] };
}
