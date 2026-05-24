import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { renderHook, act } from "@testing-library/react";
import { useDebouncedValue } from "@/react/useDebouncedValue";

// M-8 (audit 2026-05-24): unit coverage for the hook. No anvil, no SDK
// provider — pure timing behaviour against fake timers.
describe("useDebouncedValue", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("returns the initial value synchronously", () => {
    const { result } = renderHook(() => useDebouncedValue("a", 200));
    expect(result.current).toBe("a");
  });

  it("holds the previous value while the timer is pending, then commits", () => {
    const { result, rerender } = renderHook(({ v }: { v: string }) => useDebouncedValue(v, 200), {
      initialProps: { v: "a" },
    });
    expect(result.current).toBe("a");

    rerender({ v: "b" });
    expect(result.current).toBe("a"); // not flushed yet

    act(() => {
      vi.advanceTimersByTime(199);
    });
    expect(result.current).toBe("a"); // still pending

    act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(result.current).toBe("b");
  });

  it("delayMs <= 0 commits the next value synchronously on rerender", () => {
    const { result, rerender } = renderHook(({ v }: { v: number }) => useDebouncedValue(v, 0), {
      initialProps: { v: 1 },
    });
    expect(result.current).toBe(1);

    rerender({ v: 2 });
    // 0-delay branch flushes via the effect on rerender; no timer to advance.
    expect(result.current).toBe(2);
  });

  it("a value that changes again before the timer fires resets the debounce window", () => {
    const { result, rerender } = renderHook(({ v }: { v: string }) => useDebouncedValue(v, 200), {
      initialProps: { v: "a" },
    });

    rerender({ v: "b" });
    act(() => {
      vi.advanceTimersByTime(150);
    });
    expect(result.current).toBe("a");

    // Change before the first 200ms elapses.
    rerender({ v: "c" });
    act(() => {
      vi.advanceTimersByTime(150);
    });
    expect(result.current).toBe("a"); // window restarted, not yet flushed

    act(() => {
      vi.advanceTimersByTime(50);
    });
    expect(result.current).toBe("c");
  });
});
