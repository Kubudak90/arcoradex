// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOracleAdapterV2} from "../../../src/v2/interfaces/IOracleAdapterV2.sol";

/// @title MockOracleAdapterV2
/// @notice Test-only adapter. Price and the `safe` flag are independently settable
/// per token so tests can drive every §11 failure mode (unsafe-with-stale-price,
/// price=0, etc.) without modelling Chainlink/Pyth internals.
contract MockOracleAdapterV2 is IOracleAdapterV2 {
    mapping(address token => uint256) public price1e18Of;
    mapping(address token => bool) public safeOf;

    function setPrice(address token, uint256 price1e18, bool safe) external {
        price1e18Of[token] = price1e18;
        safeOf[token] = safe;
    }

    function setSafe(address token, bool safe) external {
        safeOf[token] = safe;
    }

    function readPrice(address token) external view returns (uint256, bool) {
        return (price1e18Of[token], safeOf[token]);
    }

    function peekPrice(address token) external view returns (uint256, bool) {
        return (price1e18Of[token], safeOf[token]);
    }
}
