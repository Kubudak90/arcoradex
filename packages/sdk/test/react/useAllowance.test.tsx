import { describe, it, expect, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { makeConnectedTestWrapper } from "./TestWrapper";
import { useAllowance } from "@/react/useAllowance";
import { useArcoraDex } from "@/react/useArcoraDex";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

describe("useAllowance", () => {
  it("isApprovalNeeded resolves to a boolean once the on-chain allowance read settles", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeConnectedTestWrapper(rpcUrl, deployed);
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;

    const { result } = renderHook(
      () => ({
        sdk: useArcoraDex(),
        a: useAllowance({ token: usdc, spender: deployed.pool, amount: 1_000_000n }),
      }),
      { wrapper },
    );

    // Wait for the mock connector to attach.
    await waitFor(() => expect(result.current.sdk.account).toBeDefined(), { timeout: 10_000 });

    // Wait for the allowance read to land — once allowance has a value, the
    // hook's `isApprovalNeeded` flips from null to a concrete boolean.
    await waitFor(() => expect(typeof result.current.a.isApprovalNeeded).toBe("boolean"), {
      timeout: 10_000,
    });

    expect(result.current.a.error).toBeNull();
    expect(typeof result.current.a.ensureAllowance).toBe("function");
  }, 20_000);

  it("ensureAllowance() throws when token/spender/amount are not all set", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeConnectedTestWrapper(rpcUrl, deployed);

    const { result } = renderHook(
      () => useAllowance({ token: undefined, spender: deployed.pool, amount: 100n }),
      { wrapper },
    );

    await expect(result.current.ensureAllowance()).rejects.toThrow(/token, spender, and amount/i);
  }, 10_000);
});
