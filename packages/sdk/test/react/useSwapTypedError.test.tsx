import { describe, it, expect, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { http, createWalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { makeConnectedTestWrapper } from "./TestWrapper";
import { useSwap } from "@/react/useSwap";
import { useArcoraDex } from "@/react/useArcoraDex";
import { arcTestnet } from "@/chains/arcTestnet";
import { ArcoraDexError, SameTokenError } from "@/errors";

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

// L-1 / hooks (audit 2026-05-31): a hook must surface a typed ArcoraDexError,
// not a raw viem ContractFunctionExecutionError. A same-token swap reverts the
// on-chain `quote` with SameToken; the quote action wraps it via
// parseContractError, and the mutation hook propagates it through `.error`.
describe("useSwap surfaces typed ArcoraDexError", () => {
  it("a same-token swap exposes SameTokenError on .error", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;

    // Fund so ensureAllowance/approve can run before the quote revert.
    const account = privateKeyToAccount(ANVIL_KEY);
    const wc = createWalletClient({ account, chain: arcTestnet, transport: http(rpcUrl) });
    await wc.writeContract({
      address: usdc,
      abi: MINT_ABI,
      functionName: "mint",
      args: [account.address, 10_000_000n],
    });
    await new Promise((r) => setTimeout(r, 500));

    const wrapper = makeConnectedTestWrapper(rpcUrl, deployed);
    const { result } = renderHook(
      () => ({ swap: useSwap(), sdk: useArcoraDex() }),
      { wrapper },
    );
    await waitFor(() => expect(result.current.sdk.account).toBeDefined(), { timeout: 10_000 });

    result.current.swap.mutate({
      tokenIn: usdc,
      tokenOut: usdc, // same token → on-chain quote reverts SameToken
      amountIn: 1_000_000n,
      slippageBps: 100,
      exactApproval: true,
    });

    await waitFor(() => expect(result.current.swap.error).not.toBeNull(), { timeout: 15_000 });
    const err = result.current.swap.error!;
    expect(err).toBeInstanceOf(ArcoraDexError);
    expect(err).toBeInstanceOf(SameTokenError);
  }, 30_000);
});
