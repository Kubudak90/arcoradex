// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArcoraDexRegistryV2} from "./IArcoraDexRegistryV2.sol";
import {IArcoraDexLPV2} from "./IArcoraDexLPV2.sol";

interface IArcoraDexPoolV2 {
    // ── Errors ────────────────────────────────────────────────────────
    error ZeroAmount();
    error ZeroAddress();
    error SameToken(address token);
    error DeadlinePassed();
    error PoolPaused();
    error TokenNotActive(address token);
    error OracleUnsafe(address token);
    error InvalidProtocolFeeShareBps(uint16 bps);
    error InsufficientOutput(uint256 actual, uint256 minOut);
    error InsufficientLpOut(uint256 actual, uint256 minLpOut);
    error InsufficientTokenOut(uint256 actual, uint256 minTokenOut);
    error InsufficientLiquidity(address token, uint256 requested, uint256 available);
    error ReserveFloorBreached(address token);
    error DepositCapExceeded(address token);
    error FirstDepositTooSmall(uint256 usdValue, uint256 minimumLiquidity);
    error EarlyWithdraw(uint256 unlockAt, uint256 nowAt);
    error EarlyTransfer(uint256 unlockAt, uint256 nowAt);
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
    event Swapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeUsd1e18,
        uint256 protocolFeeAmtOut,
        address recipient
    );
    event WithdrewSingle(
        address indexed user,
        address indexed tokenOut,
        uint256 lpBurned,
        uint256 amountOut,
        uint256 protocolFee,
        uint256 feeUsd1e18
    );
    event WithdrewProportional(address indexed user, uint256 lpBurned);
    event ProtocolFeeShareUpdated(uint16 oldBps, uint16 newBps);
    event ProtocolFeesWithdrawn(address indexed token, uint256 amount, address indexed to);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event PauseGuardianUpdated(address indexed prev, address indexed next);

    // ── Views ───────────────────────────────────────────────────────────
    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    function REGISTRY() external view returns (IArcoraDexRegistryV2);
    // slither-disable-next-line naming-convention
    function LP() external view returns (IArcoraDexLPV2);
    function reserves(address token) external view returns (uint256);
    function protocolFeesAccrued(address token) external view returns (uint256);
    function lastMintAt(address account) external view returns (uint256);
    function pauseGuardian() external view returns (address);
    function paused() external view returns (bool);
    function totalReservesUSD() external view returns (uint256 navE18);

    /// @notice health in bps (0..10000) of `token`'s reserve (§9).
    function reserveHealth(address token) external view returns (uint256 healthBps);
    /// @notice Max executable NET output of `tokenOut` and its gross entitlement (§9).
    function maxSwapOut(address tokenOut) external view returns (uint256 netOut, uint256 grossUsd1e18);
    /// @notice Max LP `account` may burn via single-token path into `tokenOut`, and the net out (§9).
    function maxWithdraw(address tokenOut, address account) external view returns (uint256 lpAmount, uint256 netOut);
    function quoteSwapV2(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps);
    function quoteWithdrawV2(address tokenOut, uint256 lpAmount)
        external
        view
        returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps);

    // ── Public (anyone) ──────────────────────────────────────────────
    function deposit(address token, uint256 amount, uint256 minLpOut, uint256 deadline)
        external
        returns (uint256 lpMinted);
    function withdrawSingle(address tokenOut, uint256 lpAmount, uint256 minTokenOut, uint256 deadline)
        external
        returns (uint256 amountOut);
    function withdrawProportional(uint256 lpAmount, uint256 deadline) external returns (uint256[] memory amounts);
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external returns (uint256 amountOut);

    // ── Owner / Guardian ───────────────────────────────────────────────
    function setProtocolFeeShareBps(uint16 newBps) external;
    function withdrawProtocolFees(address token, uint256 amount, address to) external;
    function pause() external;
    function unpause() external;
    function setPauseGuardian(address newGuardian) external;

    // ── LP hook ──────────────────────────────────────────────────────
    function notifyLPTransfer(address from, address to) external;
}
