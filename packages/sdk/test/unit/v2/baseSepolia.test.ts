import { describe, expect, it } from "vitest";
import { baseSepolia } from "../../../src/chains/baseSepolia";

describe("baseSepolia chain", () => {
  it("is chainId 84532, testnet, ETH-native", () => {
    expect(baseSepolia.id).toBe(84532);
    expect(baseSepolia.testnet).toBe(true);
    expect(baseSepolia.nativeCurrency.symbol).toBe("ETH");
    expect(baseSepolia.rpcUrls.default.http[0]).toMatch(/^https:\/\//);
  });
});
