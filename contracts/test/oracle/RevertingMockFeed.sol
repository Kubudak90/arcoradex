// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";

/// @notice Test helper: a Chainlink-shape feed whose `latestRoundData()` always reverts.
/// Used to verify the Pool's try/catch handles reverting oracles by falling back to cache.
contract RevertingMockFeed is IChainlinkAggregator {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert("oracle unavailable");
    }
}

/// @notice Test helper: a Chainlink-shape feed with a WORKING `latestRoundData()` that
/// returns a valid, fresh round — but whose `decimals()` always reverts.
/// Used to exercise the inner try/catch around `oracle.decimals()` in `_readOracle`.
contract RevertingDecimalsMockFeed is IChainlinkAggregator {
    /// @dev Returns a valid fresh round: roundId=1, answer=$1 (8-dec), timestamps=block.timestamp,
    /// answeredInRound=1. All freshness checks pass so `isFresh` becomes true and execution
    /// reaches the inner `decimals()` call.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }

    function decimals() external pure override returns (uint8) {
        revert("decimals unavailable");
    }
}
