import { describe, expect, it } from "vitest";
import { DEFAULT_ADDRESSES } from "../../src/addresses";
import { arcTestnet } from "../../src/chains/arcTestnet";

describe("DEFAULT_ADDRESSES", () => {
  it("points arcTestnet at the live V3 deployment", () => {
    const a = DEFAULT_ADDRESSES[arcTestnet.id]!;
    // Live public-testnet V3 addresses from the 2026-06-10 FRESH redeploy
    // (Branch C lost-key recovery, chainId 5042002). Their liveness is asserted
    // on-chain by test/integration/addresses-live.test.ts (pool unpaused,
    // registry lists 7 tokens). Compare raw literals against the canonical
    // EIP-55 checksummed form, so a future regression to lowercase (or any
    // other casing) fails this test rather than being silently normalised away.
    expect(a.pool).toBe("0x214825E3e24a07cd58e48267e492320dAccCe2f6");
    expect(a.registry).toBe("0x372f83a1432Aa43b72eDCE083DC8352d9Bfb47f1");
    expect(a.lp).toBe("0xc07e979B5Ee023Ad96E65E733b99902306CAFEf2");
  });
});
