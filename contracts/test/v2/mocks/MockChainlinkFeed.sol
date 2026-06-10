// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IChainlinkAggregator} from "../../../src/interfaces/IChainlinkAggregator.sol";

/// @title MockChainlinkFeed
/// @notice Fully settable Chainlink aggregator for adapter tests. Every staleness /
/// negative / malformed / revert case is reachable by setters. Defaults to a fresh
/// 8-dec $1.00 round.
contract MockChainlinkFeed is IChainlinkAggregator {
    uint8 internal _decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _roundId;
    uint80 internal _answeredInRound;
    bool internal _revert;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId = 1;
        _answeredInRound = 1;
    }

    function setAnswer(int256 a) external {
        _answer = a;
    }

    function setUpdatedAt(uint256 u) external {
        _updatedAt = u;
    }

    function setRound(uint80 roundId_, uint80 answeredInRound_) external {
        _roundId = roundId_;
        _answeredInRound = answeredInRound_;
    }

    function setRevert(bool r) external {
        _revert = r;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        if (_revert) revert("feed down");
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }
}
