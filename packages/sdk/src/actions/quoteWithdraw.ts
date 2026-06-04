import type { ArcoraDexClient } from "../client";
import { poolAbi } from "../abi/pool";
import { parseContractError } from "../errors";

export async function quoteWithdraw(
  client: ArcoraDexClient,
  args: { tokenOut: `0x${string}`; lpAmount: bigint },
): Promise<{ amountOut: bigint; protocolFee: bigint }> {
  // L-1 (audit 2026-05-31): typed error on quote revert (see quoteSwap.ts).
  try {
    const result = await client.publicClient.readContract({
      address: client.addresses.pool,
      abi: poolAbi,
      functionName: "quoteWithdraw",
      args: [args.tokenOut, args.lpAmount],
    });
    return { amountOut: result[0], protocolFee: result[1] };
  } catch (e) {
    throw parseContractError(e);
  }
}
