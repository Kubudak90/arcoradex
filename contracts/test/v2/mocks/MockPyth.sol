// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPythV2} from "../../../src/v2/interfaces/IPythV2.sol";

/// @title MockPyth
/// @notice Settable IPythV2 for adapter tests. Per-id Price is fully settable so a test
/// can drive stale publishTime, negative price, blown confidence, and odd expo. `setRevert`
/// makes getPriceUnsafe revert to prove the adapter's try/catch fail-closes.
contract MockPyth is IPythV2 {
    mapping(bytes32 id => Price) internal _prices;
    bool internal _revert;
    uint256 public updateFee;

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        _prices[id] = Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
    }

    function setRevert(bool r) external {
        _revert = r;
    }

    function setUpdateFee(uint256 f) external {
        updateFee = f;
    }

    function getPriceUnsafe(bytes32 id) external view override returns (Price memory) {
        if (_revert) revert("pyth down");
        return _prices[id];
    }

    function getUpdateFee(bytes[] calldata) external view override returns (uint256) {
        return updateFee;
    }

    /// @dev No-op pull: just refreshes publishTime to block.timestamp for the first id
    /// encoded in updateData[0] (test convenience — tests pass the id as 32 bytes).
    function updatePriceFeeds(bytes[] calldata updateData) external payable override {
        if (updateData.length > 0 && updateData[0].length == 32) {
            bytes32 id = abi.decode(updateData[0], (bytes32));
            _prices[id].publishTime = block.timestamp;
        }
    }

    function getValidTimePeriod() external pure override returns (uint256) {
        return 60;
    }
}
