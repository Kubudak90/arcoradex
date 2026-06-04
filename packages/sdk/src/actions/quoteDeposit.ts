import type { ArcoraDexClient } from "../client";
import { poolAbi } from "../abi/pool";
import { parseContractError } from "../errors";

export async function quoteDeposit(
  client: ArcoraDexClient,
  args: { token: `0x${string}`; amount: bigint },
): Promise<bigint> {
  // L-1 (audit 2026-05-31): typed error on quote revert (see quoteSwap.ts).
  try {
    return await client.publicClient.readContract({
      address: client.addresses.pool,
      abi: poolAbi,
      functionName: "quoteDeposit",
      args: [args.token, args.amount],
    });
  } catch (e) {
    throw parseContractError(e);
  }
}
