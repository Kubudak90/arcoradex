export class ArcoraDexError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ArcoraDexError";
  }
}

export class MissingAccountError extends ArcoraDexError {
  constructor() {
    super("Missing account: this method requires a viem account on the SDK client.");
    this.name = "MissingAccountError";
  }
}

export class InsufficientBalanceError extends ArcoraDexError {
  constructor(
    public readonly token: `0x${string}`,
    public readonly balance: bigint,
    public readonly required: bigint,
  ) {
    super(`Insufficient balance of ${token}: have ${balance}, need ${required}`);
    this.name = "InsufficientBalanceError";
  }
}

export class InsufficientLiquidityError extends ArcoraDexError {
  constructor(
    public readonly token: `0x${string}`,
    public readonly requested: bigint,
    public readonly available: bigint,
  ) {
    super(`Insufficient pool liquidity for ${token}: requested ${requested}, available ${available}`);
    this.name = "InsufficientLiquidityError";
  }
}

export class FirstDepositTooSmallError extends ArcoraDexError {
  constructor(public readonly usd: bigint, public readonly minimum: bigint) {
    super(`First deposit too small: ${usd} <= MINIMUM_LIQUIDITY (${minimum})`);
    this.name = "FirstDepositTooSmallError";
  }
}

export class SlippageExceededError extends ArcoraDexError {
  constructor(public readonly actual: bigint, public readonly minOut: bigint) {
    super(`slippage: actual ${actual} below minOut ${minOut}`);
    this.name = "SlippageExceededError";
  }
}

/**
 * The pool's oracle path rejected a read for `token`. Surfaced for any of:
 * - `InvalidOracleTimestamp` (Chainlink `updatedAt` is zero or beyond `maxStaleSeconds`)
 * - `InvalidOracleRound` (`answeredInRound < roundId`, or roundId is zero)
 * - `NoValidPrice` (no fresh read AND no usable cached fallback)
 *
 * `reason` carries the underlying selector name so callers can distinguish
 * the three sub-cases without needing extra error classes.
 */
export class OracleStaleError extends ArcoraDexError {
  constructor(
    public readonly token: `0x${string}`,
    public readonly reason:
      | "InvalidOracleTimestamp"
      | "InvalidOracleRound"
      | "NoValidPrice" = "NoValidPrice",
  ) {
    super(`Oracle read rejected for ${token} (${reason})`);
    this.name = "OracleStaleError";
  }
}

export class OracleDeviationError extends ArcoraDexError {
  constructor(
    public readonly token: `0x${string}`,
    public readonly newPrice: bigint,
    public readonly prev: bigint,
    public readonly maxDevBps: number,
  ) {
    super(`Oracle deviation for ${token}: ${newPrice} vs prev ${prev} exceeds ${maxDevBps} bps`);
    this.name = "OracleDeviationError";
  }
}

export class PoolPausedError extends ArcoraDexError {
  constructor() {
    super("Pool is paused.");
    this.name = "PoolPausedError";
  }
}

export class TokenNotActiveError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`) {
    super(`Token ${token} is not active in the registry.`);
    this.name = "TokenNotActiveError";
  }
}

export class DeadlinePassedError extends ArcoraDexError {
  constructor() {
    super("Transaction deadline already passed.");
    this.name = "DeadlinePassedError";
  }
}

export class EarlyWithdrawError extends ArcoraDexError {
  constructor(public readonly unlockAt: bigint, public readonly nowAt: bigint) {
    super(`LP min-hold active until ${unlockAt} (now ${nowAt})`);
    this.name = "EarlyWithdrawError";
  }
}

interface RevertedShape {
  data?: { errorName?: string; args?: readonly unknown[] };
  cause?: RevertedShape;
}

/**
 * Walk the error's cause chain looking for a node that has
 * `data.errorName` — that's the ContractFunctionRevertedError viem
 * produces.  When writeContract throws a live revert it wraps the
 * ContractFunctionRevertedError inside a ContractFunctionExecutionError,
 * so we must recurse through `.cause` until we find the payload.
 */
function extractRevertData(
  err: unknown,
  depth = 0,
): { errorName: string | undefined; args: readonly unknown[] } {
  if (depth > 5 || err == null) return { errorName: undefined, args: [] };
  const r = err as RevertedShape;
  if (r?.data?.errorName != null) {
    return { errorName: r.data.errorName, args: r.data.args ?? [] };
  }
  return extractRevertData(r?.cause, depth + 1);
}

export function parseContractError(err: unknown): ArcoraDexError {
  const { errorName: name, args: rawArgs } = extractRevertData(err);
  const args = rawArgs as readonly unknown[];

  switch (name) {
    case "InsufficientOutput":
    case "InsufficientLpOut":
    case "InsufficientTokenOut":
      return new SlippageExceededError(args[0] as bigint, args[1] as bigint);
    case "InsufficientLiquidity":
      return new InsufficientLiquidityError(
        args[0] as `0x${string}`,
        args[1] as bigint,
        args[2] as bigint,
      );
    case "FirstDepositTooSmall":
      return new FirstDepositTooSmallError(args[0] as bigint, args[1] as bigint);
    case "PoolPaused":
      return new PoolPausedError();
    case "TokenNotActive":
      return new TokenNotActiveError(args[0] as `0x${string}`);
    case "DeadlinePassed":
      return new DeadlinePassedError();
    case "EarlyWithdraw":
      return new EarlyWithdrawError(args[0] as bigint, args[1] as bigint);
    case "PriceDeviation":
      return new OracleDeviationError(
        args[0] as `0x${string}`,
        args[1] as bigint,
        args[2] as bigint,
        Number(args[3]),
      );
    // H-3 / H-1 (audit 2026-05-24): map all three oracle-rejection reverts to
    // OracleStaleError so consumers can `catch (e) { if (e instanceof OracleStaleError) }`
    // and inspect `.reason` to tell them apart.
    case "InvalidOracleTimestamp":
      return new OracleStaleError(args[0] as `0x${string}`, "InvalidOracleTimestamp");
    case "InvalidOracleRound":
      return new OracleStaleError(args[0] as `0x${string}`, "InvalidOracleRound");
    case "NoValidPrice":
      return new OracleStaleError(args[0] as `0x${string}`, "NoValidPrice");
    default:
      return new ArcoraDexError(`Contract reverted: ${name ?? "unknown"}`);
  }
}
