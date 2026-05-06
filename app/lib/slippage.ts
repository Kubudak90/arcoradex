/**
 * Convert a quoted output amount + slippage tolerance (in bps) into a `minOut`.
 * Example: minOut(1_000_000n, 50) where 50 bps = 0.5% → 995_000n.
 */
export function minOut(quoted: bigint, slippageBps: number): bigint {
  if (slippageBps <= 0) return quoted;
  if (slippageBps >= 10_000) return 0n;
  // (10_000 - slippageBps) / 10_000
  return (quoted * BigInt(10_000 - slippageBps)) / 10_000n;
}

export function deadline(secondsFromNow = 20 * 60): bigint {
  return BigInt(Math.floor(Date.now() / 1000) + secondsFromNow);
}
