import { describe, it, expect, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { http, createWalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { makeTestWrapper } from "./TestWrapper";
import { useSwapHistory } from "@/react/useSwapHistory";
import { arcTestnet } from "@/chains/arcTestnet";
import { createArcoraDex } from "@";

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

describe("useSwapHistory", () => {
  it("loads recent swaps and updates incrementally on watch", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;
    const eurc = deployed.tokens.find((t) => t.symbol === "EURC")!.address;

    const wrapper = makeTestWrapper(rpcUrl, deployed);
    const { result } = renderHook(
      () => useSwapHistory({ limit: 10, watch: true, pollingInterval: 200 }),
      { wrapper },
    );

    await waitFor(() => expect(result.current.isLoading).toBe(false), { timeout: 10_000 });
    const initialCount = result.current.events.length;

    // Trigger a new swap via the raw SDK (outside the React tree).
    const account = privateKeyToAccount(ANVIL_KEY);
    const wc = createWalletClient({ account, chain: arcTestnet, transport: http(rpcUrl) });
    await wc.writeContract({
      address: usdc,
      abi: MINT_ABI,
      functionName: "mint",
      args: [account.address, 100_000_000n],
    });
    await new Promise((r) => setTimeout(r, 300));

    const sdk = createArcoraDex({
      chain: arcTestnet,
      transport: http(rpcUrl),
      account,
      addresses: deployed,
    });
    await sdk.swap({
      tokenIn: usdc,
      tokenOut: eurc,
      amountIn: 750_000n,
      slippageBps: 100,
      exactApproval: true,
    });

    // Allow the watcher to pick up the new event.
    await waitFor(
      () => expect(result.current.events.length).toBeGreaterThan(initialCount),
      { timeout: 10_000, interval: 200 },
    );
  }, 30_000);
});
