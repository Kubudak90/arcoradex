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

  it("addresses match the 2026-06-10 fresh Arc redeploy (Branch C)", () => {
    const bySymbol = Object.fromEntries(FAUCET_TOKENS.map((t) => [t.symbol, t.address]));
    expect(bySymbol).toEqual({
      USDC:  "0x200380a191FdB530C73120674EAF00E8417D168B",
      USDT:  "0xd93548768635d218478899448729eB9d6fCE9903",
      PYUSD: "0xd3fea5191fbD9e5B7492DE0e8289897514421407",
      DAI:   "0x89dD7f0D66e35F78794ee0215E380DD3269A2a0B",
      EURC:  "0xD4637b44879630dD0fE35FE86CC90EA192aeF008",
      TRYC:  "0x0dA050E630A1801421AdEf52351b1a1123b38265",
      BRLC:  "0x98422826dD9C22123991713810E1aC0B5d15179d",
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

  it("USDC/USDT/PYUSD/DAI mint ≈ $1000 (pegged USD ⇒ 1000 units)", () => {
    const pegged = FAUCET_TOKENS.filter((t) => ["USDC", "USDT", "PYUSD", "DAI"].includes(t.symbol));
    expect(pegged).toHaveLength(4);
    for (const t of pegged) {
      expect(t.amount).toBe(1_000n);
    }
  });
});
