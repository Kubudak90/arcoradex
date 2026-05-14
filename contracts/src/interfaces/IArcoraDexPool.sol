// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IArcoraDexRegistry } from "./IArcoraDexRegistry.sol";
import { IArcoraDexLP }       from "./IArcoraDexLP.sol";

interface IArcoraDexPool {
    // ── Errors ────────────────────────────────────────────────────────
    error ZeroAmount();
    error ZeroAddress();
    error SameToken(address token);
    error DeadlinePassed();
    error PoolPaused();
    error TokenNotActive(address token);
    error InvalidFeeBps(uint16 bps);
    error InvalidProtocolFeeShareBps(uint16 bps);
    error InsufficientOutput(uint256 actual, uint256 minOut);
    error InsufficientLpOut(uint256 actual, uint256 minLpOut);
    error InsufficientTokenOut(uint256 actual, uint256 minTokenOut);
    error InsufficientLiquidity(address token, uint256 requested, uint256 available);
    error FirstDepositTooSmall(uint256 usdValue, uint256 minimumLiquidity);
    error InvalidOracleRound(address token, uint80 roundId, uint80 answeredInRound);
    error InvalidOracleTimestamp(address token, uint256 updatedAt);
    error PriceDeviation(address token, uint256 newPrice1e18, uint256 prev1e18, uint16 maxDevBps);
    error NoValidPrice(address token);
    error EarlyWithdraw(uint256 unlockAt, uint256 nowAt);
    error NotLP();
    error NotAuthorized();

    // ── Events ────────────────────────────────────────────────────────
    event Deposited(
        address indexed user,
        address indexed token,
        uint256 amountIn,
        uint256 lpMinted,
        uint256 navBefore1e18,
        uint256 navAfter1e18
    );
    event Withdrew(
        address indexed user,
        address indexed tokenOut,
        uint256 lpBurned,
        uint256 amountOut,
        uint256 protocolFee,
        uint256 navBefore1e18,
        uint256 navAfter1e18
    );
    event Swapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 lpFeeUsd1e18,
        uint256 protocolFeeAmtOut,
        address recipient
    );
    event SwapFeeUpdated(uint16 oldBps, uint16 newBps);
    event ProtocolFeeShareUpdated(uint16 oldBps, uint16 newBps);
    event ProtocolFeesWithdrawn(address indexed token, uint256 amount, address indexed to);
    event Paused (address indexed by);
    event Unpaused(address indexed by);
    event AcceptedPriceSynced(address indexed token, uint256 oldPrice1e18, uint256 newPrice1e18);
    event PriceCacheUpdated(address indexed token, uint256 price1e18, uint256 updatedAt);
    event PauseGuardianUpdated(address indexed prev, address indexed next);

    // ── Views ─────────────────────────────────────────────────────────
    function REGISTRY()             external view returns (IArcoraDexRegistry);
    function LP()                   external view returns (IArcoraDexLP);
    function reserves(address token)             external view returns (uint256);
    function protocolFeesAccrued(address token)  external view returns (uint256);
    function lastAcceptedPrice(address token)    external view returns (uint256);
    function lastValidPrice(address token)   external view returns (uint256);
    function lastValidPriceAt(address token) external view returns (uint256);
    function lastMintAt(address account) external view returns (uint256);
    function pauseGuardian()        external view returns (address);
    function swapFeeBps()           external view returns (uint16);
    function protocolFeeShareBps()  external view returns (uint16);
    function paused()               external view returns (bool);
    function totalReservesUSD()     external view returns (uint256 navE18);

    function quote        (address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (uint256 amountOut);
    function quoteDeposit (address token, uint256 amount)
        external view returns (uint256 lpOut);
    function quoteWithdraw(address tokenOut, uint256 lpAmount)
        external view returns (uint256 amountOut, uint256 protocolFee);

    // ── Public (anyone) ──────────────────────────────────────────────
    function deposit(address token, uint256 amount, uint256 minLpOut, uint256 deadline)
        external returns (uint256 lpMinted);
    function withdraw(address tokenOut, uint256 lpAmount, uint256 minTokenOut, uint256 deadline)
        external returns (uint256 amountOut);
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external returns (uint256 amountOut);

    // ── Owner-only ───────────────────────────────────────────────────
    function setSwapFeeBps         (uint16 newBps) external;
    function setProtocolFeeShareBps(uint16 newBps) external;
    function withdrawProtocolFees  (address token, uint256 amount, address to) external;
    function pause()   external;
    function unpause() external;
    function syncAcceptedPrice(address token) external returns (uint256 price1e18);
    function setPauseGuardian(address newGuardian) external;

    /// @notice Called by the LP token on every transfer to propagate min-hold.
    /// Only the LP contract may call this.
    function notifyLPTransfer(address from, address to) external;
}
