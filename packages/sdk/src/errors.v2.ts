import {
  ArcoraDexError,
  parseContractError,
} from "./errors";

export class OracleUnsafeError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`) {
    super(`Oracle is unsafe for ${token}: this path is unavailable; use proportional withdrawal.`);
    this.name = "OracleUnsafeError";
  }
}

export class ReserveFloorBreachedError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`) {
    super(`Reserve floor breached for ${token}: amount exceeds the floor-safe maximum.`);
    this.name = "ReserveFloorBreachedError";
  }
}

export class DepositCapExceededError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`) {
    super(`Deposit cap exceeded for ${token}.`);
    this.name = "DepositCapExceededError";
  }
}

interface RevertedShape {
  data?: { errorName?: string; args?: readonly unknown[] };
  cause?: RevertedShape;
}

function extractRevertData(err: unknown, depth = 0): { errorName?: string; args: readonly unknown[] } {
  if (depth > 5 || err == null) return { errorName: undefined, args: [] };
  const r = err as RevertedShape;
  if (r?.data?.errorName != null) return { errorName: r.data.errorName, args: r.data.args ?? [] };
  return extractRevertData(r?.cause, depth + 1);
}

export function parseContractErrorV2(err: unknown): ArcoraDexError {
  const { errorName: name, args } = extractRevertData(err);
  switch (name) {
    case "OracleUnsafe":
      return new OracleUnsafeError(args[0] as `0x${string}`);
    case "ReserveFloorBreached":
      return new ReserveFloorBreachedError(args[0] as `0x${string}`);
    case "DepositCapExceeded":
      return new DepositCapExceededError(args[0] as `0x${string}`);
    default:
      // Shared selectors (InsufficientOutput/PoolPaused/TokenNotActive/…) reuse
      // the audited V1 mapping verbatim.
      return parseContractError(err);
  }
}
