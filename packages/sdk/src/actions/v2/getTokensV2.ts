import type { ReadClientV2 } from "./_readClient";
import type { TokenInfoV2 } from "../../types.v2";
import { registryAbiV2 } from "../../abi/v2/registry";
import { erc20Abi } from "../../abi/erc20";
import { KNOWN_TOKENS_V2 } from "../../tokens/known.v2";
import { getAddress } from "viem";

export async function getTokensV2(
  client: ReadClientV2,
  args?: { activeOnly?: boolean },
): Promise<TokenInfoV2[]> {
  const registry = client.addresses.registry;
  const n = Number(
    await client.publicClient.readContract({
      address: registry,
      abi: registryAbiV2,
      functionName: "tokensLength",
    }),
  );
  if (n === 0) return [];

  const addresses = await Promise.all(
    Array.from({ length: n }, (_, i) =>
      client.publicClient.readContract({
        address: registry,
        abi: registryAbiV2,
        functionName: "tokens",
        args: [BigInt(i)],
      }),
    ),
  );

  const configs = await Promise.all(
    addresses.map((a) =>
      client.publicClient.readContract({
        address: registry,
        abi: registryAbiV2,
        functionName: "tokenConfig",
        args: [a],
      }),
    ),
  );

  const labels = await Promise.all(
    addresses.map(async (a) => {
      let key: `0x${string}`;
      try {
        key = getAddress(a);
      } catch {
        key = a;
      }
      const known = KNOWN_TOKENS_V2[key];
      if (known) return known;
      const [symbol, name] = await Promise.all([
        client.publicClient.readContract({ address: a, abi: erc20Abi, functionName: "symbol" }),
        client.publicClient.readContract({ address: a, abi: erc20Abi, functionName: "name" }),
      ]);
      return { symbol, name };
    }),
  );

  const tokens: TokenInfoV2[] = addresses.map((address, i) => {
    const c = configs[i]!;
    const m = labels[i]!;
    return {
      address,
      symbol: m.symbol,
      name: m.name,
      decimals: Number(c.decimals),
      isActive: c.isActive,
      adapter: c.adapter,
      minimumReserveUsd: c.minimumReserveUsd,
      targetReserveUsd: c.targetReserveUsd,
      depositCapUsd: c.depositCapUsd,
      bands: c.bands.map((b) => ({ upperHealthBps: Number(b.upperHealthBps), rateBps: Number(b.rateBps) })),
    };
  });

  return args?.activeOnly ? tokens.filter((t) => t.isActive) : tokens;
}
