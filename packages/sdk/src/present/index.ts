import type { FeeBand } from "../types.v2";

/** The spec §7 initial fee schedule as marginal bands (health bps → fee bps). */
export const INITIAL_FEE_SCHEDULE = [
  { fromBps: 7500, toBps: 10000, feeBps: 5 },   // 75%-100%  → 0.05%
  { fromBps: 5000, toBps: 7500,  feeBps: 20 },  // 50%-75%   → 0.20%
  { fromBps: 2500, toBps: 5000,  feeBps: 75 },  // 25%-50%   → 0.75%
  { fromBps: 0,    toBps: 2500,  feeBps: 300 }, // 0%-25%    → 3.00%
] as const;

export type HealthBand = "75-100" | "50-75" | "25-50" | "0-25";

/** Map a reserve-health bps value to the §7 band it sits in. */
export function healthBand(healthBps: number): HealthBand {
  if (healthBps >= 7500) return "75-100";
  if (healthBps >= 5000) return "50-75";
  if (healthBps >= 2500) return "25-50";
  return "0-25";
}

export type HealthLabel = "Healthy" | "Caution" | "Low" | "Critical";

export function healthLabel(healthBps: number): HealthLabel {
  switch (healthBand(healthBps)) {
    case "75-100": return "Healthy";
    case "50-75":  return "Caution";
    case "25-50":  return "Low";
    default:       return "Critical";
  }
}

/**
 * Read a token's marginal fee bands FROM its on-chain TokenConfigV2 (preferred
 * over the static schedule — the registry is the source of truth). Returns the
 * bands sorted healthiest-first for display.
 */
export function feeBandsForToken(bands: FeeBand[]): FeeBand[] {
  return [...bands].sort((a, b) => b.upperHealthBps - a.upperHealthBps);
}

/** Estimated dynamic fee as a percentage: feeUsd1e18 / grossUsd1e18 * 100. */
export function estimatedFeePct(feeUsd1e18: bigint, grossUsd1e18: bigint): number {
  if (grossUsd1e18 === 0n) return 0;
  // bps with 1e4 precision, then → percent.
  const bps = Number((feeUsd1e18 * 1_000_000n) / grossUsd1e18) / 100;
  return bps / 100;
}

export interface MaxGuardResult { amount: bigint; clamped: boolean; overMax: boolean }

/** §9: clamp an entered amount to the floor-safe max; flag when it was over. */
export function applyMaxGuard(entered: bigint, max: bigint): MaxGuardResult {
  if (entered > max) return { amount: max, clamped: true, overMax: true };
  return { amount: entered, clamped: false, overMax: false };
}
