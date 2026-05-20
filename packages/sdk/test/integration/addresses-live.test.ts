import { describe, expect, it } from "vitest";
import { createPublicClient, http, parseAbi } from "viem";
import { DEFAULT_ADDRESSES } from "../../src/addresses";
import { arcTestnet } from "../../src/chains/arcTestnet";

const POOL_ABI = parseAbi([
  "function paused() view returns (bool)",
]);

const REGISTRY_ABI = parseAbi([
  "function tokensLength() view returns (uint256)",
]);

describe.skipIf(process.env.SKIP_LIVE_TESTS === "1")("V3 defaults are live", () => {
  it("pool is unpaused and registry lists 7 tokens", async () => {
    const client = createPublicClient({ chain: arcTestnet, transport: http() });
    const { pool, registry } = DEFAULT_ADDRESSES[arcTestnet.id]!;
    const [paused, len] = await Promise.all([
      client.readContract({ address: pool,     abi: POOL_ABI,     functionName: "paused" }),
      client.readContract({ address: registry, abi: REGISTRY_ABI, functionName: "tokensLength" }),
    ]);
    expect(paused).toBe(false);
    expect(Number(len)).toBe(7);
  }, 30_000);
});
