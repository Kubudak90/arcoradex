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

describe("deposit()", () => {
  // Same seed-the-deployer dance as the swap suite (parallel test files don't share state).
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

  it("auto-approves (or skips if already approved) and mints LP", async () => {
    const sdk = writeSdk();
    const result = await sdk.deposit({
      token: usdc(),
      amount: 100_000_000n,
      slippageBps: 100,
    });
    expect(result.lpMinted).toBeGreaterThan(0n);
    expect(result.event.amountIn).toBe(100_000_000n);
    expect(result.event.token.toLowerCase()).toBe(usdc().toLowerCase());
  });

  it("exactApproval: true succeeds with bounded approval", async () => {
    const sdk = writeSdk();
    const result = await sdk.deposit({
      token: usdc(),
      amount: 50_000_000n,
      slippageBps: 100,
      exactApproval: true,
    });
    expect(result.lpMinted).toBeGreaterThan(0n);
  });
});
