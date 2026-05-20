import { describe, expect, it } from "vitest";
import { DEFAULT_ADDRESSES } from "../../src/addresses";
import { arcTestnet } from "../../src/chains/arcTestnet";

describe("DEFAULT_ADDRESSES", () => {
  it("points arcTestnet at the live V3 deployment", () => {
    const a = DEFAULT_ADDRESSES[arcTestnet.id]!;
    // V3 addresses recorded in docs/rollouts/2026-05-14-phase3-oracle.md and
    // verified on-chain (V3 pool unpaused; V1 pool paused) on 2026-05-20.
    // Compare raw literals against the canonical EIP-55 checksummed form, so a
    // future regression to lowercase (or any other casing) fails this test
    // rather than being silently normalised away.
    expect(a.pool).toBe("0x1ce1Ef94e7ebe70727BD69003d61A3F0c9A331bc");
    expect(a.registry).toBe("0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB");
    expect(a.lp).toBe("0x17B47173C457069E53B3B75Ef42773041B79523e");
  });
});
