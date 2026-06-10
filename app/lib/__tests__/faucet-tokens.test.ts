import { isAddress } from "viem";
import { describe, expect, it } from "vitest";
import {
  ARC_TESTNET_CHAIN_ID,
  BASE_SEPOLIA_CHAIN_ID,
  FAUCET_SUPPORTED_CHAIN_IDS,
  FAUCET_TOKENS,
  FAUCET_TOKENS_BY_CHAIN,
  faucetTokensFor,
} from "../faucet-tokens";

describe("FAUCET_TOKENS_BY_CHAIN", () => {
  it("covers exactly the two live V2 chains (Base Sepolia 84532 + Arc 5042002)", () => {
    expect([...FAUCET_SUPPORTED_CHAIN_IDS].sort()).toEqual(
      [BASE_SEPOLIA_CHAIN_ID, ARC_TESTNET_CHAIN_ID].sort(),
    );
    expect(BASE_SEPOLIA_CHAIN_ID).toBe(84532);
    expect(ARC_TESTNET_CHAIN_ID).toBe(5042002);
  });

  // Shared shape invariants, asserted per chain.
  for (const [chainIdStr, tokens] of Object.entries(FAUCET_TOKENS_BY_CHAIN)) {
    describe(`chain ${chainIdStr}`, () => {
      it("lists exactly 3 stables (matching the live V2 Registry token count)", () => {
        expect(tokens).toHaveLength(3);
      });

      it("symbols are unique and cover USDC/USDT/EURC", () => {
        const set = new Set(tokens.map((t) => t.symbol));
        expect(set.size).toBe(tokens.length);
        expect([...set].sort()).toEqual(["EURC", "USDC", "USDT"]);
      });

      it("addresses are unique and EIP-55 valid", () => {
        const addrs = tokens.map((t) => t.address);
        expect(new Set(addrs).size).toBe(addrs.length);
        for (const t of tokens) {
          expect(isAddress(t.address, { strict: true })).toBe(true);
        }
      });

      it("decimals are either 6 or 18 (matches deploy)", () => {
        for (const t of tokens) {
          expect([6, 18]).toContain(t.decimals);
        }
      });

      it("amounts are positive bigints", () => {
        for (const t of tokens) {
          expect(typeof t.amount).toBe("bigint");
          expect(t.amount).toBeGreaterThan(0n);
        }
      });

      it("USDC/USDT mint ≈ $1000 (pegged USD ⇒ 1000 units)", () => {
        const pegged = tokens.filter((t) => ["USDC", "USDT"].includes(t.symbol));
        expect(pegged).toHaveLength(2);
        for (const t of pegged) {
          expect(t.amount).toBe(1_000n);
        }
      });
    });
  }

  it("addresses never collide across chains (flat lookups elsewhere assume this)", () => {
    const all = Object.values(FAUCET_TOKENS_BY_CHAIN).flatMap((ts) =>
      ts.map((t) => t.address),
    );
    expect(new Set(all).size).toBe(all.length);
  });

  it("Base Sepolia addresses match the live 84532 V2 token set", () => {
    const bySymbol = Object.fromEntries(
      FAUCET_TOKENS_BY_CHAIN[BASE_SEPOLIA_CHAIN_ID]!.map((t) => [t.symbol, t.address]),
    );
    expect(bySymbol).toEqual({
      USDC: "0x3a98d8adC295d90171e9DA93D411dEa95674c867",
      USDT: "0x7110315D229C7CE655399703ACbA8E67f1d5C0c0",
      EURC: "0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7",
    });
  });

  it("Arc testnet addresses match the live 5042002 V2 token set", () => {
    const bySymbol = Object.fromEntries(
      FAUCET_TOKENS_BY_CHAIN[ARC_TESTNET_CHAIN_ID]!.map((t) => [t.symbol, t.address]),
    );
    expect(bySymbol).toEqual({
      USDC: "0x168655bc42265d8721AD6BCe20435919A0160B79",
      USDT: "0xD05FE3e0A38508b182143E1eBf69C657a87cBe22",
      EURC: "0xb1D82C6ba72CfE115Baa0Cd33De78224D9370Eea",
    });
  });
});

describe("faucetTokensFor", () => {
  it("returns the chain's token set for supported ids", () => {
    expect(faucetTokensFor(BASE_SEPOLIA_CHAIN_ID)).toBe(
      FAUCET_TOKENS_BY_CHAIN[BASE_SEPOLIA_CHAIN_ID],
    );
    expect(faucetTokensFor(ARC_TESTNET_CHAIN_ID)).toBe(
      FAUCET_TOKENS_BY_CHAIN[ARC_TESTNET_CHAIN_ID],
    );
  });

  it("returns undefined for unsupported / missing ids", () => {
    expect(faucetTokensFor(1)).toBeUndefined();
    expect(faucetTokensFor(11155111)).toBeUndefined();
    expect(faucetTokensFor(undefined)).toBeUndefined();
  });
});

describe("FAUCET_TOKENS (back-compat flat export)", () => {
  it("is the default-chain (Base Sepolia) set", () => {
    expect(FAUCET_TOKENS).toBe(FAUCET_TOKENS_BY_CHAIN[BASE_SEPOLIA_CHAIN_ID]);
  });
});
