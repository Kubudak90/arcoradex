import type { ReadClientV2 } from "./_readClient";
import type { MaxSwapOut } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { parseContractErrorV2 } from "../../errors.v2";

export async function maxSwapOut(
  client: ReadClientV2,
  tokenOut: `0x${string}`,
): Promise<MaxSwapOut> {
  try {
    const [netOut, grossUsd1e18] = await client.publicClient.readContract({
      address: client.addresses.pool,
      abi: poolAbiV2,
      functionName: "maxSwapOut",
      args: [tokenOut],
    });
    return { netOut, grossUsd1e18 };
  } catch (e) {
    throw parseContractErrorV2(e);
  }
}
