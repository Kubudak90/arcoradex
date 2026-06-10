import { describe, it, expect } from "vitest";
import { useMaxGuard } from "../useMaxGuard";

// `useMaxGuard` is a pure function (no React state) that wraps the SDK's
// `applyMaxGuard`, so it is unit-tested directly. These cover the §9 Max-guard
// math: pass-through under max, exact-max boundary, clamp-and-flag over max, and
// the safe default for null inputs.
describe("useMaxGuard", () => {
  it("passes through when entered < max (no clamp, no over)", () => {
    const r = useMaxGuard(100n, 200n);
    expect(r).toEqual({ amount: 100n, clamped: false, overMax: false });
  });

  it("does not flag over-max at the exact max (boundary is inclusive)", () => {
    const r = useMaxGuard(200n, 200n);
    expect(r).toEqual({ amount: 200n, clamped: false, overMax: false });
  });

  it("clamps to max and flags over when entered > max", () => {
    const r = useMaxGuard(250n, 200n);
    expect(r).toEqual({ amount: 200n, clamped: true, overMax: true });
  });

  it("returns a safe default when entered is null", () => {
    const r = useMaxGuard(null, 200n);
    expect(r).toEqual({ amount: 0n, clamped: false, overMax: false });
  });

  it("returns a safe default when max is null (preserves entered)", () => {
    const r = useMaxGuard(123n, null);
    expect(r).toEqual({ amount: 123n, clamped: false, overMax: false });
  });

  it("returns a safe default when both inputs are null", () => {
    const r = useMaxGuard(null, null);
    expect(r).toEqual({ amount: 0n, clamped: false, overMax: false });
  });
});
