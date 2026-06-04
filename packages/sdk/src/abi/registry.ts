import { parseAbi } from "viem";

export const registryAbi = parseAbi([
  // I-8 (audit 2026-05-31): field order MUST match the on-chain
  // IArcoraDexRegistry.TokenInfo: {decimals, isActive, usdOracle,
  // maxOracleDeviationBps, maxStaleSeconds}. Omitting maxStaleSeconds caused the
  // tuple decode to drop a field.
  "struct TokenInfo { uint8 decimals; bool isActive; address usdOracle; uint16 maxOracleDeviationBps; uint32 maxStaleSeconds; }",
  "function tokens(uint256 i) view returns (address)",
  "function tokensLength() view returns (uint256)",
  "function tokenInfo(address token) view returns (TokenInfo)",
  "function isActive(address token) view returns (bool)",
]);
