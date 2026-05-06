// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IChainlinkAggregator } from "./IChainlinkAggregator.sol";

interface IArcoraDexRegistry {
    struct TokenInfo {
        uint8                decimals;
        bool                 isActive;
        IChainlinkAggregator usdOracle;
        uint16               maxOracleDeviationBps;
    }

    // ── Errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidDecimals(uint8 decimals);
    error TokenDecimalMismatch(address token, uint8 declared, uint8 actual);
    error InvalidDeviation(uint16 bps);
    error TokenAlreadyListed(address token);
    error TokenNotListed(address token);

    // ── Events ────────────────────────────────────────────────────────
    event TokenListed     (address indexed token, uint8 decimals, address oracle, uint16 maxDeviationBps);
    event OracleUpdated   (address indexed token, address oldOracle, address newOracle);
    event DeviationUpdated(address indexed token, uint16 oldBps, uint16 newBps);
    event TokenDeactivated(address indexed token);
    event TokenReactivated(address indexed token);

    // ── Mutators ──────────────────────────────────────────────────────
    function listToken     (address token, uint8 decimals_, IChainlinkAggregator oracle, uint16 maxDeviationBps) external;
    function setOracle     (address token, IChainlinkAggregator newOracle) external;
    function setDeviation  (address token, uint16 maxDeviationBps) external;
    function deactivateToken(address token) external;
    function reactivateToken(address token) external;

    // ── Views ─────────────────────────────────────────────────────────
    function tokens(uint256 i) external view returns (address);
    function tokensLength()    external view returns (uint256);
    function tokenInfo(address token) external view returns (TokenInfo memory);
    function isActive(address token) external view returns (bool);
}
