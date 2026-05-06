import { describe, it, expect, inject } from "vitest";
import { http } from "viem";
import { createArcoraDex, arcTestnet } from "@";

const sdk = () =>
  createArcoraDex({
    chain: arcTestnet,
    transport: http(inject("anvilRpcUrl")),
    addresses: inject("deployed"),
  });

const usdc = () => inject("deployed").tokens.find((t) => t.symbol === "USDC")!.address;
const eurc = () => inject("deployed").tokens.find((t) => t.symbol === "EURC")!.address;

describe("read actions", () => {
  it("getPoolStats returns the seeded NAV (~$70k minus 1000-wei MIN_LIQUIDITY)", async () => {
    const stats = await sdk().getPoolStats();
    expect(stats.navUsd1e18).toBeGreaterThan(69_900n * 10n ** 18n);
    expect(stats.navUsd1e18).toBeLessThan(70_100n * 10n ** 18n);
    expect(stats.swapFeeBps).toBe(30);
    expect(stats.protocolFeeShareBps).toBe(1000);
    expect(stats.paused).toBe(false);
  });

  it("getTokens returns 7 stables, all active", async () => {
    const tokens = await sdk().getTokens();
    expect(tokens.length).toBe(7);
    expect(tokens.every((t) => t.isActive)).toBe(true);
    expect(new Set(tokens.map((t) => t.symbol))).toEqual(
      new Set(["USDC", "USDT", "PYUSD", "DAI", "EURC", "TRYC", "BRLC"]),
    );
  });

  it("quoteSwap USDC→EURC: 100 USDC → ~92.31 EURC after 30 bps fee", async () => {
    const out = await sdk().quoteSwap({
      tokenIn: usdc(),
      tokenOut: eurc(),
      amountIn: 100_000_000n,
    });
    expect(out).toBeGreaterThan(92_000_000n);
    expect(out).toBeLessThan(93_000_000n);
  });

  it("getReserves returns positive reserves for every seeded token", async () => {
    const r = await sdk().getReserves();
    for (const t of inject("deployed").tokens) {
      expect(r[t.address]).toBeGreaterThan(0n);
    }
  });

  it("getPosition for the deployer reflects ~all the LP supply", async () => {
    const deployerAddr = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as const;
    const pos = await sdk().getPosition(deployerAddr);
    expect(pos.lpBalance).toBeGreaterThan(0n);
    expect(pos.sharePct).toBeGreaterThan(0.99);
  });

  it("getProtocolFees is zero for a freshly-deployed token", async () => {
    expect(await sdk().getProtocolFees(usdc())).toBe(0n);
  });
});
