import { describe, it, expect } from "vitest";
import { minOut, deadline } from "@/slippage";

describe("minOut", () => {
  it("returns the quoted amount when slippage is 0", () => {
    expect(minOut(1_000_000n, 0)).toBe(1_000_000n);
  });
  it("applies 0.5% slippage (50 bps)", () => {
    expect(minOut(1_000_000n, 50)).toBe(995_000n);
  });
  it("applies 1% slippage (100 bps)", () => {
    expect(minOut(1_000_000n, 100)).toBe(990_000n);
  });
  it("returns 0 when slippage >= 10000 bps", () => {
    expect(minOut(1_000_000n, 10_000)).toBe(0n);
    expect(minOut(1_000_000n, 99_999)).toBe(0n);
  });
  it("rounds toward zero (BigInt integer division)", () => {
    // 12345 * 9990 = 123_326_550 → /10_000 = 12_332
    expect(minOut(12_345n, 10)).toBe(12_332n);
  });
});

describe("deadline", () => {
  it("defaults to 20 minutes from now", () => {
    const d = deadline();
    const now = Math.floor(Date.now() / 1000);
    const window = Number(d) - now;
    expect(window).toBeGreaterThanOrEqual(20 * 60 - 2);
    expect(window).toBeLessThanOrEqual(20 * 60 + 2);
  });
  it("accepts a custom horizon", () => {
    const d = deadline(60);
    const now = Math.floor(Date.now() / 1000);
    expect(Number(d) - now).toBeGreaterThanOrEqual(58);
    expect(Number(d) - now).toBeLessThanOrEqual(62);
  });
});
