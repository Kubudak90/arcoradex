import { describe, expect, it } from "vitest";
import { DEFAULT_ADDRESSES } from "../../src/addresses";
import { arcTestnet } from "../../src/chains/arcTestnet";

describe("DEFAULT_ADDRESSES", () => {
  it("points arcTestnet at the live V3 deployment", () => {
    const a = DEFAULT_ADDRESSES[arcTestnet.id]!;
    // Live public-testnet V3 addresses from the 2026-06-06 deploy
    // (DeployPublicTestnet.s.sol, chainId 5042002). Their liveness is asserted
    // on-chain by test/integration/addresses-live.test.ts (pool unpaused,
    // registry lists 7 tokens). Compare raw literals against the canonical
    // EIP-55 checksummed form, so a future regression to lowercase (or any
    // other casing) fails this test rather than being silently normalised away.
    expect(a.pool).toBe("0x532505501B1D789A724E9341B95aD9037aA1a3bf");
    expect(a.registry).toBe("0xc6D0FB58Bf2d529021A4E679F36Fe31842A97c97");
    expect(a.lp).toBe("0x8C286D963030E5218d08E2cf83F40c624b561155");
  });
});
