import { parseAbi } from "viem";

export const poolAbi = parseAbi([
  "function deposit(address token, uint256 amount, uint256 minLpOut, uint256 deadline) returns (uint256)",
  "function withdraw(address tokenOut, uint256 lpAmount, uint256 minTokenOut, uint256 deadline) returns (uint256)",
  "function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline, address recipient) returns (uint256)",
  "function quote(address tokenIn, address tokenOut, uint256 amountIn) view returns (uint256)",
  "function quoteDeposit(address token, uint256 amount) view returns (uint256)",
  "function quoteWithdraw(address tokenOut, uint256 lpAmount) view returns (uint256, uint256)",
  "function reserves(address) view returns (uint256)",
  "function protocolFeesAccrued(address) view returns (uint256)",
  "function totalReservesUSD() view returns (uint256)",
  "function swapFeeBps() view returns (uint16)",
  "function protocolFeeShareBps() view returns (uint16)",
  "function paused() view returns (bool)",
  "function LP() view returns (address)",
  "function REGISTRY() view returns (address)",
  "event Swapped(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 lpFeeUsd1e18, uint256 protocolFeeAmtOut, address recipient)",
  "event Deposited(address indexed user, address indexed token, uint256 amountIn, uint256 lpMinted, uint256 navBefore1e18, uint256 navAfter1e18)",
  "event Withdrew(address indexed user, address indexed tokenOut, uint256 lpBurned, uint256 amountOut, uint256 protocolFee, uint256 navBefore1e18, uint256 navAfter1e18)",
]);
