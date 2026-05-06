import { describe, it, expect, vi, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { http, createWalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { makeConnectedTestWrapper } from "./TestWrapper";
import { useSwap } from "@/react/useSwap";
import { useArcoraDex } from "@/react/useArcoraDex";
import { arcTestnet } from "@/chains/arcTestnet";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

const ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

const MINT_ABI = [
  {
    type: "function",
    name: "mint",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

describe("useSwap", () => {
  it("mutate() executes a swap and onSuccess receives the decoded event", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;
    const eurc = deployed.tokens.find((t) => t.symbol === "EURC")!.address;

    // Mint USDC to the deployer so the swap has balance to pull.
    const account = privateKeyToAccount(ANVIL_KEY);
    const wc = createWalletClient({ account, chain: arcTestnet, transport: http(rpcUrl) });
    await wc.writeContract({
      address: usdc,
      abi: MINT_ABI,
      functionName: "mint",
      args: [account.address, 100_000_000n],
    });
    // Allow the mint to be mined.
    await new Promise((r) => setTimeout(r, 500));

    const wrapper = makeConnectedTestWrapper(rpcUrl, deployed);
    const { result } = renderHook(
      () => ({ swap: useSwap(), sdk: useArcoraDex() }),
      { wrapper },
    );

    // Wait for the mock connector to attach so sdk.account is defined before mutate().
    await waitFor(() => expect(result.current.sdk.account).toBeDefined(), { timeout: 10_000 });

    const onSuccess = vi.fn();
    result.current.swap.mutate(
      {
        tokenIn: usdc,
        tokenOut: eurc,
        amountIn: 1_000_000n,
        slippageBps: 100,
        exactApproval: true,
      },
      { onSuccess },
    );

    // Wait for the mutation to settle (data populated or error thrown).
    await waitFor(
      () => {
        if (result.current.swap.error) throw result.current.swap.error;
        expect(result.current.swap.data).toBeDefined();
      },
      { timeout: 15_000 },
    );

    expect(onSuccess).toHaveBeenCalledTimes(1);
    const evt = result.current.swap.data?.event;
    expect(evt?.amountIn).toBe(1_000_000n);
    expect(evt?.tokenIn.toLowerCase()).toBe(usdc.toLowerCase());
    expect(evt?.tokenOut.toLowerCase()).toBe(eurc.toLowerCase());
  }, 30_000);
});
