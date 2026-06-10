import { describe, expect, it } from "vitest";
import { DEFAULT_ADDRESSES_V2 } from "../../../src/addresses.v2";
import { baseSepolia } from "../../../src/chains/baseSepolia";

describe("DEFAULT_ADDRESSES_V2", () => {
  it("points baseSepolia at the live V2 deployment (checksummed literals)", () => {
    const a = DEFAULT_ADDRESSES_V2[baseSepolia.id]!;
    expect(a.pool).toBe("0x63FD6180dC6Aa5aE2941Bd28D2dc34c54F2b7820");
    expect(a.registry).toBe("0xae1f10b007cDC4131797A45232a3D52Ff2C314e2");
    expect(a.lp).toBe("0x02aFC4c2c72ecE2049725DA2bd9080EF6285c844");
  });

  it("does not collide with the V1 Arc map (separate object)", async () => {
    const { DEFAULT_ADDRESSES } = await import("../../../src/addresses");
    expect(DEFAULT_ADDRESSES_V2[baseSepolia.id]).toBeDefined();
    // 84532 is absent from the V1 map; 5042002 is absent from the V2 map.
    expect(DEFAULT_ADDRESSES[baseSepolia.id]).toBeUndefined();
    expect(DEFAULT_ADDRESSES_V2[5042002]).toBeUndefined();
  });
});
