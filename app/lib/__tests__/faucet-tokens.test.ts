import { isAddress } from "viem";
import { describe, expect, it } from "vitest";
import { FAUCET_TOKENS } from "../faucet-tokens";

describe("FAUCET_TOKENS", () => {
  it("lists exactly 7 stables (matching Registry token count)", () => {
    expect(FAUCET_TOKENS).toHaveLength(7);
  });

  it("symbols are unique", () => {
    const set = new Set(FAUCET_TOKENS.map((t) => t.symbol));
    expect(set.size).toBe(FAUCET_TOKENS.length);
  });

  it("addresses are unique and EIP-55 valid", () => {
    const addrs = FAUCET_TOKENS.map((t) => t.address);
    expect(new Set(addrs).size).toBe(addrs.length);
    for (const t of FAUCET_TOKENS) {
      expect(isAddress(t.address, { strict: true })).toBe(true);
    }
  });

  it("decimals are either 6 or 18 (matches deploy)", () => {
    for (const t of FAUCET_TOKENS) {
      expect([6, 18]).toContain(t.decimals);
    }
  });

  it("amounts are positive bigints", () => {
    for (const t of FAUCET_TOKENS) {
      expect(typeof t.amount).toBe("bigint");
      expect(t.amount).toBeGreaterThan(0n);
    }
  });

  it("USDC/USDT/PYUSD/DAI mint ≈ $1000 (pegged USD ⇒ 1000 units)", () => {
    const pegged = FAUCET_TOKENS.filter((t) => ["USDC", "USDT", "PYUSD", "DAI"].includes(t.symbol));
    expect(pegged).toHaveLength(4);
    for (const t of pegged) {
      expect(t.amount).toBe(1_000n);
    }
  });
});
