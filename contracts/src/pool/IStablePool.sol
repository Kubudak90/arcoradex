// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStablePool
/// @notice Singleton oracle-priced shared-vault stablecoin pool.
interface IStablePool {
    event LiquidityDeposited(address indexed token, uint256 amount, uint256 newReserve);
    event LiquidityWithdrawn(address indexed token, uint256 amount, uint256 newReserve);
    event Swapped(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        address recipient
    );
    event SwapFeeUpdated(uint16 oldBps, uint16 newBps);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error TokenNotActive(address token);
    error SameToken(address token);
    error ZeroAmount();
    error DeadlinePassed();
    error InsufficientLiquidity(address token, uint256 requested, uint256 available);
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    error PriceDeviation(address token, uint256 newPrice, uint256 lastAccepted, uint16 maxBps);
    error InvalidOracleRound(address token, uint80 roundId, uint80 answeredInRound);
    error InvalidOracleTimestamp(address token, uint256 updatedAt);
    error InvalidFeeBps(uint16 bps);
    error PoolPaused();

    function reserves(address token) external view returns (uint256);
    function protocolFeesAccrued(address token) external view returns (uint256);
    function swapFeeBps() external view returns (uint16);
    function paused() external view returns (bool);

    function deposit(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount, address to) external;
    function withdrawProtocolFees(address token, uint256 amount, address to) external;
    function syncAcceptedPrice(address token) external returns (uint256 price1e18);

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external returns (uint256 amountOut);

    function setSwapFeeBps(uint16 newBps) external;
    function pause() external;
    function unpause() external;
}
