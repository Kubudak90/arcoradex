import type { Hash, TransactionReceipt } from "viem";

export interface SwappedEvent {
  user: `0x${string}`;
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  amountIn: bigint;
  amountOut: bigint;
  lpFeeUsd1e18: bigint;
  protocolFeeAmtOut: bigint;
  recipient: `0x${string}`;
  blockNumber: bigint;
  txHash: Hash;
  logIndex: number;
}

export interface DepositedEvent {
  user: `0x${string}`;
  token: `0x${string}`;
  amountIn: bigint;
  lpMinted: bigint;
  navBefore1e18: bigint;
  navAfter1e18: bigint;
  blockNumber: bigint;
  txHash: Hash;
  logIndex: number;
}

export interface WithdrewEvent {
  user: `0x${string}`;
  tokenOut: `0x${string}`;
  lpBurned: bigint;
  amountOut: bigint;
  protocolFee: bigint;
  navBefore1e18: bigint;
  navAfter1e18: bigint;
  blockNumber: bigint;
  txHash: Hash;
  logIndex: number;
}

export interface SwapResult {
  approveHash?: Hash;
  hash: Hash;
  receipt: TransactionReceipt;
  amountOut: bigint;
  event: SwappedEvent;
}

export interface DepositResult {
  approveHash?: Hash;
  hash: Hash;
  receipt: TransactionReceipt;
  lpMinted: bigint;
  event: DepositedEvent;
}

export interface WithdrawResult {
  hash: Hash;
  receipt: TransactionReceipt;
  amountOut: bigint;
  event: WithdrewEvent;
}

export interface PoolStats {
  navUsd1e18: bigint;
  lpSupply: bigint;
  lpPriceUsd1e18: bigint;
  swapFeeBps: number;
  protocolFeeShareBps: number;
  paused: boolean;
}

export interface TokenInfo {
  address: `0x${string}`;
  symbol: string;
  name: string;
  decimals: number;
  isActive: boolean;
  oracle: `0x${string}`;
  maxOracleDeviationBps: number;
  /**
   * I-8 (audit 2026-05-31): per-token Chainlink freshness window (seconds). A
   * read whose `updatedAt` is older than this is rejected as stale. Mirrors the
   * on-chain `Registry.TokenInfo.maxStaleSeconds` (uint32).
   */
  maxStaleSeconds: number;
}

export interface UserPosition {
  lpBalance: bigint;
  usdValue1e18: bigint;
  sharePct: number;
}
