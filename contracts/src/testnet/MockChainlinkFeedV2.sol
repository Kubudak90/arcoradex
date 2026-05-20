// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";

/// @title MockChainlinkFeedV2
/// @notice Testnet-only Chainlink-shaped price feed with role-separated owner
/// (admin) and writer (price-pusher). Drop-in replacement for MockChainlinkFeed
/// at the registry's oracle slot.
contract MockChainlinkFeedV2 is IChainlinkAggregator, Ownable2Step {
    address public writer;
    int256 public latestAnswer;
    uint256 public latestUpdatedAt;
    uint8 public immutable decimalsValue;

    error NotWriter();
    error ZeroAddress();
    error AnswerNotPositive();
    event WriterUpdated(address indexed prev, address indexed next);
    event AnswerUpdated(int256 answer, uint256 updatedAt);

    uint80 private _roundId;

    constructor(uint8 _decimals, int256 initialAnswer, address initialWriter, address initialOwner)
        Ownable(initialOwner)
    {
        if (initialWriter == address(0)) revert ZeroAddress();
        decimalsValue = _decimals;
        latestAnswer = initialAnswer;
        latestUpdatedAt = block.timestamp;
        writer = initialWriter;
        _roundId = 1;
        emit WriterUpdated(address(0), initialWriter);
        emit AnswerUpdated(initialAnswer, block.timestamp);
    }

    function setWriter(address newWriter) external onlyOwner {
        if (newWriter == address(0)) revert ZeroAddress();
        emit WriterUpdated(writer, newWriter);
        writer = newWriter;
    }

    function setAnswer(int256 newAnswer) external {
        if (msg.sender != writer) revert NotWriter();
        if (newAnswer <= 0) revert AnswerNotPositive();
        _roundId += 1;
        latestAnswer = newAnswer;
        latestUpdatedAt = block.timestamp;
        emit AnswerUpdated(newAnswer, block.timestamp);
    }

    function decimals() external view returns (uint8) {
        return decimalsValue;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, latestAnswer, latestUpdatedAt, latestUpdatedAt, _roundId);
    }
}
