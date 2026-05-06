import { formatUnits, parseUnits } from "viem";

export function fmtUnits(value: bigint, decimals: number, displayDecimals = 4): string {
  const s = formatUnits(value, decimals);
  // Trim to displayDecimals, then drop trailing zeros after the dot.
  const [intP, fracP = ""] = s.split(".");
  if (!fracP) return intP;
  const trimmed = fracP.slice(0, displayDecimals).replace(/0+$/, "");
  return trimmed.length ? `${intP}.${trimmed}` : intP;
}

export function fmtUSD(value1e18: bigint, displayDecimals = 2): string {
  const s = formatUnits(value1e18, 18);
  const [intP, fracP = ""] = s.split(".");
  const trimmed = fracP.slice(0, displayDecimals).padEnd(displayDecimals, "0");
  // Add thousands separators
  const intWithCommas = intP.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `$${intWithCommas}.${trimmed}`;
}

export function tryParseUnits(value: string, decimals: number): bigint | null {
  if (!value || value === "." || isNaN(Number(value))) return null;
  try {
    return parseUnits(value as `${number}`, decimals);
  } catch {
    return null;
  }
}
