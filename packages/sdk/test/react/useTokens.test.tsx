import { describe, it, expect, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { makeTestWrapper } from "./TestWrapper";
import { useTokens } from "@/react/useTokens";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

describe("useTokens", () => {
  it("loads the registry's 7 active tokens", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);

    const { result } = renderHook(() => useTokens(), { wrapper });

    expect(result.current.isLoading).toBe(true);
    await waitFor(() => expect(result.current.isLoading).toBe(false), { timeout: 10_000 });

    expect(result.current.tokens.length).toBe(7);
    expect(result.current.activeTokens.length).toBe(7);
    expect(result.current.error).toBeNull();
  }, 15_000);
});
