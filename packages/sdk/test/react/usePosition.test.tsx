import { describe, it, expect, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { privateKeyToAccount } from "viem/accounts";
import { makeTestWrapper } from "./TestWrapper";
import { usePosition } from "@/react/usePosition";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

const ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

describe("usePosition", () => {
  it("returns null position when no address is provided and no wallet connected", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);

    const { result } = renderHook(() => usePosition(), { wrapper });

    // Without a connected wallet OR an explicit addr, the hook stays idle.
    expect(result.current.position).toBeNull();
    expect(result.current.error).toBeNull();
  }, 10_000);

  it("returns a UserPosition object for the anvil deployer address", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);
    const deployer = privateKeyToAccount(ANVIL_KEY).address;

    const { result } = renderHook(() => usePosition(deployer), { wrapper });

    await waitFor(() => expect(result.current.position).not.toBeNull(), { timeout: 10_000 });
    const pos = result.current.position!;
    // Shape sanity — the deploy fixture seeds the deployer with some LP.
    expect(typeof pos.lpBalance).toBe("bigint");
    expect(pos.lpBalance).toBeGreaterThanOrEqual(0n);
    expect(result.current.error).toBeNull();
  }, 15_000);
});
