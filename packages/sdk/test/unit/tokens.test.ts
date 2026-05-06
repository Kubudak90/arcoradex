import { describe, it, expect } from "vitest";
import { tokenLabel } from "@/tokens/label";

const USDC = "0x3BFa09fF6467639f0981948385bA1018Ac07d22C";

describe("tokenLabel", () => {
  it("returns metadata for a known checksummed address", () => {
    expect(tokenLabel(USDC)).toEqual({ symbol: "USDC", name: "USD Coin" });
  });
  it("returns metadata for a lowercased address (post-getAddress normalization)", () => {
    expect(tokenLabel(USDC.toLowerCase() as `0x${string}`)).toEqual({ symbol: "USDC", name: "USD Coin" });
  });
  it("returns metadata for an UPPERCASED address (post-getAddress normalization)", () => {
    expect(tokenLabel(USDC.toUpperCase() as `0x${string}`)).toEqual({ symbol: "USDC", name: "USD Coin" });
  });
  it("falls back to a synthetic symbol for unknown addresses", () => {
    const unknown = "0x1111111111111111111111111111111111111111" as const;
    const m = tokenLabel(unknown);
    expect(m.symbol.length).toBeGreaterThan(0);
    expect(m.name).toBe(unknown);
  });
});
