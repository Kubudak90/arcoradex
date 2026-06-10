import { applyMaxGuard, type MaxGuardResult } from "@arcoralabs/dex-sdk/v2";

/**
 * §9 Max-guard hook — wraps the SDK's `applyMaxGuard(entered, max)` so the
 * swap/withdraw CTAs can gate on the floor-safe maximum.
 *
 * Returns `{ amount, clamped, overMax }`:
 *   - `amount`  — the entered value clamped to `max` (advisory; the contract is
 *                 the final enforcement layer).
 *   - `clamped` — true when the entered value was reduced to `max`.
 *   - `overMax` — true when the entered value exceeded the floor-safe `max`;
 *                 the CTA gates on `!overMax`.
 *
 * When either input is null (no amount typed yet, or the max hasn't loaded), it
 * returns a safe pass-through default so the caller never sees a false over-max.
 */
export function useMaxGuard(entered: bigint | null, max: bigint | null): MaxGuardResult {
  if (entered == null || max == null) {
    return { amount: entered ?? 0n, clamped: false, overMax: false };
  }
  return applyMaxGuard(entered, max);
}
