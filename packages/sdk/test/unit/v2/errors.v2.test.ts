import { describe, expect, it } from "vitest";
import {
  OracleUnsafeError,
  ReserveFloorBreachedError,
  DepositCapExceededError,
  parseContractErrorV2,
} from "../../../src/errors.v2";
import { SlippageExceededError, PoolPausedError } from "../../../src/errors";

const wrap = (errorName: string, args: readonly unknown[]) => ({ data: { errorName, args } });

describe("parseContractErrorV2", () => {
  it("maps V2-only selectors to typed errors", () => {
    const tok = "0x3a98d8adC295d90171e9DA93D411dEa95674c867" as const;
    expect(parseContractErrorV2(wrap("OracleUnsafe", [tok]))).toBeInstanceOf(OracleUnsafeError);
    expect(parseContractErrorV2(wrap("ReserveFloorBreached", [tok]))).toBeInstanceOf(ReserveFloorBreachedError);
    expect(parseContractErrorV2(wrap("DepositCapExceeded", [tok]))).toBeInstanceOf(DepositCapExceededError);
  });

  it("delegates shared selectors to the V1 table", () => {
    expect(parseContractErrorV2(wrap("InsufficientOutput", [1n, 2n]))).toBeInstanceOf(SlippageExceededError);
    expect(parseContractErrorV2(wrap("PoolPaused", []))).toBeInstanceOf(PoolPausedError);
  });
});
