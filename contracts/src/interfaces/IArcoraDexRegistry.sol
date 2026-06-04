// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IChainlinkAggregator} from "./IChainlinkAggregator.sol";

interface IArcoraDexRegistry {
    struct TokenInfo {
        uint8 decimals;
        bool isActive;
        IChainlinkAggregator usdOracle;
        uint16 maxOracleDeviationBps;
        uint32 maxStaleSeconds;
    }

    // ── Errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidDecimals(uint8 decimals);
    error TokenDecimalMismatch(address token, uint8 declared, uint8 actual);
    error InvalidDeviation(uint16 bps);
    error InvalidStaleSeconds(uint32 maxStaleSeconds);
    error TokenAlreadyListed(address token);
    error TokenNotListed(address token);
    error MaxTokensReached();
    error TokenStillActive(address token);
    /// @notice Reverted by `deactivateToken` when the wired Pool still holds a
    /// non-zero reserve balance for the token (I-1). Deactivating a token with
    /// live reserves would drop those reserves out of NAV (the NAV loop skips
    /// inactive tokens), transferring value between LP cohorts and stranding the
    /// reserves. Drain the Pool's reserves for the token to zero first.
    error TokenHasReserves(address token);

    // ── Events ────────────────────────────────────────────────────────
    event TokenListed(
        address indexed token,
        uint8 decimals,
        address indexed oracle,
        uint16 maxOracleDeviationBps,
        uint32 maxStaleSeconds
    );
    event OracleUpdated(address indexed token, address oldOracle, address newOracle);
    event DeviationUpdated(address indexed token, uint16 oldBps, uint16 newBps);
    event MaxStaleSecondsUpdated(address indexed token, uint32 oldVal, uint32 newVal);
    event TokenDeactivated(address indexed token);
    event TokenReactivated(address indexed token);
    event TokenRemoved(address indexed token);
    /// @notice Emitted when the owner wires (or rewires) the Pool the registry
    /// consults for the I-1 reserve guard.
    event PoolSet(address indexed pool);

    // ── Mutators ──────────────────────────────────────────────────────
    function listToken(
        address token,
        uint8 decimals_,
        IChainlinkAggregator oracle,
        uint16 maxDeviationBps,
        uint32 maxStaleSeconds_
    ) external;
    function setOracle(address token, IChainlinkAggregator newOracle) external;
    function setDeviation(address token, uint16 maxDeviationBps) external;
    function setMaxStaleSeconds(address token, uint32 maxStaleSeconds_) external;
    function deactivateToken(address token) external;
    function reactivateToken(address token) external;
    function removeToken(address token) external;
    function setPool(address pool_) external;

    // ── Views ─────────────────────────────────────────────────────────
    function MAX_TOKENS() external view returns (uint256);
    function tokens(uint256 i) external view returns (address);
    function tokensLength() external view returns (uint256);
    function tokenInfo(address token) external view returns (TokenInfo memory);
    function isActive(address token) external view returns (bool);
    function pool() external view returns (address);
}
