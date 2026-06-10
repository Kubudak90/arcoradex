import { describe, it, expect } from "vitest";
import { healthBand, healthLabel } from "@arcoralabs/dex-sdk/v2";

// §7 reserve-health band boundaries — the mapping the ReserveHealthBar renders.
// Boundaries are inclusive at the lower edge of each band (7500 / 5000 / 2500).
describe("healthBand / healthLabel", () => {
  it("maps the Healthy band (75-100%)", () => {
    expect(healthBand(10000)).toBe("75-100");
    expect(healthLabel(10000)).toBe("Healthy");
    expect(healthBand(7500)).toBe("75-100");
    expect(healthLabel(7500)).toBe("Healthy");
  });

  it("maps the Caution band (50-75%)", () => {
    expect(healthBand(7499)).toBe("50-75");
    expect(healthLabel(7499)).toBe("Caution");
    expect(healthBand(5000)).toBe("50-75");
    expect(healthLabel(5000)).toBe("Caution");
  });

  it("maps the Low band (25-50%)", () => {
    expect(healthBand(4999)).toBe("25-50");
    expect(healthLabel(4999)).toBe("Low");
    expect(healthBand(2500)).toBe("25-50");
    expect(healthLabel(2500)).toBe("Low");
  });

  it("maps the Critical band (0-25%)", () => {
    expect(healthBand(2499)).toBe("0-25");
    expect(healthLabel(2499)).toBe("Critical");
    expect(healthBand(0)).toBe("0-25");
    expect(healthLabel(0)).toBe("Critical");
  });
});
