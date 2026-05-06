import { describe, it, expect, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { makeTestWrapper } from "./TestWrapper";
import { useQuoteSwap } from "@/react/useQuoteSwap";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

describe("useQuoteSwap", () => {
  it("returns null for invalid input (no amount)", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;
    const eurc = deployed.tokens.find((t) => t.symbol === "EURC")!.address;

    const { result } = renderHook(
      () =>
        useQuoteSwap({ tokenIn: usdc, tokenOut: eurc, amountIn: undefined }, { debounceMs: 0 }),
      { wrapper },
    );

    expect(result.current.data).toBeNull();
    expect(result.current.isFetching).toBe(false);
  }, 10_000);

  it("returns a positive bigint for valid input", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;
    const eurc = deployed.tokens.find((t) => t.symbol === "EURC")!.address;

    const { result } = renderHook(
      () =>
        useQuoteSwap(
          { tokenIn: usdc, tokenOut: eurc, amountIn: 100_000_000n },
          { debounceMs: 0 },
        ),
      { wrapper },
    );

    await waitFor(() => expect(result.current.data).not.toBeNull(), { timeout: 10_000 });
    expect(result.current.data!).toBeGreaterThan(0n);
  }, 15_000);
});
