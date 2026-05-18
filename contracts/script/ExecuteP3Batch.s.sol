// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { P3BatchBuilder } from "./P3BatchBuilder.sol";

/// @notice Executes the P3 Registry migration batch 48h after
/// P3GovernanceActions scheduled it. The Timelock executor role is open,
/// so the deployer EOA can execute directly (no Safe signatures needed).
/// MUST be run with the SAME P3_AGG_* env vars as the scheduling run, or
/// the reconstructed batch will not match the scheduled operation id.
///
/// Required env: DEPLOYER_PRIVATE_KEY, P3_AGG_<SYM> x7.
contract ExecuteP3Batch is P3BatchBuilder {
    TimelockController constant TIMELOCK =
        TimelockController(payable(0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83));

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address[7] memory aggs = _readAggregators();
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _buildP3Batch(aggs);

        bytes32 id = TIMELOCK.hashOperationBatch(targets, values, payloads, PREDECESSOR, SALT);
        console2.log("Batch id:");
        console2.logBytes32(id);
        require(TIMELOCK.isOperationReady(id), "batch not ready (48h not elapsed, or not scheduled)");

        vm.startBroadcast(deployerKey);
        TIMELOCK.executeBatch(targets, values, payloads, PREDECESSOR, SALT);
        vm.stopBroadcast();

        require(TIMELOCK.isOperationDone(id), "batch not done after execute");
        console2.log("P3 batch executed: Registry migrated to aggregators, TRYC/BRLC caps -> 200");
    }
}
