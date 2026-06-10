import type { Hash, TransactionReceipt } from "viem";

/** The shared §9 quote shape returned by quoteSwapV2 / quoteWithdrawV2. */
export interface QuoteV2 {
  amountOut: bigint;
  protocolFee: bigint;
  /** Total dynamic fee in USD (1e18), summed across the marginal bands crossed (§7). */
  feeUsd1e18: bigint;
  /** Output reserve health AFTER the transaction, in bps (0..10000). */
  postHealthBps: number;
}

export interface ReserveHealth { healthBps: number }
export interface MaxSwapOut { netOut: bigint; grossUsd1e18: bigint }
export interface MaxWithdraw { lpAmount: bigint; netOut: bigint }

/** Mirrors FeeBandMathV2.Band { uint16 upperHealthBps; uint16 rateBps }. */
export interface FeeBand { upperHealthBps: number; rateBps: number }

export interface TokenConfigV2 {
  decimals: number;
  isActive: boolean;
  adapter: `0x${string}`;
  minimumReserveUsd: bigint;
  targetReserveUsd: bigint;
  depositCapUsd: bigint;
  bands: FeeBand[];
}

export interface TokenInfoV2 extends TokenConfigV2 {
  address: `0x${string}`;
  symbol: string;
  name: string;
}

export interface PoolStatsV2 {
  navUsd1e18: bigint;
  lpSupply: bigint;
  lpPriceUsd1e18: bigint;
  protocolFeeShareBps: number;
  paused: boolean;
}

export interface SwappedEventV2 {
  user: `0x${string}`;
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  amountIn: bigint;
  amountOut: bigint;
  feeUsd1e18: bigint;
  protocolFeeAmtOut: bigint;
  recipient: `0x${string}`;
  blockNumber: bigint;
  txHash: Hash;
  logIndex: number;
}

export interface WithdrewSingleEvent {
  user: `0x${string}`;
  tokenOut: `0x${string}`;
  lpBurned: bigint;
  amountOut: bigint;
  protocolFee: bigint;
  feeUsd1e18: bigint;
  blockNumber: bigint;
  txHash: Hash;
  logIndex: number;
}

export interface WithdrewProportionalEvent {
  user: `0x${string}`;
  lpBurned: bigint;
  blockNumber: bigint;
  txHash: Hash;
  logIndex: number;
}

export interface SwapResultV2 { approveHash?: Hash; hash: Hash; receipt: TransactionReceipt; amountOut: bigint; event: SwappedEventV2 }
export interface DepositResultV2 { approveHash?: Hash; hash: Hash; receipt: TransactionReceipt; lpMinted: bigint }
export interface WithdrawSingleResult { hash: Hash; receipt: TransactionReceipt; amountOut: bigint; event: WithdrewSingleEvent }
export interface WithdrawProportionalResult { hash: Hash; receipt: TransactionReceipt; amounts: bigint[]; event: WithdrewProportionalEvent }
