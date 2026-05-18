// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IChainlinkAggregator } from "../interfaces/IChainlinkAggregator.sol";

/// @title MockChainlinkFeed
/// @notice Testnet-only Chainlink-shaped price feed. Owner can update the price.
/// @dev Use this on Arc testnet until a native EUR/USD feed exists.
contract MockChainlinkFeed is IChainlinkAggregator {
    address public immutable owner;
    int256  public latestAnswer;
    uint256 public latestUpdatedAt;
    uint8   public immutable decimalsValue;

    error NotOwner();
    event AnswerUpdated(int256 answer, uint256 updatedAt);

    constructor(uint8 _decimals, int256 initialAnswer) {
        owner = msg.sender;
        decimalsValue = _decimals;
        latestAnswer = initialAnswer;
        latestUpdatedAt = block.timestamp;
    }

    function setAnswer(int256 newAnswer) external {
        if (msg.sender != owner) revert NotOwner();
        latestAnswer = newAnswer;
        latestUpdatedAt = block.timestamp;
        emit AnswerUpdated(newAnswer, block.timestamp);
    }

    function decimals() external view returns (uint8) { return decimalsValue; }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, latestAnswer, latestUpdatedAt, latestUpdatedAt, 1);
    }
}
