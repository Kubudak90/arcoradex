import { describe, it, expect } from "vitest";
import { estimatedFeePct } from "@arcoralabs/dex-sdk/v2";

// §9 estimated dynamic fee — feeUsd1e18 / grossUsd1e18 → percent, with a
// zero-gross guard so the DynamicFeeRow never divides by zero.
describe("estimatedFeePct", () => {
  it("computes 0.05% for a 0.05% fee (5e14 over 1e18)", () => {
    expect(estimatedFeePct(5n * 10n ** 14n, 10n ** 18n)).toBeCloseTo(0.05, 5);
  });

  it("computes 0.20% for a 0.20% fee (2e15 over 1e18)", () => {
    expect(estimatedFeePct(2n * 10n ** 15n, 10n ** 18n)).toBeCloseTo(0.2, 5);
  });

  it("returns 0 when gross is zero (no divide-by-zero)", () => {
    expect(estimatedFeePct(5n * 10n ** 14n, 0n)).toBe(0);
  });

  it("returns 0 when the fee is zero", () => {
    expect(estimatedFeePct(0n, 10n ** 18n)).toBe(0);
  });
});
