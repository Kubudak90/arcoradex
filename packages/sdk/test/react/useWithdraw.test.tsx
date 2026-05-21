import { describe, it, expect, vi, inject } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { http, createWalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { makeConnectedTestWrapper, makeTestWrapper } from "./TestWrapper";
import { useWithdraw } from "@/react/useWithdraw";
import { useArcoraDex } from "@/react/useArcoraDex";
import { arcTestnet } from "@/chains/arcTestnet";
import { createArcoraDex } from "@/client";

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

describe("useWithdraw", () => {
  // Shape-only smoke: no chain interaction, no test-ordering hazard.
  it("returns the expected mutation-result shape pre-mutate", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const wrapper = makeTestWrapper(rpcUrl, deployed);

    const { result } = renderHook(() => useWithdraw(), { wrapper });

    expect(typeof result.current.mutate).toBe("function");
    expect(typeof result.current.mutateAsync).toBe("function");
    expect(typeof result.current.reset).toBe("function");
    expect(result.current.isPending).toBe(false);
    expect(result.current.data).toBeUndefined();
    expect(result.current.error).toBeNull();
  }, 10_000);

  // Error-path: a fresh deposit resets lastMintAt to the chain's current
  // timestamp, so an immediate withdraw can't satisfy MIN_HOLD_SECONDS and is
  // guaranteed to fail regardless of what time-warps other test files may
  // have performed against the shared anvil. Order-independent.
  //
  // Note on assertion strength: when viem's writeContract goes through the
  // local privateKeyToAccount path it simulates first and surfaces a typed
  // EarlyWithdrawError. Through the wagmi mock connector path (which this
  // test exercises, since FaucetButton/SwapCard would) the simulate step is
  // skipped, the revert lands on the receipt as status="reverted", and the
  // SDK currently surfaces it as a generic "Withdrew event not found"
  // Error. Both prove the hook plumbs errors correctly; tightening the
  // typed-error coverage of the wagmi path would be a separate SDK PR.
  it("surfaces a chain-rejection error before MIN_HOLD_SECONDS elapses", async () => {
    const rpcUrl = inject("anvilRpcUrl") as string;
    const deployed = inject("deployed") as DeployedAddresses;
    const usdc = deployed.tokens.find((t) => t.symbol === "USDC")!.address;

    // Seed the deployer with USDC + do a deposit out-of-band so we know
    // exactly when lastMintAt was set on chain.
    const account = privateKeyToAccount(ANVIL_KEY);
    const wc = createWalletClient({ account, chain: arcTestnet, transport: http(rpcUrl) });
    await wc.writeContract({
      address: usdc,
      abi: MINT_ABI,
      functionName: "mint",
      args: [account.address, 200_000_000n],
    });
    const setupSdk = createArcoraDex({
      chain: arcTestnet,
      transport: http(rpcUrl),
      account,
      addresses: deployed,
    });
    await setupSdk.deposit({ token: usdc, amount: 50_000_000n, slippageBps: 100 });

    const wrapper = makeConnectedTestWrapper(rpcUrl, deployed);
    const { result } = renderHook(
      () => ({ w: useWithdraw(), sdk: useArcoraDex() }),
      { wrapper },
    );
    await waitFor(() => expect(result.current.sdk.account).toBeDefined(), { timeout: 10_000 });

    const onError = vi.fn();
    result.current.w.mutate(
      { tokenOut: usdc, lpAmount: 1n * 10n ** 18n, slippageBps: 100 },
      { onError },
    );

    await waitFor(() => expect(result.current.w.error).not.toBeNull(), { timeout: 15_000 });

    const err = result.current.w.error!;
    expect(err).toBeInstanceOf(Error);
    expect(onError).toHaveBeenCalledTimes(1);
    expect(onError.mock.calls[0]![0]).toBeInstanceOf(Error);
    // Hook surface: data stays undefined on failure.
    expect(result.current.w.data).toBeUndefined();
  }, 30_000);
});
