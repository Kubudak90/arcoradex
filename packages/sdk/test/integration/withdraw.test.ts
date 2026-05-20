import { describe, it, expect, inject } from "vitest";
import { http, createTestClient, publicActions } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createArcoraDex, arcTestnet } from "@";

const ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

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

describe("withdraw()", () => {
  it("burns LP and returns amountOut + protocolFee meta", async () => {
    const sdk = writeSdk();

    // The Pool enforces MIN_HOLD_SECONDS = 1 hour since lastMintAt.
    // The deploy fixture mints LP at setup time, so we must warp past the
    // hold window before withdraw() will succeed.
    const testClient = createTestClient({
      chain: arcTestnet,
      mode: "anvil",
      transport: http(inject("anvilRpcUrl")),
    }).extend(publicActions);
    await testClient.increaseTime({ seconds: 3601 });
    await testClient.mine({ blocks: 1 });

    // After warping, the chain's block.timestamp is ~3601s ahead of JS
    // Date.now(). The SDK's default deadline() uses Date.now(), which would
    // produce a deadline that's already past from the chain's point of view.
    // Fetch the current block timestamp and add 20 minutes to compute an
    // explicit deadline the contract will accept.
    const block = await testClient.getBlock();
    const explicitDeadline = block.timestamp + BigInt(20 * 60);

    const result = await sdk.withdraw({
      tokenOut: usdc(),
      lpAmount: 10n * 10n ** 18n,
      slippageBps: 100,
      deadline: explicitDeadline,
    });
    expect(result.hash).toBeDefined();
    expect(result.amountOut).toBeGreaterThan(0n);
    expect(result.event.lpBurned).toBe(10n * 10n ** 18n);
    expect(result.event.tokenOut.toLowerCase()).toBe(usdc().toLowerCase());

    // All integration tests share one Anvil instance (singleFork: true). Reset
    // the chain clock back to real wall-clock time so subsequent test files
    // (deposit, swap history, etc.) see a chain timestamp that matches their
    // SDK-generated deadlines (which use Date.now()).
    await testClient.setNextBlockTimestamp({
      timestamp: BigInt(Math.floor(Date.now() / 1000)),
    });
    await testClient.mine({ blocks: 1 });
  });
});
