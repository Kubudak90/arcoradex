import { describe, expect, it } from "vitest";
import { arcTestnet } from "../../../src/chains/arcTestnet";

describe("arcTestnet chain (V2 target)", () => {
  it("is chainId 5042002, testnet, USDC-native gas", () => {
    expect(arcTestnet.id).toBe(5042002);
    expect(arcTestnet.testnet).toBe(true);
    expect(arcTestnet.nativeCurrency.symbol).toBe("USDC");
    expect(arcTestnet.rpcUrls.default.http[0]).toBe("https://rpc.testnet.arc.network");
  });

  it("exposes the Arc explorer", () => {
    expect(arcTestnet.blockExplorers?.default.url).toBe("https://testnet.arcscan.app");
  });
});
