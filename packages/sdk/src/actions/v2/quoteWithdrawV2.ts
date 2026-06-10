import type { ReadClientV2 } from "./_readClient";
import type { QuoteV2 } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { parseContractErrorV2 } from "../../errors.v2";

export async function quoteWithdrawV2(
  client: ReadClientV2,
  args: { tokenOut: `0x${string}`; lpAmount: bigint },
): Promise<QuoteV2> {
  try {
    const [amountOut, protocolFee, feeUsd1e18, postHealthBps] =
      await client.publicClient.readContract({
        address: client.addresses.pool,
        abi: poolAbiV2,
        functionName: "quoteWithdrawV2",
        args: [args.tokenOut, args.lpAmount],
      });
    return { amountOut, protocolFee, feeUsd1e18, postHealthBps: Number(postHealthBps) };
  } catch (e) {
    throw parseContractErrorV2(e);
  }
}
