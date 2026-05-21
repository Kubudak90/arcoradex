import { describe, it, expect, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { makeTestWrapper } from "./TestWrapper";
import { useQuoteWithdraw } from "@/react/useQuoteWithdraw";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

describe("useQuoteWithdraw", () => {
  it("returns null when lpAmount is undefined", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;

    const { result } = renderHook(
      () => useQuoteWithdraw({ tokenOut: usdc, lpAmount: undefined }, { debounceMs: 0 }),
      { wrapper },
    );

    expect(result.current.data).toBeNull();
    expect(result.current.isFetching).toBe(false);
  }, 10_000);

  it("returns amountOut + protocolFee for valid LP amount", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;

    const { result } = renderHook(
      () => useQuoteWithdraw({ tokenOut: usdc, lpAmount: 10n * 10n ** 18n }, { debounceMs: 0 }),
      { wrapper },
    );

    await waitFor(() => expect(result.current.data).not.toBeNull(), { timeout: 10_000 });
    const q = result.current.data!;
    expect(q.amountOut).toBeGreaterThan(0n);
    expect(q.protocolFee).toBeGreaterThanOrEqual(0n);
    expect(result.current.error).toBeNull();
  }, 15_000);
});
