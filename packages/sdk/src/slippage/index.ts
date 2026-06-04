export function minOut(quoted: bigint, slippageBps: number): bigint {
  if (slippageBps <= 0) return quoted;
  // I-10 (audit 2026-05-31): a slippage tolerance >= 100% (10000 bps) used to
  // silently return 0n, which DISABLES slippage protection (any output, even
  // near-zero, is accepted) — exactly what a sandwich/MEV bot wants. Reject it
  // loudly instead so callers cannot accidentally opt out of protection.
  if (slippageBps >= 10_000) throw new RangeError("slippageBps must be < 10000");
  return (quoted * BigInt(10_000 - slippageBps)) / 10_000n;
}

export function deadline(secondsFromNow = 20 * 60): bigint {
  return BigInt(Math.floor(Date.now() / 1000) + secondsFromNow);
}
