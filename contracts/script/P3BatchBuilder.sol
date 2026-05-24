// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";

/// @notice Shared P3 Timelock-batch construction used by both
/// P3GovernanceActions (scheduleBatch) and ExecuteP3Batch (executeBatch).
/// Both scripts MUST build the batch identically or the operation id
/// (hashOperationBatch) will not match and executeBatch will revert —
/// hence the single shared builder.
///
/// @dev DEAD CODE — superseded by P3_5BatchBuilder. M-1 (audit 2026-05-24):
/// this batch uses SALT = bytes32(0), which makes a rescheduled call
/// collide on the same operation id and revert. The post-P3.5 batches
/// (P3_5BatchBuilder) use a non-zero salt and are the canonical scripts
/// for any future Timelock work. Retained for git history of the
/// 2026-05-17 deployment trail; do NOT extend or invoke this batch.
abstract contract P3BatchBuilder is Script {
    ArcoraDexRegistry constant REGISTRY = ArcoraDexRegistry(0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB);

    bytes32 constant PREDECESSOR = bytes32(0);
    /// @dev SALT is zero, making this schedule intentionally non-repeatable:
    /// a second scheduleBatch with the same targets/payloads/predecessor/salt
    /// would collide on the same operation id and revert if still pending.
    bytes32 constant SALT = bytes32(0);
    uint256 constant TIMELOCK_DELAY = 48 hours;

    // Token addresses (2026-05-06 deploy); TRYC = index 5, BRLC = index 6.
    address[7] internal TOKENS = [
        0x3BFa09fF6467639f0981948385bA1018Ac07d22C, // USDC
        0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B, // USDT
        0xfdB2c86d010698401f0b969348DC58b6659B96a3, // PYUSD
        0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE, // DAI
        0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD, // EURC
        0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61, // TRYC
        0xa13c0935A98e2c175b31A4054f698819271a8FfC // BRLC
    ];

    /// @dev Reads the 7 P3 aggregator addresses from env vars.
    function _readAggregators() internal view returns (address[7] memory aggs) {
        aggs[0] = vm.envAddress("P3_AGG_USDC");
        aggs[1] = vm.envAddress("P3_AGG_USDT");
        aggs[2] = vm.envAddress("P3_AGG_PYUSD");
        aggs[3] = vm.envAddress("P3_AGG_DAI");
        aggs[4] = vm.envAddress("P3_AGG_EURC");
        aggs[5] = vm.envAddress("P3_AGG_TRYC");
        aggs[6] = vm.envAddress("P3_AGG_BRLC");
        for (uint256 i = 0; i < 7; i++) {
            require(aggs[i] != address(0), "P3BatchBuilder: zero aggregator address");
        }
    }

    /// @dev Builds the 9-operation Registry batch: 7 setOracle + 2 setDeviation
    /// (TRYC and BRLC caps -> 200). Both scheduling and execution call this.
    function _buildP3Batch(address[7] memory aggs)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](9);
        values = new uint256[](9);
        payloads = new bytes[](9);
        for (uint256 i = 0; i < 7; i++) {
            targets[i] = address(REGISTRY);
            values[i] = 0;
            payloads[i] = abi.encodeCall(ArcoraDexRegistry.setOracle, (TOKENS[i], IChainlinkAggregator(aggs[i])));
        }
        targets[7] = address(REGISTRY);
        values[7] = 0;
        payloads[7] = abi.encodeCall(ArcoraDexRegistry.setDeviation, (TOKENS[5], uint16(200))); // TRYC
        targets[8] = address(REGISTRY);
        values[8] = 0;
        payloads[8] = abi.encodeCall(ArcoraDexRegistry.setDeviation, (TOKENS[6], uint16(200))); // BRLC
    }
}
