import { describe, it, expect } from "vitest";
import {
  reserveUsd1e18,
  poolShare,
  lpValueUsd1e18,
  depositCapHeadroom,
  exceedsCap,
} from "../lp-math";

const ONE = 10n ** 18n;
const usd = (n: number) => BigInt(n) * ONE; // n USD as 1e18

describe("reserveUsd1e18", () => {
  it("values a 6-dp token at a $1 oracle price", () => {
    // 1000 USDC (6dp) at $1 → $1000 (1e18)
    expect(reserveUsd1e18(1_000_000_000n, 6, ONE)).toBe(usd(1000));
  });

  it("applies a non-$1 oracle price (EUR ≈ $1.08)", () => {
    // 100 EURC (6dp) at $1.08 → $108 (1e18)
    const price = (108n * ONE) / 100n; // 1.08e18
    expect(reserveUsd1e18(100_000_000n, 6, price)).toBe(usd(108));
  });

  it("handles an 18-dp token", () => {
    expect(reserveUsd1e18(5n * ONE, 18, ONE)).toBe(usd(5));
  });
});

describe("poolShare (GF-3)", () => {
  it("is balance / supply", () => {
    expect(poolShare(25n * ONE, 100n * ONE)).toBeCloseTo(0.25, 9);
  });

  it("is 0 when supply is empty (no divide-by-zero)", () => {
    expect(poolShare(0n, 0n)).toBe(0);
  });
});

describe("lpValueUsd1e18 (GF-3)", () => {
  it("is lpPrice × balance / 1e18", () => {
    // 10 LP at $1.05/LP → $10.50 (1e18)
    const lpPrice = (105n * ONE) / 100n; // 1.05e18
    expect(lpValueUsd1e18(lpPrice, 10n * ONE)).toBe((1050n * ONE) / 100n);
  });
});

describe("depositCapHeadroom (GF-4)", () => {
  it("computes remaining headroom under the cap", () => {
    const h = depositCapHeadroom(usd(1_000_000), usd(600_000));
    expect(h).not.toBeNull();
    expect(h!.headroomUsd1e18).toBe(usd(400_000));
    expect(h!.reached).toBe(false);
  });

  it("flags `reached` when the reserve meets the cap", () => {
    const h = depositCapHeadroom(usd(1_000_000), usd(1_000_000));
    expect(h!.headroomUsd1e18).toBe(0n);
    expect(h!.reached).toBe(true);
  });

  it("flags `reached` when over the cap (negative headroom)", () => {
    const h = depositCapHeadroom(usd(1_000_000), usd(1_200_000));
    expect(h!.headroomUsd1e18).toBe(-usd(200_000));
    expect(h!.reached).toBe(true);
  });

  it("returns null for an uncapped token (cap = 0)", () => {
    expect(depositCapHeadroom(0n, usd(500_000))).toBeNull();
  });
});

describe("exceedsCap (GF-4)", () => {
  const headroom = depositCapHeadroom(usd(1_000_000), usd(900_000)); // $100k left

  it("is true when the deposit is larger than headroom", () => {
    expect(exceedsCap(usd(150_000), headroom)).toBe(true);
  });

  it("is false when the deposit fits", () => {
    expect(exceedsCap(usd(50_000), headroom)).toBe(false);
  });

  it("is false at exactly the headroom", () => {
    expect(exceedsCap(usd(100_000), headroom)).toBe(false);
  });

  it("is false for an uncapped token (null headroom)", () => {
    expect(exceedsCap(usd(10_000_000), null)).toBe(false);
  });

  it("is false for a zero deposit", () => {
    expect(exceedsCap(0n, headroom)).toBe(false);
  });
});
