import { describe, expect, it } from "vitest";
import { createPublicClient, http } from "viem";
import { createArcoraDexV2 } from "../../../src/clientV2";
import { baseSepolia } from "../../../src/chains/baseSepolia";
import { DEFAULT_ADDRESSES_V2 } from "../../../src/addresses.v2";
import { poolAbiV2 } from "../../../src/abi/v2/pool";

const RPC = process.env.BASE_SEPOLIA_RPC;

// Skips cleanly when no RPC is provided (default CI), mirroring the V1
// addresses-live test's SKIP_LIVE_TESTS gate. Run with:
//   BASE_SEPOLIA_RPC=https://base-sepolia-rpc.publicnode.com pnpm --filter @arcoralabs/dex-sdk test addresses-live-v2
describe.skipIf(!RPC)("V2 Base Sepolia defaults are live (84532)", () => {
  it("pool is unpaused and registry lists 3 tokens", async () => {
    const pub = createPublicClient({ chain: baseSepolia, transport: http(RPC) });
    const { pool } = DEFAULT_ADDRESSES_V2[baseSepolia.id]!;
    const paused = await pub.readContract({ address: pool, abi: poolAbiV2, functionName: "paused" });
    expect(paused).toBe(false);

    const sdk = createArcoraDexV2({ chain: baseSepolia, transport: http(RPC) });
    const tokens = await sdk.getTokens();
    expect(tokens.length).toBe(3);
    expect(tokens.map((t) => t.symbol).sort()).toEqual(["EURC", "USDC", "USDT"]);
  }, 30_000);

  it("quoteSwapV2 USDC→EURC returns a 4-field quote with sane health", async () => {
    const sdk = createArcoraDexV2({ chain: baseSepolia, transport: http(RPC) });
    const { USDC, EURC } = {
      USDC: "0x3a98d8adC295d90171e9DA93D411dEa95674c867" as const,
      EURC: "0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7" as const,
    };
    // NOTE: a live quote requires a fresh Pyth pull (keeper) — if the adapter is
    // stale this throws OracleUnsafeError, which is itself a valid §11 assertion.
    // Keep amountIn small relative to reserves so it stays in the healthiest band.
    const q = await sdk.quoteSwapV2({ tokenIn: USDC, tokenOut: EURC, amountIn: 1_000_000n }); // 1 USDC (6dp)
    expect(q.amountOut).toBeGreaterThan(0n);
    expect(q.postHealthBps).toBeGreaterThanOrEqual(0);
    expect(q.postHealthBps).toBeLessThanOrEqual(10000);
  }, 30_000);

  it("reserveHealth(EURC) is within 0..10000 bps", async () => {
    const sdk = createArcoraDexV2({ chain: baseSepolia, transport: http(RPC) });
    const { healthBps } = await sdk.reserveHealth("0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7");
    expect(healthBps).toBeGreaterThanOrEqual(0);
    expect(healthBps).toBeLessThanOrEqual(10000);
  }, 30_000);
});
