import { getAddress } from "viem";
import { KNOWN_TOKENS, type KnownTokenMeta } from "./known";

export function tokenLabel(address: `0x${string}`): KnownTokenMeta {
  // Normalize the 0x prefix to lowercase before EIP-55 checksum conversion
  // so that fully-uppercased inputs like "0X3BFA..." are handled correctly.
  const normalized = `0x${address.slice(2)}` as `0x${string}`;
  let key: `0x${string}`;
  try {
    key = getAddress(normalized);
  } catch {
    return { symbol: address.slice(2, 6).toUpperCase(), name: address };
  }
  const known = KNOWN_TOKENS[key];
  if (known) return known;
  return { symbol: key.slice(2, 6).toUpperCase(), name: key };
}
