import { describe, expect, it } from "vitest";
import {
  SUPPORTED_CHAINS,
  DEFAULT_CHAIN,
  EXPLORERS,
  isSupportedChain,
  chainById,
  explorerFor,
  addNetworkParams,
} from "../chain";

const BASE = 84532;
const ARC = 5042002;

describe("multi-chain config (lib/chain)", () => {
  it("supports exactly Base Sepolia (84532) + Arc testnet (5042002)", () => {
    const ids = SUPPORTED_CHAINS.map((c) => c.id);
    expect(new Set(ids)).toEqual(new Set([BASE, ARC]));
    expect(DEFAULT_CHAIN.id).toBe(BASE);
  });

  it("maps each chain to its own explorer", () => {
    expect(EXPLORERS[BASE]).toBe("https://sepolia.basescan.org");
    expect(EXPLORERS[ARC]).toBe("https://testnet.arcscan.app");
  });

  it("isSupportedChain accepts both V2 chains and rejects others", () => {
    expect(isSupportedChain(BASE)).toBe(true);
    expect(isSupportedChain(ARC)).toBe(true);
    expect(isSupportedChain(1)).toBe(false);
    expect(isSupportedChain(undefined)).toBe(false);
  });

  it("chainById resolves a supported chain and falls back to the default", () => {
    expect(chainById(ARC).id).toBe(ARC);
    expect(chainById(BASE).id).toBe(BASE);
    expect(chainById(999).id).toBe(DEFAULT_CHAIN.id);
    expect(chainById(undefined).id).toBe(DEFAULT_CHAIN.id);
  });

  it("explorerFor returns the active chain's explorer (Base→basescan, Arc→arcscan)", () => {
    expect(explorerFor(BASE)).toContain("sepolia.basescan.org");
    expect(explorerFor(ARC)).toContain("testnet.arcscan.app");
    // Unknown chain falls back to the default chain's explorer.
    expect(explorerFor(999)).toBe(EXPLORERS[DEFAULT_CHAIN.id]);
  });

  it("addNetworkParams builds valid wallet_addEthereumChain params per chain", () => {
    const arc = SUPPORTED_CHAINS.find((c) => c.id === ARC)!;
    const p = addNetworkParams(arc);
    expect(p.chainId).toBe("0x" + ARC.toString(16));
    expect(p.chainName).toBe(arc.name);
    expect(p.nativeCurrency.symbol).toBe("USDC"); // Arc native gas is USDC
    expect(p.rpcUrls[0]).toMatch(/^https:\/\//);
    expect(p.blockExplorerUrls).toEqual(["https://testnet.arcscan.app"]);

    const base = SUPPORTED_CHAINS.find((c) => c.id === BASE)!;
    const pb = addNetworkParams(base);
    expect(pb.chainId).toBe("0x" + BASE.toString(16));
    expect(pb.nativeCurrency.symbol).toBe("ETH");
    expect(pb.blockExplorerUrls).toEqual(["https://sepolia.basescan.org"]);
  });
});
