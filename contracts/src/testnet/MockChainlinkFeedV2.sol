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

    // ── H-2: on-chain sanity bounds (defense-in-depth, immutable at construction) ──
    int256 public immutable minAnswer; // hard sanity floor (>0)
    int256 public immutable maxAnswer; // hard sanity ceiling
    uint32 public immutable maxJumpBps; // 0 = disabled; else max |delta| vs prev, in bps
    uint32 public immutable minUpdateSeconds; // 0 = disabled; else min seconds between updates

    error NotWriter();
    error ZeroAddress();
    error AnswerNotPositive();
    error InvalidBounds();
    error AnswerOutOfBounds(int256 a, int256 lo, int256 hi);
    error MaxJumpExceeded(uint256 diffBps, uint32 cap);
    error MinIntervalNotMet(uint256 nowTs, uint256 nextOkTs);
    event WriterUpdated(address indexed prev, address indexed next);
    event AnswerUpdated(int256 answer, uint256 updatedAt);

    uint80 private _roundId;

    constructor(
        uint8 _decimals,
        int256 initialAnswer,
        address initialWriter,
        address initialOwner,
        int256 _minAnswer,
        int256 _maxAnswer,
        uint32 _maxJumpBps,
        uint32 _minUpdateSeconds
    ) Ownable(initialOwner) {
        if (initialWriter == address(0)) revert ZeroAddress();
        if (_minAnswer <= 0 || _maxAnswer < _minAnswer) revert InvalidBounds();
        if (initialAnswer < _minAnswer || initialAnswer > _maxAnswer) {
            revert AnswerOutOfBounds(initialAnswer, _minAnswer, _maxAnswer);
        }
        decimalsValue = _decimals;
        minAnswer = _minAnswer;
        maxAnswer = _maxAnswer;
        maxJumpBps = _maxJumpBps;
        minUpdateSeconds = _minUpdateSeconds;
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
        if (newAnswer < minAnswer || newAnswer > maxAnswer) {
            revert AnswerOutOfBounds(newAnswer, minAnswer, maxAnswer);
        }
        if (latestAnswer != 0) {
            uint256 prev = uint256(latestAnswer);
            uint256 diff =
                newAnswer > latestAnswer ? uint256(newAnswer - latestAnswer) : uint256(latestAnswer - newAnswer);
            if (maxJumpBps != 0 && diff * 10_000 > prev * maxJumpBps) {
                revert MaxJumpExceeded(diff * 10_000 / prev, maxJumpBps);
            }
            if (minUpdateSeconds != 0 && block.timestamp < latestUpdatedAt + minUpdateSeconds) {
                revert MinIntervalNotMet(block.timestamp, latestUpdatedAt + minUpdateSeconds);
            }
        }
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
