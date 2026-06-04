import { describe, it, expect } from "vitest";
import {
  ArcoraDexError,
  SlippageExceededError,
  InsufficientLiquidityError,
  PoolPausedError,
  EarlyWithdrawError,
  OracleStaleError,
  SameTokenError,
  ZeroAmountError,
  TokenNotActiveError,
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

  // H-3 (audit 2026-05-24): oracle revert paths map to OracleStaleError.
  // G-5 (audit 2026-05-31): InvalidOracleTimestamp / InvalidOracleRound were
  // removed from the contract; only NoValidPrice remains.
  it("maps NoValidPrice revert to OracleStaleError with reason=NoValidPrice", () => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "NoValidPrice", args: ["0xtok"] },
    };
    const out = parseContractError(fakeViemErr);
    expect(out).toBeInstanceOf(OracleStaleError);
    if (out instanceof OracleStaleError) {
      expect(out.token).toBe("0xtok");
      expect(out.reason).toBe("NoValidPrice");
    }
  });

  // G-5 (audit 2026-05-31): the removed oracle selectors no longer map to a
  // typed class — they fall through to the generic ArcoraDexError.
  it.each(["InvalidOracleTimestamp", "InvalidOracleRound"] as const)(
    "no longer maps removed oracle selector %s to OracleStaleError",
    (selector) => {
      const fakeViemErr = {
        name: "ContractFunctionRevertedError",
        data: { errorName: selector, args: ["0xtok", 0n, 0n] },
      };
      const out = parseContractError(fakeViemErr);
      expect(out).not.toBeInstanceOf(OracleStaleError);
      expect(out).toBeInstanceOf(ArcoraDexError);
      expect(out.message).toContain(selector);
    },
  );

  // L-1 (audit 2026-05-31): SameToken / ZeroAmount now map to typed classes.
  it("decodes SameToken → SameTokenError with the token field", () => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "SameToken", args: ["0xtok"] },
    };
    const out = parseContractError(fakeViemErr);
    expect(out).toBeInstanceOf(SameTokenError);
    if (out instanceof SameTokenError) {
      expect(out.token).toBe("0xtok");
    }
  });

  it("decodes ZeroAmount → ZeroAmountError (no args)", () => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "ZeroAmount", args: [] },
    };
    expect(parseContractError(fakeViemErr)).toBeInstanceOf(ZeroAmountError);
  });
});

// L-1 (audit 2026-05-31): a quote read that reverts must surface a typed
// ArcoraDexError, not a raw viem error. The quote actions wrap readContract in
// parseContractError; here we drive that wrapper directly with a stub client
// whose publicClient.readContract throws the viem-shaped revert.
describe("quote actions surface typed errors on revert (L-1)", () => {
  it("quoteSwap maps a SameToken revert to SameTokenError", async () => {
    const { quoteSwap } = await import("@/actions/quoteSwap");
    const stub = {
      addresses: { pool: "0xpool" },
      publicClient: {
        readContract: async () => {
          throw {
            name: "ContractFunctionExecutionError",
            cause: {
              name: "ContractFunctionRevertedError",
              data: { errorName: "SameToken", args: ["0xtok"] },
            },
          };
        },
      },
    } as never;
    await expect(
      quoteSwap(stub, { tokenIn: "0xtok", tokenOut: "0xtok", amountIn: 1n }),
    ).rejects.toBeInstanceOf(SameTokenError);
  });

  it("quoteDeposit maps a TokenNotActive revert to TokenNotActiveError", async () => {
    const { quoteDeposit } = await import("@/actions/quoteDeposit");
    const stub = {
      addresses: { pool: "0xpool" },
      publicClient: {
        readContract: async () => {
          throw {
            name: "ContractFunctionExecutionError",
            cause: {
              name: "ContractFunctionRevertedError",
              data: { errorName: "TokenNotActive", args: ["0xtok"] },
            },
          };
        },
      },
    } as never;
    await expect(
      quoteDeposit(stub, { token: "0xtok", amount: 1n }),
    ).rejects.toBeInstanceOf(TokenNotActiveError);
  });
});
