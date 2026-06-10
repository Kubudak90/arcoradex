import { describe, expect, it } from "vitest";
import {
  healthBand, healthLabel, estimatedFeePct, applyMaxGuard, INITIAL_FEE_SCHEDULE,
} from "../../../src/present";

describe("present helpers", () => {
  it("healthBand maps bps → the §7 band label", () => {
    expect(healthBand(10000)).toBe("75-100");
    expect(healthBand(8000)).toBe("75-100");
    expect(healthBand(6000)).toBe("50-75");
    expect(healthBand(3000)).toBe("25-50");
    expect(healthBand(1000)).toBe("0-25");
  });

  it("healthLabel is human and matches the band", () => {
    expect(healthLabel(9000)).toBe("Healthy");
    expect(healthLabel(1000)).toBe("Critical");
  });

  it("INITIAL_FEE_SCHEDULE is the §7 table (marginal fee per band)", () => {
    expect(INITIAL_FEE_SCHEDULE).toEqual([
      { fromBps: 7500, toBps: 10000, feeBps: 5 },
      { fromBps: 5000, toBps: 7500, feeBps: 20 },
      { fromBps: 2500, toBps: 5000, feeBps: 75 },
      { fromBps: 0,    toBps: 2500, feeBps: 300 },
    ]);
  });

  it("estimatedFeePct = feeUsd1e18 / grossUsd1e18 in bps", () => {
    // 0.05% of $100 = $0.05; 5e16 / 100e18 → 5 bps.
    expect(estimatedFeePct(50_000_000_000_000_000n, 100_000_000_000_000_000_000n)).toBeCloseTo(0.05, 4);
  });

  it("applyMaxGuard clamps and flags over-max", () => {
    expect(applyMaxGuard(120n, 100n)).toEqual({ amount: 100n, clamped: true,  overMax: true });
    expect(applyMaxGuard(80n,  100n)).toEqual({ amount: 80n,  clamped: false, overMax: false });
  });
});
