// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IChainlinkAggregator } from "../../src/interfaces/IChainlinkAggregator.sol";

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

    function latestRoundData()
        external
        pure
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert("oracle unavailable");
    }
}
