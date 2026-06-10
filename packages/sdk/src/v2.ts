export { createArcoraDexV2 } from "./clientV2";
export type { ArcoraDexClientV2, CreateArcoraDexV2Params } from "./clientV2";
export { baseSepolia } from "./chains/baseSepolia";
export { arcTestnet } from "./chains/arcTestnet";
export { DEFAULT_ADDRESSES_V2 } from "./addresses.v2";
export { KNOWN_TOKENS_V2, KNOWN_TOKENS_V2_BY_CHAIN } from "./tokens/known.v2";
export { poolAbiV2 } from "./abi/v2/pool";
export { registryAbiV2 } from "./abi/v2/registry";
// `types.v2.ts` is type-only (interfaces); use `export type *` to satisfy the
// repo's @typescript-eslint/consistent-type-exports rule (the plan's bare
// `export *` trips it — minimal faithful fix, same emitted surface).
export type * from "./types.v2";
export {
  OracleUnsafeError, ReserveFloorBreachedError, DepositCapExceededError, parseContractErrorV2,
} from "./errors.v2";
export { reserveHealth } from "./actions/v2/reserveHealth";
export { maxSwapOut } from "./actions/v2/maxSwapOut";
export { maxWithdraw } from "./actions/v2/maxWithdraw";
export { quoteSwapV2 } from "./actions/v2/quoteSwapV2";
export { quoteWithdrawV2 } from "./actions/v2/quoteWithdrawV2";
export { getTokensV2 } from "./actions/v2/getTokensV2";
export { getPoolStatsV2 } from "./actions/v2/getPoolStatsV2";
export { swapV2, type SwapV2Args } from "./actions/v2/swapV2";
export { depositV2, type DepositV2Args } from "./actions/v2/depositV2";
export { withdrawSingleV2 } from "./actions/v2/withdrawSingleV2";
export { withdrawProportionalV2 } from "./actions/v2/withdrawProportionalV2";
export {
  feeBandsForToken, estimatedFeePct, healthBand, healthLabel, applyMaxGuard, INITIAL_FEE_SCHEDULE,
} from "./present";
export type { HealthBand, HealthLabel, MaxGuardResult } from "./present";
