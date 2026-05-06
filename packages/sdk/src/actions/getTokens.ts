import type { ArcoraDexClient } from "../client";
import type { TokenInfo } from "../types";
import { registryAbi } from "../abi/registry";
import { erc20Abi } from "../abi/erc20";
import { KNOWN_TOKENS } from "../tokens/known";
import { getAddress } from "viem";

export async function getTokens(
  client: ArcoraDexClient,
  args?: { activeOnly?: boolean },
): Promise<TokenInfo[]> {
  const registry = client.addresses.registry;
  const length = await client.publicClient.readContract({
    address: registry,
    abi: registryAbi,
    functionName: "tokensLength",
  });
  const n = Number(length);
  if (n === 0) return [];

  const addresses = await Promise.all(
    Array.from({ length: n }, (_, i) =>
      client.publicClient.readContract({
        address: registry,
        abi: registryAbi,
        functionName: "tokens",
        args: [BigInt(i)],
      }),
    ),
  );

  const infos = await Promise.all(
    addresses.map((a) =>
      client.publicClient.readContract({
        address: registry,
        abi: registryAbi,
        functionName: "tokenInfo",
        args: [a],
      }),
    ),
  );

  // Symbol/name: prefer the static KNOWN_TOKENS map (canonical labels for
  // chain-agnostic usage); fall back to an on-chain ERC20 read so freshly
  // deployed local/test tokens still get human labels.
  const labels = await Promise.all(
    addresses.map(async (a) => {
      let key: `0x${string}`;
      try {
        key = getAddress(a);
      } catch {
        key = a;
      }
      const known = KNOWN_TOKENS[key];
      if (known) return known;
      const [symbol, name] = await Promise.all([
        client.publicClient.readContract({ address: a, abi: erc20Abi, functionName: "symbol" }),
        client.publicClient.readContract({ address: a, abi: erc20Abi, functionName: "name" }),
      ]);
      return { symbol, name };
    }),
  );

  const tokens: TokenInfo[] = addresses.map((address, i) => {
    const raw = infos[i]!;
    const meta = labels[i]!;
    return {
      address,
      symbol: meta.symbol,
      name: meta.name,
      decimals: Number(raw.decimals),
      isActive: raw.isActive,
      oracle: raw.usdOracle,
      maxOracleDeviationBps: Number(raw.maxOracleDeviationBps),
    };
  });

  return args?.activeOnly ? tokens.filter((t) => t.isActive) : tokens;
}
