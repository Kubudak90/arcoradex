import { describe, expect, it } from "vitest";
import { http } from "viem";
import { createArcoraDexV2 } from "../../../src/clientV2";
import { baseSepolia } from "../../../src/chains/baseSepolia";
import { arcTestnet } from "../../../src/chains/arcTestnet";
import { DEFAULT_ADDRESSES_V2 } from "../../../src/addresses.v2";

describe("createArcoraDexV2", () => {
  it("resolves DEFAULT_ADDRESSES_V2 for baseSepolia and exposes the V2 surface", () => {
    const sdk = createArcoraDexV2({ chain: baseSepolia, transport: http() });
    expect(sdk.addresses).toEqual(DEFAULT_ADDRESSES_V2[baseSepolia.id]);
    for (const fn of [
      "reserveHealth", "maxSwapOut", "maxWithdraw", "quoteSwapV2", "quoteWithdrawV2",
      "swap", "deposit", "withdrawSingle", "withdrawProportional",
      "getTokens", "getPoolStats",
    ] as const) {
      expect(typeof sdk[fn]).toBe("function");
    }
  });

  it("resolves DEFAULT_ADDRESSES_V2 for arcTestnet (the second live V2 chain)", () => {
    const sdk = createArcoraDexV2({ chain: arcTestnet, transport: http() });
    expect(sdk.addresses).toEqual(DEFAULT_ADDRESSES_V2[arcTestnet.id]);
    expect(sdk.chain.id).toBe(5042002);
    // Distinct addresses from the Base map — proves the per-chain resolution.
    expect(sdk.addresses.pool).not.toBe(DEFAULT_ADDRESSES_V2[baseSepolia.id]!.pool);
  });

  it("throws for an unmapped chain unless addresses are passed", () => {
    // Use a chain id that is in NEITHER V2 map.
    expect(() => createArcoraDexV2({ chain: { ...baseSepolia, id: 99999999 }, transport: http() }))
      .toThrow(/No default ArcoraDexAddresses/);
  });
});
