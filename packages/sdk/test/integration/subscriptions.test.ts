import { describe, it, expect, vi, inject } from "vitest";
import { http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createArcoraDex, arcTestnet } from "@";

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

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

const writeSdk = () => {
  const rpcUrl = inject("anvilRpcUrl") as string;
  const deployed = inject("deployed") as DeployedAddresses;
  return createArcoraDex({
    chain: arcTestnet,
    transport: http(rpcUrl),
    account: privateKeyToAccount(ANVIL_KEY),
    addresses: deployed,
  });
};

const usdc = () => (inject("deployed") as DeployedAddresses).tokens.find((t) => t.symbol === "USDC")!.address;
const eurc = () => (inject("deployed") as DeployedAddresses).tokens.find((t) => t.symbol === "EURC")!.address;

describe("subscribeSwaps", () => {
  it("invokes handler when a swap is broadcast", async () => {
    const sdk = writeSdk();
    const handler = vi.fn();
    const unsub = sdk.subscribeSwaps(handler, { pollingInterval: 200 });

    const mintHash = await sdk.walletClient!.writeContract({
      address: usdc(),
      abi: MINT_ABI,
      functionName: "mint",
      args: [sdk.account!.address, 100_000_000n],
      chain: sdk.chain,
      account: sdk.account!,
    });
    await sdk.publicClient.waitForTransactionReceipt({ hash: mintHash });

    await sdk.swap({
      tokenIn: usdc(),
      tokenOut: eurc(),
      amountIn: 1_000_000n,
      slippageBps: 100,
      // Bound the approval so swap.test.ts's "first auto-approve" expectation
      // (with amountIn=10M) still triggers a fresh MAX approval.
      exactApproval: true,
    });

    // viem polls at 200ms interval; give the watcher a moment to deliver
    await new Promise((r) => setTimeout(r, 2_000));

    expect(handler).toHaveBeenCalled();
    unsub();
  }, 20_000);

  it("unsub() prevents further handler calls", async () => {
    const sdk = writeSdk();
    const handler = vi.fn();
    const unsub = sdk.subscribeSwaps(handler, { pollingInterval: 200 });
    unsub();

    // Mint + swap after unsubscribing
    const mintHash = await sdk.walletClient!.writeContract({
      address: usdc(),
      abi: MINT_ABI,
      functionName: "mint",
      args: [sdk.account!.address, 100_000_000n],
      chain: sdk.chain,
      account: sdk.account!,
    });
    await sdk.publicClient.waitForTransactionReceipt({ hash: mintHash });

    await sdk.swap({
      tokenIn: usdc(),
      tokenOut: eurc(),
      amountIn: 500_000n,
      slippageBps: 100,
      exactApproval: true,
    });
    await new Promise((r) => setTimeout(r, 2_000));

    expect(handler).not.toHaveBeenCalled();
  }, 20_000);
});
