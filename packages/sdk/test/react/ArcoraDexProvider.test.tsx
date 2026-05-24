import { describe, it, expect, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { makeTestWrapper, makeConnectedTestWrapper } from "./TestWrapper";
import { useArcoraDexContext } from "@/react/ArcoraDexProvider";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

// M-8 (audit 2026-05-24): exercise the provider's context-construction path
// directly. The other hook tests indirectly cover the happy path; these
// pin down the transitions (no-account → connected) and the addresses
// pass-through that integrators rely on.
describe("ArcoraDexProvider", () => {
  it("exposes a usable SDK client with no wallet connected", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);

    const { result } = renderHook(() => useArcoraDexContext(), { wrapper });

    expect(result.current).not.toBeNull();
    const sdk = result.current!;
    expect(sdk.addresses.pool).toBe(deployed.pool);
    expect(sdk.addresses.registry).toBe(deployed.registry);
    expect(sdk.addresses.lp).toBe(deployed.lp);
    // No wallet attached yet.
    expect(sdk.account).toBeUndefined();
    expect(sdk.walletClient).toBeUndefined();
  });

  it("attaches a wallet client once the wagmi mock connector reports connected", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeConnectedTestWrapper(rpcUrl, deployed);

    const { result } = renderHook(() => useArcoraDexContext(), { wrapper });

    await waitFor(() => expect(result.current?.account).toBeDefined(), { timeout: 10_000 });
    expect(result.current?.walletClient).toBeDefined();
  }, 15_000);
});
