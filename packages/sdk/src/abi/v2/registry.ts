import { parseAbi } from "viem";

// Band fields are verbatim from contracts/src/v2/lib/FeeBandMathV2.sol:
//   struct Band { uint16 upperHealthBps; uint16 rateBps; }
export const registryAbiV2 = parseAbi([
  "struct Band { uint16 upperHealthBps; uint16 rateBps; }",
  "struct TokenConfigV2 { uint8 decimals; bool isActive; address adapter; uint256 minimumReserveUsd; uint256 targetReserveUsd; uint256 depositCapUsd; Band[] bands; }",
  "function tokens(uint256 i) view returns (address)",
  "function tokensLength() view returns (uint256)",
  "function tokenConfig(address token) view returns (TokenConfigV2)",
  "function isActive(address token) view returns (bool)",
  "function pool() view returns (address)",
]);
