import type { ArcoraDexClient } from "../client";
import { poolAbi } from "../abi/pool";
import { getTokens } from "./getTokens";

export async function getReserves(
  client: ArcoraDexClient,
): Promise<Record<`0x${string}`, bigint>> {
  const tokens = await getTokens(client);
  const reserves = await Promise.all(
    tokens.map((t) =>
      client.publicClient.readContract({
        address: client.addresses.pool,
        abi: poolAbi,
        functionName: "reserves",
        args: [t.address],
      }),
    ),
  );
  const out: Record<`0x${string}`, bigint> = {};
  tokens.forEach((t, i) => {
    out[t.address] = reserves[i]!;
  });
  return out;
}
