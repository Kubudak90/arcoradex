// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IOracleAdapterV2} from "../interfaces/IOracleAdapterV2.sol";

/// @title MockOracleAdapterV2Settable
/// @notice TESTNET-ONLY deployable IOracleAdapterV2 for chains with NO Pyth and NO
/// real Chainlink (Arc testnet, chainId 5042002). The Pool consumes only the
/// (price1e18, safe) tuple this returns, so a keeper-settable mock keeps the full
/// section 9 UI (reserveHealth / quotes / maxSwapOut) functional and lets an operator
/// drive the section 11 oracle-failure path deterministically by flipping `safe`.
///
/// ROLE SEPARATION (mirrors src/testnet/MockChainlinkFeedV2):
///   - owner (Ownable2Step admin): rotates the writer; handed to the Gov Safe at deploy.
///   - writer (the keeper EOA): pushes setPrice/setSafe; never the admin key.
///
/// NOT for mainnet. The real dual-source ChainlinkPythAdapterV2 is used wherever
/// both a Chainlink-style aggregator and a Pyth contract exist (e.g. Base).
contract MockOracleAdapterV2Settable is IOracleAdapterV2, Ownable2Step {
    address public writer;
    mapping(address token => uint256 price1e18) public price1e18Of;
    mapping(address token => bool safe) public safeOf;
    mapping(address token => uint256 ts) public updatedAtOf;

    error NotWriter();
    error ZeroAddress();

    event WriterUpdated(address indexed prev, address indexed next);
    event PricePushed(address indexed token, uint256 price1e18, bool safe, uint256 updatedAt);

    modifier onlyWriter() {
        if (msg.sender != writer) revert NotWriter();
        _;
    }

    constructor(address initialOwner, address initialWriter) Ownable(initialOwner) {
        if (initialWriter == address(0)) revert ZeroAddress();
        writer = initialWriter;
        emit WriterUpdated(address(0), initialWriter);
    }

    /// @notice Admin rotates the keeper-writer (e.g. on a key ceremony).
    function setWriter(address newWriter) external onlyOwner {
        if (newWriter == address(0)) revert ZeroAddress();
        emit WriterUpdated(writer, newWriter);
        writer = newWriter;
    }

    /// @notice Keeper pushes the full (price1e18, safe) tuple for a token.
    function setPrice(address token, uint256 price1e18, bool safe) external onlyWriter {
        price1e18Of[token] = price1e18;
        safeOf[token] = safe;
        updatedAtOf[token] = block.timestamp;
        emit PricePushed(token, price1e18, safe, block.timestamp);
    }

    /// @notice Keeper/drill flips ONLY the safe flag (retains last price for display).
    function setSafe(address token, bool safe) external onlyWriter {
        safeOf[token] = safe;
        emit PricePushed(token, price1e18Of[token], safe, block.timestamp);
    }

    /// @inheritdoc IOracleAdapterV2
    function readPrice(address token) external view override returns (uint256 price1e18, bool safe) {
        return (price1e18Of[token], safeOf[token]);
    }

    /// @inheritdoc IOracleAdapterV2
    function peekPrice(address token) external view override returns (uint256 price1e18, bool safe) {
        return (price1e18Of[token], safeOf[token]);
    }
}
