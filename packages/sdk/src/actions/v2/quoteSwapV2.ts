import type { ReadClientV2 } from "./_readClient";
import type { QuoteV2 } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { parseContractErrorV2 } from "../../errors.v2";

export async function quoteSwapV2(
  client: ReadClientV2,
  args: { tokenIn: `0x${string}`; tokenOut: `0x${string}`; amountIn: bigint },
): Promise<QuoteV2> {
  try {
    const [amountOut, protocolFee, feeUsd1e18, postHealthBps] =
      await client.publicClient.readContract({
        address: client.addresses.pool,
        abi: poolAbiV2,
        functionName: "quoteSwapV2",
        args: [args.tokenIn, args.tokenOut, args.amountIn],
      });
    return { amountOut, protocolFee, feeUsd1e18, postHealthBps: Number(postHealthBps) };
  } catch (e) {
    throw parseContractErrorV2(e);
  }
}
