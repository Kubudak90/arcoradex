import { describe, it, expect, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { makeTestWrapper } from "./TestWrapper";
import { usePoolStats } from "@/react/usePoolStats";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

describe("usePoolStats", () => {
  it("returns the seeded NAV (~$70k) and default fee bps", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);

    const { result } = renderHook(() => usePoolStats(), { wrapper });

    await waitFor(() => expect(result.current.stats).not.toBeNull(), { timeout: 10_000 });

    expect(result.current.stats!.swapFeeBps).toBe(30);
    expect(result.current.stats!.protocolFeeShareBps).toBe(1000);
    expect(result.current.stats!.navUsd1e18).toBeGreaterThan(69_000n * 10n ** 18n);
  }, 15_000);
});
