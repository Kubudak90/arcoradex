export function minOut(quoted: bigint, slippageBps: number): bigint {
  if (slippageBps <= 0) return quoted;
  if (slippageBps >= 10_000) return 0n;
  return (quoted * BigInt(10_000 - slippageBps)) / 10_000n;
}

export function deadline(secondsFromNow = 20 * 60): bigint {
  return BigInt(Math.floor(Date.now() / 1000) + secondsFromNow);
}
