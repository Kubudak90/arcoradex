import { describe, it, expect, inject } from "vitest";
import { http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createArcoraDex, arcTestnet } from "@";

const ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

describe("createArcoraDex", () => {
  it("read-only mode: no walletClient, account undefined", () => {
    const sdk = createArcoraDex({
      chain: arcTestnet,
      transport: http(inject("anvilRpcUrl")),
      addresses: inject("deployed"),
    });
    expect(sdk.walletClient).toBeUndefined();
    expect(sdk.account).toBeUndefined();
  });

  it("with-account mode: walletClient set", () => {
    const sdk = createArcoraDex({
      chain: arcTestnet,
      transport: http(inject("anvilRpcUrl")),
      account: privateKeyToAccount(ANVIL_KEY),
      addresses: inject("deployed"),
    });
    expect(sdk.walletClient).toBeDefined();
    expect(sdk.account?.address).toBe("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
  });

  it("addresses default lookup throws on unknown chain", () => {
    const fakeChain = { ...arcTestnet, id: 9_999_999 };
    expect(() =>
      createArcoraDex({ chain: fakeChain, transport: http(inject("anvilRpcUrl")) }),
    ).toThrow(/No default ArcoraDexAddresses/);
  });
});
