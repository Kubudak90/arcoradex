import type { ReadClientV2 } from "./_readClient";
import type { MaxWithdraw } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { parseContractErrorV2 } from "../../errors.v2";

export async function maxWithdraw(
  client: ReadClientV2,
  tokenOut: `0x${string}`,
  account: `0x${string}`,
): Promise<MaxWithdraw> {
  try {
    const [lpAmount, netOut] = await client.publicClient.readContract({
      address: client.addresses.pool,
      abi: poolAbiV2,
      functionName: "maxWithdraw",
      args: [tokenOut, account],
    });
    return { lpAmount, netOut };
  } catch (e) {
    throw parseContractErrorV2(e);
  }
}
