import { describe, it, expect } from "vitest";
import { fmtUnits, fmtUSD, tryParseUnits } from "@/format";

describe("fmtUnits", () => {
  it("formats USDC with 6 decimals", () => {
    expect(fmtUnits(1_000_000n, 6)).toBe("1");
    expect(fmtUnits(1_500_000n, 6)).toBe("1.5");
    expect(fmtUnits(123_456_789n, 6)).toBe("123.4567");
  });
  it("formats DAI with 18 decimals", () => {
    expect(fmtUnits(10n ** 18n, 18)).toBe("1");
    expect(fmtUnits(15n * 10n ** 17n, 18)).toBe("1.5");
  });
  it("respects displayDecimals and trims trailing zeros", () => {
    expect(fmtUnits(1_500_000n, 6, 6)).toBe("1.5");
  });
});

describe("fmtUSD", () => {
  it("formats 1e18 as $1.00", () => {
    expect(fmtUSD(10n ** 18n)).toBe("$1.00");
  });
  it("formats 70_000e18 with thousands separators", () => {
    expect(fmtUSD(70_000n * 10n ** 18n)).toBe("$70,000.00");
  });
});

describe("tryParseUnits", () => {
  it("parses valid input", () => {
    expect(tryParseUnits("1.5", 6)).toBe(1_500_000n);
    expect(tryParseUnits("100", 18)).toBe(100n * 10n ** 18n);
  });
  it("returns null for empty / invalid", () => {
    expect(tryParseUnits("", 6)).toBe(null);
    expect(tryParseUnits(".", 6)).toBe(null);
    expect(tryParseUnits("abc", 6)).toBe(null);
  });
});
