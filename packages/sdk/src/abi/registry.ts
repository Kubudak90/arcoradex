import { parseAbi } from "viem";

export const registryAbi = parseAbi([
  "struct TokenInfo { uint8 decimals; bool isActive; address usdOracle; uint16 maxOracleDeviationBps; }",
  "function tokens(uint256 i) view returns (address)",
  "function tokensLength() view returns (uint256)",
  "function tokenInfo(address token) view returns (TokenInfo)",
  "function isActive(address token) view returns (bool)",
]);
