import { describe, it, expect, inject } from "vitest";
import { http } from "viem";
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
    const result = await sdk.withdraw({
      tokenOut: usdc(),
      lpAmount: 10n * 10n ** 18n,
      slippageBps: 100,
    });
    expect(result.hash).toBeDefined();
    expect(result.amountOut).toBeGreaterThan(0n);
    expect(result.event.lpBurned).toBe(10n * 10n ** 18n);
    expect(result.event.tokenOut.toLowerCase()).toBe(usdc().toLowerCase());
  });
});
