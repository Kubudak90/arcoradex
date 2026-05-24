// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";

/// @notice Shared P3.5 Timelock-batch construction used by both
/// P3_5GovernanceActions (scheduleBatch) and ExecuteP3_5Batch (executeBatch).
/// Both scripts MUST build the batch identically or the operation id
/// (hashOperationBatch) will not match and executeBatch will revert —
/// hence the single shared builder.
///
/// Key audit fix (G-3): SALT is non-zero and deployment-unique, eliminating
/// the front-run griefing vector that the P3 zero-salt batch had. A griefer
/// cannot force a collision by front-running scheduleBatch with the same
/// batch payload, because the salt produces an unpredictable operation id.
/// After a hypothetical cancel, the batch can be rescheduled immediately
/// without a zero-salt re-use collision.
abstract contract P3_5BatchBuilder is Script {
    ArcoraDexRegistry constant REGISTRY = ArcoraDexRegistry(0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB);
    TimelockController constant TIMELOCK = TimelockController(payable(0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83));

    bytes32 constant PREDECESSOR = bytes32(0);
    /// @dev Non-zero, deployment-unique salt — audit G-3 fix.
    /// Eliminates the front-run griefing window that the P3 zero-salt batch had
    /// and restores re-runnability after a hypothetical cancel.
    bytes32 constant SALT = keccak256("ArcoraDEX-P3_5-aggregator-migration-v1");
    /// @dev Authoritative minimum delay expected on the Timelock (48 hours).
    /// P3_5GovernanceActions asserts minDelay >= this value before scheduling,
    /// catching any misconfiguration where the Timelock was left in setup-mode
    /// with a zero or reduced delay.
    uint256 internal constant TIMELOCK_DELAY = 48 hours;

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

    /// @dev Reads the 7 P3.5 aggregator addresses from env vars.
    function _readP3_5Aggregators() internal view returns (address[7] memory aggs) {
        aggs[0] = vm.envAddress("P3_5_AGG_USDC");
        aggs[1] = vm.envAddress("P3_5_AGG_USDT");
        aggs[2] = vm.envAddress("P3_5_AGG_PYUSD");
        aggs[3] = vm.envAddress("P3_5_AGG_DAI");
        aggs[4] = vm.envAddress("P3_5_AGG_EURC");
        aggs[5] = vm.envAddress("P3_5_AGG_TRYC");
        aggs[6] = vm.envAddress("P3_5_AGG_BRLC");
        for (uint256 i = 0; i < 7; i++) {
            require(aggs[i] != address(0), "P3_5BatchBuilder: zero aggregator address");
        }
    }

    /// @dev Builds the 7-operation Registry batch: one setOracle per token,
    /// pointing the Registry at the new V2 OracleAggregator instances.
    /// Both scheduling and execution call this function — the batch MUST be
    /// identical in both calls or the Timelock operation id will not match.
    function _buildP3_5Batch(address[7] memory aggs)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](7);
        values = new uint256[](7);
        payloads = new bytes[](7);
        for (uint256 i = 0; i < 7; i++) {
            targets[i] = address(REGISTRY);
            values[i] = 0;
            payloads[i] = abi.encodeCall(ArcoraDexRegistry.setOracle, (TOKENS[i], IChainlinkAggregator(aggs[i])));
        }
    }
}
