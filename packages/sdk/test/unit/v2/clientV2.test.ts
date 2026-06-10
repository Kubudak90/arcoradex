import { describe, expect, it } from "vitest";
import { http } from "viem";
import { createArcoraDexV2 } from "../../../src/clientV2";
import { baseSepolia } from "../../../src/chains/baseSepolia";
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

  it("throws for an unmapped chain unless addresses are passed", () => {
    // Arc 5042002 is intentionally absent from the V2 map.
    expect(() => createArcoraDexV2({ chain: { ...baseSepolia, id: 5042002 }, transport: http() }))
      .toThrow(/No default ArcoraDexAddresses/);
  });
});
