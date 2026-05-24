import { describe, it, expect } from "vitest";
import {
  ArcoraDexError,
  SlippageExceededError,
  InsufficientLiquidityError,
  PoolPausedError,
  EarlyWithdrawError,
  OracleStaleError,
  parseContractError,
} from "@/errors";

describe("ArcoraDexError hierarchy", () => {
  it("SlippageExceededError exposes typed fields", () => {
    const e = new SlippageExceededError(100n, 200n);
    expect(e).toBeInstanceOf(ArcoraDexError);
    expect(e.actual).toBe(100n);
    expect(e.minOut).toBe(200n);
    expect(e.message).toContain("slippage");
  });
  it("PoolPausedError has no extra fields", () => {
    const e = new PoolPausedError();
    expect(e).toBeInstanceOf(ArcoraDexError);
    expect(e.message).toContain("paused");
  });
});

describe("parseContractError", () => {
  it("decodes a fake ContractFunctionRevertedError into the typed class", () => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "InsufficientOutput", args: [100n, 200n] },
    };
    const out = parseContractError(fakeViemErr);
    expect(out).toBeInstanceOf(SlippageExceededError);
    if (out instanceof SlippageExceededError) {
      expect(out.actual).toBe(100n);
      expect(out.minOut).toBe(200n);
    }
  });

  it("falls back to ArcoraDexError for unknown selectors", () => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "UnknownErrorSig", args: [] },
    };
    const out = parseContractError(fakeViemErr);
    expect(out).toBeInstanceOf(ArcoraDexError);
    expect(out).not.toBeInstanceOf(SlippageExceededError);
  });

  it("recognizes PoolPaused with no args", () => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "PoolPaused", args: [] },
    };
    expect(parseContractError(fakeViemErr)).toBeInstanceOf(PoolPausedError);
  });

  it("recognizes InsufficientLiquidity with named fields", () => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "InsufficientLiquidity", args: ["0xabc", 5n, 1n] },
    };
    const out = parseContractError(fakeViemErr);
    expect(out).toBeInstanceOf(InsufficientLiquidityError);
    if (out instanceof InsufficientLiquidityError) {
      expect(out.token).toBe("0xabc");
      expect(out.requested).toBe(5n);
      expect(out.available).toBe(1n);
    }
  });

  // H-2 (audit 2026-05-24): EarlyWithdrawError must be reachable via instanceof.
  it("recognizes EarlyWithdraw and surfaces it as EarlyWithdrawError", () => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "EarlyWithdraw", args: [1_700_000_000n, 1_700_000_500n] },
    };
    const out = parseContractError(fakeViemErr);
    expect(out).toBeInstanceOf(EarlyWithdrawError);
    if (out instanceof EarlyWithdrawError) {
      expect(out.unlockAt).toBe(1_700_000_000n);
      expect(out.nowAt).toBe(1_700_000_500n);
    }
  });

  // H-3 (audit 2026-05-24): three oracle revert paths all map to OracleStaleError
  // with `reason` distinguishing them. Previously fell through to generic ArcoraDexError.
  it.each([
    ["InvalidOracleTimestamp", ["0xtok", 0n]],
    ["InvalidOracleRound", ["0xtok", 0n, 0n]],
    ["NoValidPrice", ["0xtok"]],
  ] as const)("maps %s revert to OracleStaleError with reason=%s", (selector, args) => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: selector, args },
    };
    const out = parseContractError(fakeViemErr);
    expect(out).toBeInstanceOf(OracleStaleError);
    if (out instanceof OracleStaleError) {
      expect(out.token).toBe("0xtok");
      expect(out.reason).toBe(selector);
    }
  });
});
