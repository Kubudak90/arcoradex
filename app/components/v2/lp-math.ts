/**
 * Pure LP / deposit-cap math shared by LiquidityPageV2 (and unit-tested).
 *
 * Kept side-effect-free so the GF-3 share math and GF-4 cap-headroom math can be
 * verified without rendering. All `*Usd1e18` values are 1e18-scaled USD.
 */

/** rawReserve × price1e18 / 10^decimals → reserve USD value (1e18-scaled). */
export function reserveUsd1e18(raw: bigint, decimals: number, price1e18: bigint): bigint {
  return (raw * price1e18) / 10n ** BigInt(decimals);
}

/** GF-3: pool share = balance / lpSupply, as a fraction in [0,1]. */
export function poolShare(balance: bigint, lpSupply: bigint): number {
  if (lpSupply === 0n) return 0;
  return Number(balance) / Number(lpSupply);
}

/** GF-3: LP position USD value = lpPriceUsd1e18 × balance / 1e18 (1e18-scaled). */
export function lpValueUsd1e18(lpPriceUsd1e18: bigint, balance: bigint): bigint {
  return (lpPriceUsd1e18 * balance) / 10n ** 18n;
}

export interface CapHeadroom {
  capUsd1e18: bigint;
  currentUsd1e18: bigint;
  headroomUsd1e18: bigint;
  /** Headroom is exhausted — deposits are blocked. */
  reached: boolean;
}

/**
 * GF-4: remaining deposit-cap headroom = depositCapUsd − current reserve USD.
 * A cap of 0 means "uncapped" (no GF-4 row) and returns null.
 */
export function depositCapHeadroom(
  depositCapUsd1e18: bigint,
  currentReserveUsd1e18: bigint,
): CapHeadroom | null {
  if (depositCapUsd1e18 === 0n) return null;
  const headroomUsd1e18 = depositCapUsd1e18 - currentReserveUsd1e18;
  return {
    capUsd1e18: depositCapUsd1e18,
    currentUsd1e18: currentReserveUsd1e18,
    headroomUsd1e18,
    reached: headroomUsd1e18 <= 0n,
  };
}

/** GF-4: would this deposit (USD) exceed the remaining headroom? */
export function exceedsCap(depositUsd1e18: bigint, headroom: CapHeadroom | null): boolean {
  if (headroom == null) return false;
  return depositUsd1e18 > 0n && depositUsd1e18 > headroom.headroomUsd1e18;
}
