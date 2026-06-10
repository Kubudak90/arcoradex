import { describe, expect, it } from "vitest";
import { isAddress } from "viem";
import { DEFAULT_ADDRESSES_V2 } from "../../../src/addresses.v2";
import { baseSepolia } from "../../../src/chains/baseSepolia";
import { arcTestnet } from "../../../src/chains/arcTestnet";

describe("DEFAULT_ADDRESSES_V2", () => {
  it("points baseSepolia at the live V2 deployment (checksummed literals)", () => {
    const a = DEFAULT_ADDRESSES_V2[baseSepolia.id]!;
    expect(a.pool).toBe("0x63FD6180dC6Aa5aE2941Bd28D2dc34c54F2b7820");
    expect(a.registry).toBe("0xae1f10b007cDC4131797A45232a3D52Ff2C314e2");
    expect(a.lp).toBe("0x02aFC4c2c72ecE2049725DA2bd9080EF6285c844");
  });

  it("points arcTestnet at the live V2 deployment (checksummed literals)", () => {
    const a = DEFAULT_ADDRESSES_V2[arcTestnet.id]!;
    expect(a.pool).toBe("0x9191B2c7ac888F2840a99bb1Bf154b8B38716312");
    expect(a.registry).toBe("0x1beBA5b2F374F9e5C8b47439CB743442f1408536");
    expect(a.lp).toBe("0x332e977aA9707eC3a0125B22c97Bc0c464658150");
  });

  it("resolves both V2 chains (84532 + 5042002) and each is EIP-55 valid", () => {
    for (const id of [baseSepolia.id, arcTestnet.id]) {
      const a = DEFAULT_ADDRESSES_V2[id]!;
      expect(a).toBeDefined();
      for (const addr of [a.pool, a.registry, a.lp]) {
        expect(isAddress(addr, { strict: true })).toBe(true);
      }
    }
  });

  it("does not collide cross-chain: no address is shared between the two V2 maps", () => {
    const base = DEFAULT_ADDRESSES_V2[baseSepolia.id]!;
    const arc = DEFAULT_ADDRESSES_V2[arcTestnet.id]!;
    const baseSet = new Set([base.pool, base.registry, base.lp].map((a) => a.toLowerCase()));
    for (const addr of [arc.pool, arc.registry, arc.lp]) {
      expect(baseSet.has(addr.toLowerCase())).toBe(false);
    }
  });

  it("does not collide with the V1 Arc map (separate object)", async () => {
    const { DEFAULT_ADDRESSES } = await import("../../../src/addresses");
    expect(DEFAULT_ADDRESSES_V2[baseSepolia.id]).toBeDefined();
    // 84532 is absent from the V1 map; the V1 Arc-V1 pool address differs from
    // the V2 Arc pool address even though both share chainId 5042002.
    expect(DEFAULT_ADDRESSES[baseSepolia.id]).toBeUndefined();
    expect(DEFAULT_ADDRESSES[arcTestnet.id]!.pool).not.toBe(
      DEFAULT_ADDRESSES_V2[arcTestnet.id]!.pool,
    );
  });
});
