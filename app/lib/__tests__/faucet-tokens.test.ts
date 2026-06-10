import { isAddress } from "viem";
import { describe, expect, it } from "vitest";
import { FAUCET_TOKENS } from "../faucet-tokens";

describe("FAUCET_TOKENS", () => {
  it("lists exactly 3 stables (matching the live V2 Registry token count)", () => {
    expect(FAUCET_TOKENS).toHaveLength(3);
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

  it("addresses match the live Base Sepolia (84532) V2 token set", () => {
    const bySymbol = Object.fromEntries(FAUCET_TOKENS.map((t) => [t.symbol, t.address]));
    expect(bySymbol).toEqual({
      USDC: "0x3a98d8adC295d90171e9DA93D411dEa95674c867",
      USDT: "0x7110315D229C7CE655399703ACbA8E67f1d5C0c0",
      EURC: "0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7",
    });
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

  it("USDC/USDT mint ≈ $1000 (pegged USD ⇒ 1000 units)", () => {
    const pegged = FAUCET_TOKENS.filter((t) => ["USDC", "USDT"].includes(t.symbol));
    expect(pegged).toHaveLength(2);
    for (const t of pegged) {
      expect(t.amount).toBe(1_000n);
    }
  });
});
