// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOracleAdapterV2} from "./IOracleAdapterV2.sol";
import {FeeBandMathV2} from "../lib/FeeBandMathV2.sol";

interface IArcoraDexRegistryV2 {
    /// @param decimals ERC20 decimals (must equal the token's actual decimals).
    /// @param isActive Whether the token participates in NAV and priced ops.
    /// @param adapter The §10 oracle adapter for this token.
    /// @param minimumReserveUsd Protected floor (1e18 USD). No priced op may cross it.
    /// @param targetReserveUsd Healthiest-band threshold (1e18 USD). Must exceed min.
    /// @param depositCapUsd Rollout cap on reserve USD (0 = unlimited).
    /// @param bands Ordered, contiguous, non-decreasing-rate fee schedule (§7).
    /// @dev The protocol fee share is a single pool-level state var (V1 pattern); there is no
    ///      per-token override.
    struct TokenConfigV2 {
        uint8 decimals;
        bool isActive;
        IOracleAdapterV2 adapter;
        uint256 minimumReserveUsd;
        uint256 targetReserveUsd;
        uint256 depositCapUsd;
        FeeBandMathV2.Band[] bands;
    }

    // ── Errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidDecimals(uint8 decimals);
    error TokenDecimalMismatch(address token, uint8 declared, uint8 actual);
    error InvalidReserveBounds(address token);
    error InvalidBands(address token);
    error TokenAlreadyListed(address token);
    error TokenNotListed(address token);
    error MaxTokensReached();
    error TokenStillActive(address token);
    error TokenHasReserves(address token);

    // ── Events ────────────────────────────────────────────────────────
    event TokenListed(
        address indexed token, address indexed adapter, uint256 minimumReserveUsd, uint256 targetReserveUsd
    );
    event TokenConfigUpdated(address indexed token);
    event AdapterUpdated(address indexed token, address oldAdapter, address newAdapter);
    event TokenDeactivated(address indexed token);
    event TokenReactivated(address indexed token);
    event TokenRemoved(address indexed token);
    event PoolSet(address indexed pool);

    // ── Constants ──────────────────────────────────────────────────────
    function MAX_TOKENS() external view returns (uint256);
    function MAX_FEE_BPS() external view returns (uint16);
    function MAX_PROTOCOL_FEE_SHARE_BPS() external view returns (uint16);

    // ── Mutators (owner-only) ──────────────────────────────────────────
    function listToken(address token, TokenConfigV2 calldata config) external;
    function setTokenConfig(address token, TokenConfigV2 calldata config) external;
    function setAdapter(address token, IOracleAdapterV2 newAdapter) external;
    function deactivateToken(address token) external;
    function reactivateToken(address token) external;
    function removeToken(address token) external;
    function setPool(address pool_) external;

    // ── Views ───────────────────────────────────────────────────────────
    function tokens(uint256 i) external view returns (address);
    function tokensLength() external view returns (uint256);
    function tokenConfig(address token) external view returns (TokenConfigV2 memory);
    function isActive(address token) external view returns (bool);
    function pool() external view returns (address);
}
