import { describe, it, expect, inject, vi } from "vitest";
import { renderHook } from "@testing-library/react";
import { makeTestWrapper } from "./TestWrapper";
import { useArcoraDex } from "@/react/useArcoraDex";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

// M-8 (audit 2026-05-24): cover the two outcomes of the consumer hook —
// the guarded throw when no provider is present, and the happy path that
// returns the live client when used under the provider.
describe("useArcoraDex", () => {
  it("throws a descriptive error when called outside <ArcoraDexProvider>", () => {
    // Suppress React's own console.error noise for this expected throw.
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      expect(() => renderHook(() => useArcoraDex())).toThrow(
        /useArcoraDex must be called inside <ArcoraDexProvider>/i,
      );
    } finally {
      spy.mockRestore();
    }
  });

  it("returns the SDK client when used under the provider", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);

    const { result } = renderHook(() => useArcoraDex(), { wrapper });

    // Shape sanity — the client must expose its addresses, chain, and a
    // publicClient. Account is undefined until the wagmi mock connector
    // actually attaches (covered by makeConnectedTestWrapper, not here).
    expect(result.current).toBeDefined();
    expect(result.current.addresses.pool).toBe(deployed.pool);
    expect(result.current.chain.id).toBe(5042002);
    expect(typeof result.current.publicClient).toBe("object");
  });
});
