import { describe, it, expect, vi, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { http, createWalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { makeConnectedTestWrapper } from "./TestWrapper";
import { useDeposit } from "@/react/useDeposit";
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

describe("useDeposit", () => {
  it("mutate() executes a deposit and onSuccess receives the DepositResult", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;

    // Seed the deployer with USDC so the deposit has balance to pull.
    const account = privateKeyToAccount(ANVIL_KEY);
    const wc = createWalletClient({ account, chain: arcTestnet, transport: http(rpcUrl) });
    await wc.writeContract({
      address: usdc,
      abi: MINT_ABI,
      functionName: "mint",
      args: [account.address, 200_000_000n], // 200 USDC
    });
    await new Promise((r) => setTimeout(r, 500));

    const wrapper = makeConnectedTestWrapper(rpcUrl, deployed);
    const { result } = renderHook(
      () => ({ d: useDeposit(), sdk: useArcoraDex() }),
      { wrapper },
    );

    await waitFor(() => expect(result.current.sdk.account).toBeDefined(), { timeout: 10_000 });

    const onSuccess = vi.fn();
    result.current.d.mutate(
      { token: usdc, amount: 50_000_000n, slippageBps: 100 },
      { onSuccess },
    );

    await waitFor(
      () => {
        if (result.current.d.error) throw result.current.d.error;
        expect(result.current.d.data).toBeDefined();
      },
      { timeout: 15_000 },
    );

    expect(onSuccess).toHaveBeenCalledTimes(1);
    const data = result.current.d.data!;
    expect(data.lpMinted).toBeGreaterThan(0n);
    expect(data.event.amountIn).toBe(50_000_000n);
    expect(data.event.token.toLowerCase()).toBe(usdc.toLowerCase());
  }, 30_000);
});
