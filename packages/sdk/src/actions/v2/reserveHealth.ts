import type { ReadClientV2 } from "./_readClient";
import type { ReserveHealth } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { parseContractErrorV2 } from "../../errors.v2";

export async function reserveHealth(
  client: ReadClientV2,
  tokenOut: `0x${string}`,
): Promise<ReserveHealth> {
  try {
    const bps = await client.publicClient.readContract({
      address: client.addresses.pool,
      abi: poolAbiV2,
      functionName: "reserveHealth",
      args: [tokenOut],
    });
    return { healthBps: Number(bps) };
  } catch (e) {
    throw parseContractErrorV2(e);
  }
}
