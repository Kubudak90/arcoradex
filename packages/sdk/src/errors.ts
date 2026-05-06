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

export class OracleStaleError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`) {
    super(`Oracle for ${token} is stale (>1h)`);
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

interface RevertedShape {
  data?: { errorName?: string; args?: readonly unknown[] };
}

export function parseContractError(err: unknown): ArcoraDexError {
  const r = err as RevertedShape;
  const name = r?.data?.errorName;
  const args = (r?.data?.args ?? []) as readonly unknown[];

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
    case "PriceDeviation":
      return new OracleDeviationError(
        args[0] as `0x${string}`,
        args[1] as bigint,
        args[2] as bigint,
        Number(args[3]),
      );
    default:
      return new ArcoraDexError(`Contract reverted: ${name ?? "unknown"}`);
  }
}
