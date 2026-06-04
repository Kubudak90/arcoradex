import { parseAbi } from "viem";

export const lpAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  // I-9 (audit 2026-05-31): the LP's immutable minter is its pool. Used to
  // anchor-check that a configured `pool` address is the canonical pool before
  // approving spend against it (LP.MINTER() must equal the pool).
  "function MINTER() view returns (address)",
]);
