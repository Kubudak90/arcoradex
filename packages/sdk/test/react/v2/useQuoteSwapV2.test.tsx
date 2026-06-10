import { describe, it, expect, inject } from "vitest";
import { renderHook } from "@testing-library/react";
import { makeTestWrapperV2 } from "./TestWrapperV2";
import { useQuoteSwapV2 } from "@/react/v2/useQuoteSwapV2";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

// Mirrors the V1 useQuoteSwap test's enabled-guard assertions. The anvil
// fixture deploys V1 contracts only (V2 anvil fixture deferred — see Task 9
// note), so this test pins the hook's guard logic (no amount / same-token →
// disabled, null result) which does NOT touch the chain. Live V2 quote decoding
// is covered by test/integration/v2/addresses-live-v2.test.ts.
describe("useQuoteSwapV2", () => {
  it("returns null and does not fetch when amountIn is undefined", () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapperV2(rpcUrl, deployed);
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;
    const eurc = deployed.tokens.find((t) => t.symbol === "EURC")!.address;

    const { result } = renderHook(
      () =>
        useQuoteSwapV2({ tokenIn: usdc, tokenOut: eurc, amountIn: undefined }, { debounceMs: 0 }),
      { wrapper },
    );

    expect(result.current.data).toBeNull();
    expect(result.current.isFetching).toBe(false);
  });

  it("returns null and does not fetch for a same-token quote", () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapperV2(rpcUrl, deployed);
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;

    const { result } = renderHook(
      () =>
        useQuoteSwapV2({ tokenIn: usdc, tokenOut: usdc, amountIn: 1_000_000n }, { debounceMs: 0 }),
      { wrapper },
    );

    expect(result.current.data).toBeNull();
    expect(result.current.isFetching).toBe(false);
  });
});
