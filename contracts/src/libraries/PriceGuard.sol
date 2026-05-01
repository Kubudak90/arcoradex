// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IChainlinkAggregator } from "../interfaces/IChainlinkAggregator.sol";

/// @title PriceGuard
/// @notice Reverts if a pool-derived rate deviates too far from a Chainlink reference.
library PriceGuard {
    /// @dev Maximum age of a Chainlink round before it is considered stale.
    uint256 internal constant MAX_STALE_SECONDS = 1 hours;

    /// @dev Denominator for basis-point arithmetic (1 bp = 0.01%).
    uint256 internal constant BPS = 10_000;

    error StaleOracle(uint256 updatedAt);
    error InvalidOraclePrice(int256 answer);
    error OracleDeviation(uint256 poolRate, uint256 oracleRate, uint256 maxBps);

    /// @notice Returns the Chainlink reference rate, scaled to 1e18.
    /// @dev Reverts on stale or invalid rounds.
    function _readOracle(IChainlinkAggregator feed) internal view returns (uint256 rate1e18) {
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        if (answer <= 0) revert InvalidOraclePrice(answer);
        if (block.timestamp - updatedAt > MAX_STALE_SECONDS) revert StaleOracle(updatedAt);
        uint8 dec = feed.decimals();
        if (dec == 18) return uint256(answer);
        if (dec < 18) return uint256(answer) * (10 ** (18 - dec));
        return uint256(answer) / (10 ** (dec - 18));
    }

    /// @notice Reverts if `poolRate` deviates from the oracle rate by more than `maxDeviationBps`.
    /// @param poolRate Rate implied by the AMM pool, scaled to 1e18 (units: quote per 1 base).
    /// @param feed Chainlink aggregator for the base/quote pair.
    /// @param maxDeviationBps Max allowed deviation in basis points (50 = 0.5%).
    function check(
        uint256 poolRate,
        IChainlinkAggregator feed,
        uint256 maxDeviationBps
    ) internal view {
        uint256 oracleRate = _readOracle(feed);
        uint256 diff = poolRate > oracleRate ? poolRate - oracleRate : oracleRate - poolRate;
        if (diff * BPS > oracleRate * maxDeviationBps) {
            revert OracleDeviation(poolRate, oracleRate, maxDeviationBps);
        }
    }
}
