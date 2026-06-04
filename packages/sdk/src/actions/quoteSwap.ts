import type { ArcoraDexClient } from "../client";
import { poolAbi } from "../abi/pool";
import { parseContractError } from "../errors";

export async function quoteSwap(
  client: ArcoraDexClient,
  args: { tokenIn: `0x${string}`; tokenOut: `0x${string}`; amountIn: bigint },
): Promise<bigint> {
  // L-1 (audit 2026-05-31): route on-chain quote reverts through
  // parseContractError so a reverting quote throws a typed ArcoraDexError
  // (e.g. SameTokenError / TokenNotActiveError / OracleStaleError) instead of a
  // raw viem ContractFunctionExecutionError.
  try {
    return await client.publicClient.readContract({
      address: client.addresses.pool,
      abi: poolAbi,
      functionName: "quote",
      args: [args.tokenIn, args.tokenOut, args.amountIn],
    });
  } catch (e) {
    throw parseContractError(e);
  }
}
