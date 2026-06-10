import { parseAbi } from "viem";

export const poolAbiV2 = parseAbi([
  // ── V2 views ──
  "function reserveHealth(address token) view returns (uint256 healthBps)",
  "function maxSwapOut(address tokenOut) view returns (uint256 netOut, uint256 grossUsd1e18)",
  "function maxWithdraw(address tokenOut, address account) view returns (uint256 lpAmount, uint256 netOut)",
  "function quoteSwapV2(address tokenIn, address tokenOut, uint256 amountIn) view returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps)",
  "function quoteWithdrawV2(address tokenOut, uint256 lpAmount) view returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps)",
  "function reserves(address token) view returns (uint256)",
  "function protocolFeesAccrued(address token) view returns (uint256)",
  "function totalReservesUSD() view returns (uint256)",
  "function protocolFeeShareBps() view returns (uint16)",
  "function paused() view returns (bool)",
  "function pauseGuardian() view returns (address)",
  "function LP() view returns (address)",
  "function REGISTRY() view returns (address)",
  // ── writes ──
  "function deposit(address token, uint256 amount, uint256 minLpOut, uint256 deadline) returns (uint256 lpMinted)",
  "function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline, address recipient) returns (uint256 amountOut)",
  "function withdrawSingle(address tokenOut, uint256 lpAmount, uint256 minTokenOut, uint256 deadline) returns (uint256 amountOut)",
  "function withdrawProportional(uint256 lpAmount, uint256 deadline) returns (uint256[] amounts)",
  // ── events ──
  "event Deposited(address indexed user, address indexed token, uint256 amountIn, uint256 lpMinted, uint256 navBefore1e18, uint256 navAfter1e18)",
  "event Swapped(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 feeUsd1e18, uint256 protocolFeeAmtOut, address recipient)",
  "event WithdrewSingle(address indexed user, address indexed tokenOut, uint256 lpBurned, uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18)",
  "event WithdrewProportional(address indexed user, uint256 lpBurned)",
  // ── V2 custom errors (for typed revert decoding via parseContractErrorV2) ──
  "error ZeroAmount()",
  "error ZeroAddress()",
  "error SameToken(address token)",
  "error DeadlinePassed()",
  "error PoolPaused()",
  "error TokenNotActive(address token)",
  "error OracleUnsafe(address token)",
  "error InsufficientOutput(uint256 actual, uint256 minOut)",
  "error InsufficientLpOut(uint256 actual, uint256 minLpOut)",
  "error InsufficientTokenOut(uint256 actual, uint256 minTokenOut)",
  "error InsufficientLiquidity(address token, uint256 requested, uint256 available)",
  "error ReserveFloorBreached(address token)",
  "error DepositCapExceeded(address token)",
  "error FirstDepositTooSmall(uint256 usdValue, uint256 minimumLiquidity)",
  "error EarlyWithdraw(uint256 unlockAt, uint256 nowAt)",
]);
