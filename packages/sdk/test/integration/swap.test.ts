import { describe, it, expect, inject, beforeAll } from "vitest";
import { http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createArcoraDex, arcTestnet } from "@";

const ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const mintAbi = parseAbi(["function mint(address to, uint256 amount)"]);

const writeSdk = () => {
  const rpcUrl = inject("anvilRpcUrl");
  const deployed = inject("deployed");
  return createArcoraDex({
    chain: arcTestnet,
    transport: http(rpcUrl),
    account: privateKeyToAccount(ANVIL_KEY),
    addresses: deployed,
  });
};

const usdc = () => inject("deployed").tokens.find((t) => t.symbol === "USDC")!.address;
const eurc = () => inject("deployed").tokens.find((t) => t.symbol === "EURC")!.address;

describe("swap()", () => {
  // Deploy script seeds the pool with the deployer's entire mint, leaving deployer
  // with zero token balance. Mint a fresh stash to the deployer for swap tests.
  beforeAll(async () => {
    const sdk = writeSdk();
    const account = privateKeyToAccount(ANVIL_KEY);
    const hash = await sdk.walletClient!.writeContract({
      chain: sdk.chain,
      account,
      address: usdc(),
      abi: mintAbi,
      functionName: "mint",
      args: [account.address, 1_000_000_000n], // 1,000 USDC
    });
    await sdk.publicClient.waitForTransactionReceipt({ hash });
  });

  it("first swap auto-approves and returns approveHash + swap result", async () => {
    const sdk = writeSdk();
    const result = await sdk.swap({
      tokenIn: usdc(),
      tokenOut: eurc(),
      amountIn: 10_000_000n,
      slippageBps: 100,
    });
    expect(result.approveHash).toBeDefined();
    expect(result.hash).toBeDefined();
    expect(result.amountOut).toBeGreaterThan(0n);
    expect(result.event.tokenIn.toLowerCase()).toBe(usdc().toLowerCase());
    expect(result.event.tokenOut.toLowerCase()).toBe(eurc().toLowerCase());
  });

  it("subsequent swap (same token, infinite allowance) skips approve", async () => {
    const sdk = writeSdk();
    const result = await sdk.swap({
      tokenIn: usdc(),
      tokenOut: eurc(),
      amountIn: 5_000_000n,
      slippageBps: 100,
    });
    expect(result.approveHash).toBeUndefined();
    expect(result.amountOut).toBeGreaterThan(0n);
  });

  it("recipient override sends output to a different address", async () => {
    const sdk = writeSdk();
    const recipient = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as const;
    const result = await sdk.swap({
      tokenIn: usdc(),
      tokenOut: eurc(),
      amountIn: 1_000_000n,
      slippageBps: 100,
      recipient,
    });
    expect(result.event.recipient.toLowerCase()).toBe(recipient.toLowerCase());
  });
});
