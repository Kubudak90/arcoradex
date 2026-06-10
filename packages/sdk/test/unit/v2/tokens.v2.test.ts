import { describe, expect, it } from "vitest";
import { isAddress } from "viem";
import {
  KNOWN_TOKENS_V2,
  KNOWN_TOKENS_V2_BY_CHAIN,
} from "../../../src/tokens/known.v2";
import { baseSepolia } from "../../../src/chains/baseSepolia";
import { arcTestnet } from "../../../src/chains/arcTestnet";

describe("KNOWN_TOKENS_V2 (per-chain V2 token maps)", () => {
  it("has the 3 Base Sepolia (84532) tokens keyed by chain id", () => {
    const base = KNOWN_TOKENS_V2_BY_CHAIN[baseSepolia.id]!;
    expect(base["0x3a98d8adC295d90171e9DA93D411dEa95674c867"]).toEqual({ symbol: "USDC", name: "USD Coin" });
    expect(base["0x7110315D229C7CE655399703ACbA8E67f1d5C0c0"]).toEqual({ symbol: "USDT", name: "Tether USD" });
    expect(base["0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7"]).toEqual({ symbol: "EURC", name: "Euro Coin" });
  });

  it("has the 3 Arc testnet (5042002) tokens keyed by chain id", () => {
    const arc = KNOWN_TOKENS_V2_BY_CHAIN[arcTestnet.id]!;
    expect(arc["0x168655bc42265d8721AD6BCe20435919A0160B79"]).toEqual({ symbol: "USDC", name: "USD Coin" });
    expect(arc["0xD05FE3e0A38508b182143E1eBf69C657a87cBe22"]).toEqual({ symbol: "USDT", name: "Tether USD" });
    expect(arc["0xb1D82C6ba72CfE115Baa0Cd33De78224D9370Eea"]).toEqual({ symbol: "EURC", name: "Euro Coin" });
  });

  it("every token address is EIP-55 valid", () => {
    for (const chainMap of Object.values(KNOWN_TOKENS_V2_BY_CHAIN)) {
      for (const addr of Object.keys(chainMap)) {
        expect(isAddress(addr, { strict: true })).toBe(true);
      }
    }
  });

  it("does not collide cross-chain: no token address is shared between the two chains", () => {
    const base = new Set(
      Object.keys(KNOWN_TOKENS_V2_BY_CHAIN[baseSepolia.id]!).map((a) => a.toLowerCase()),
    );
    for (const addr of Object.keys(KNOWN_TOKENS_V2_BY_CHAIN[arcTestnet.id]!)) {
      expect(base.has(addr.toLowerCase())).toBe(false);
    }
  });

  it("the flat KNOWN_TOKENS_V2 merges both chains (6 entries, getTokensV2 lookup)", () => {
    // getTokensV2 looks up by address only; the flat merge keeps that path
    // working for both chains since addresses never collide cross-chain.
    expect(Object.keys(KNOWN_TOKENS_V2)).toHaveLength(6);
    expect(KNOWN_TOKENS_V2["0x3a98d8adC295d90171e9DA93D411dEa95674c867"]).toEqual({ symbol: "USDC", name: "USD Coin" });
    expect(KNOWN_TOKENS_V2["0x168655bc42265d8721AD6BCe20435919A0160B79"]).toEqual({ symbol: "USDC", name: "USD Coin" });
  });
});
