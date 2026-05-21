import { describe, it, expect, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { makeTestWrapper } from "./TestWrapper";
import { useQuoteDeposit } from "@/react/useQuoteDeposit";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

describe("useQuoteDeposit", () => {
  it("returns null when amount is undefined", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;

    const { result } = renderHook(
      () => useQuoteDeposit({ token: usdc, amount: undefined }, { debounceMs: 0 }),
      { wrapper },
    );

    expect(result.current.data).toBeNull();
    expect(result.current.isFetching).toBe(false);
  }, 10_000);

  it("returns a positive LP-quote for valid deposit args", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;

    const { result } = renderHook(
      () => useQuoteDeposit({ token: usdc, amount: 100_000_000n }, { debounceMs: 0 }),
      { wrapper },
    );

    await waitFor(() => expect(result.current.data).not.toBeNull(), { timeout: 10_000 });
    expect(result.current.data!).toBeGreaterThan(0n);
    expect(result.current.error).toBeNull();
  }, 15_000);
});
