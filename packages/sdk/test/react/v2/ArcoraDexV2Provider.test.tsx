import { describe, it, expect, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { makeTestWrapperV2, makeConnectedTestWrapperV2 } from "./TestWrapperV2";
import { useArcoraDexV2Context } from "@/react/v2/ArcoraDexV2Provider";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

// Mirrors the V1 ArcoraDexProvider test: exercise the V2 provider's
// context-construction path directly — the no-account → connected transition
// and the addresses pass-through that integrators rely on. The anvil fixture
// deploys V1 contracts only (V2 anvil fixture deferred), so this test asserts
// client construction + wallet attachment, NOT live V2 contract reads.
describe("ArcoraDexV2Provider", () => {
  it("exposes a usable V2 SDK client with no wallet connected", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapperV2(rpcUrl, deployed);

    const { result } = renderHook(() => useArcoraDexV2Context(), { wrapper });

    expect(result.current).not.toBeNull();
    const sdk = result.current!;
    expect(sdk.addresses.pool).toBe(deployed.pool);
    expect(sdk.addresses.registry).toBe(deployed.registry);
    expect(sdk.addresses.lp).toBe(deployed.lp);
    // V2 surface is wired.
    expect(typeof sdk.quoteSwapV2).toBe("function");
    expect(typeof sdk.reserveHealth).toBe("function");
    expect(typeof sdk.withdrawProportional).toBe("function");
    // No wallet attached yet.
    expect(sdk.account).toBeUndefined();
    expect(sdk.walletClient).toBeUndefined();
  });

  it("attaches a wallet client once the wagmi mock connector reports connected", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeConnectedTestWrapperV2(rpcUrl, deployed);

    const { result } = renderHook(() => useArcoraDexV2Context(), { wrapper });

    await waitFor(() => expect(result.current?.account).toBeDefined(), { timeout: 10_000 });
    expect(result.current?.walletClient).toBeDefined();
  }, 15_000);
});
