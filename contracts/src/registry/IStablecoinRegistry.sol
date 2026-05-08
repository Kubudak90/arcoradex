// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IChainlinkAggregator } from "../interfaces/IChainlinkAggregator.sol";

/// @title IStablecoinRegistry
/// @notice Per-token metadata + USD oracle catalogue for the shared-vault StablePool.
interface IStablecoinRegistry {
    struct TokenInfo {
        uint8                decimals;
        bool                 isActive;
        IChainlinkAggregator usdOracle;             // USD-quoted, Chainlink-shape
        uint16               maxOracleDeviationBps; // PriceGuard tolerance, per-token
    }

    event TokenListed(address indexed token, uint8 decimals, address usdOracle, uint16 maxOracleDeviationBps);
    event TokenDeactivated(address indexed token);
    event TokenReactivated(address indexed token);
    event OracleUpdated(address indexed token, address oldOracle, address newOracle);
    event DeviationUpdated(address indexed token, uint16 oldBps, uint16 newBps);

    error TokenAlreadyListed(address token);
    error TokenNotListed(address token);
    error InvalidDecimals(uint8 decimals);
    error TokenDecimalMismatch(address token, uint8 expected, uint8 actual);
    error InvalidDeviation(uint16 bps);
    error ZeroAddress();

    function tokenInfo(address token) external view returns (TokenInfo memory);
    function isActive(address token) external view returns (bool);
    function tokens(uint256 index) external view returns (address);
    function tokensLength() external view returns (uint256);
    function listToken(address token, uint8 decimals_, IChainlinkAggregator oracle, uint16 maxDeviationBps) external;
    function deactivateToken(address token) external;
    function reactivateToken(address token) external;
    function setOracle(address token, IChainlinkAggregator oracle) external;
    function setDeviation(address token, uint16 maxDeviationBps) external;
}
