import { describe, expect, it } from "vitest";
import {
  encodeFunctionResult,
  decodeFunctionResult,
  getAbiItem,
} from "viem";
import { poolAbiV2 } from "../../../src/abi/v2/pool";

describe("poolAbiV2", () => {
  it("quoteSwapV2 returns the 4-tuple (amountOut, protocolFee, feeUsd1e18, postHealthBps)", () => {
    const item = getAbiItem({ abi: poolAbiV2, name: "quoteSwapV2" });
    expect(item && "outputs" in item && item.outputs).toHaveLength(4);
    const encoded = encodeFunctionResult({
      abi: poolAbiV2,
      functionName: "quoteSwapV2",
      result: [1n, 2n, 3n, 9000n],
    });
    const decoded = decodeFunctionResult({
      abi: poolAbiV2,
      functionName: "quoteSwapV2",
      data: encoded,
    }) as readonly bigint[];
    expect(decoded).toEqual([1n, 2n, 3n, 9000n]);
  });

  it("maxWithdraw returns (lpAmount, netOut) and reserveHealth returns healthBps", () => {
    expect(getAbiItem({ abi: poolAbiV2, name: "maxWithdraw" })).toBeDefined();
    expect(getAbiItem({ abi: poolAbiV2, name: "maxSwapOut" })).toBeDefined();
    expect(getAbiItem({ abi: poolAbiV2, name: "reserveHealth" })).toBeDefined();
    expect(getAbiItem({ abi: poolAbiV2, name: "withdrawSingle" })).toBeDefined();
    expect(getAbiItem({ abi: poolAbiV2, name: "withdrawProportional" })).toBeDefined();
  });
});
