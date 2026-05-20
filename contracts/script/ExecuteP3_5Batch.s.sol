// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IArcoraDexRegistry} from "../src/interfaces/IArcoraDexRegistry.sol";
import {P3_5BatchBuilder} from "./P3_5BatchBuilder.sol";

/// @notice Executes the P3.5 Registry migration batch after the Timelock
/// delay has elapsed. The Timelock executor role is open, so the deployer
/// EOA can execute directly (no Safe signatures needed).
///
/// MUST be run with the SAME P3_5_AGG_* env vars as the scheduling run
/// (P3_5GovernanceActions.s.sol), or the reconstructed batch payload will
/// not match the scheduled operation id and executeBatch will revert.
///
/// Post-conditions asserted on-chain:
///   - TIMELOCK.isOperationDone(batchId) == true
///   - For each of the 7 tokens, REGISTRY.tokenInfo(token).usdOracle matches
///     the corresponding P3_5_AGG_* env var.
///
/// Required env: DEPLOYER_PRIVATE_KEY, P3_5_AGG_USDC, P3_5_AGG_USDT,
/// P3_5_AGG_PYUSD, P3_5_AGG_DAI, P3_5_AGG_EURC, P3_5_AGG_TRYC,
/// P3_5_AGG_BRLC.
contract ExecuteP3_5Batch is P3_5BatchBuilder {
    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // _readP3_5Aggregators() validates all 7 are non-zero.
        address[7] memory aggs = _readP3_5Aggregators();

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildP3_5Batch(aggs);

        bytes32 id = TIMELOCK.hashOperationBatch(targets, values, payloads, PREDECESSOR, SALT);
        console2.log("Batch id:");
        console2.logBytes32(id);

        require(TIMELOCK.isOperationReady(id), "batch not ready (delay not elapsed, or not scheduled)");

        vm.startBroadcast(deployerKey);
        TIMELOCK.executeBatch(targets, values, payloads, PREDECESSOR, SALT);
        vm.stopBroadcast();

        // ── Post-condition assertions ──────────────────────────────────────────
        require(TIMELOCK.isOperationDone(id), "batch not done after executeBatch");

        // Verify each token's usdOracle pointer was updated to the new V2 aggregator.
        string[7] memory symbols = ["USDC", "USDT", "PYUSD", "DAI", "EURC", "TRYC", "BRLC"];
        for (uint256 i = 0; i < 7; i++) {
            IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(TOKENS[i]);
            require(
                address(info.usdOracle) == aggs[i],
                string.concat("ExecuteP3_5Batch: usdOracle mismatch for ", symbols[i])
            );
            console2.log(string.concat("  ", symbols[i], " usdOracle ->"), aggs[i]);
        }

        console2.log("");
        console2.log("P3.5 batch executed: Registry usdOracle pointers migrated to V2 aggregators.");
        console2.log("Audit fixes C-1 (degraded-mode signal), C-2 (per-source staleness),");
        console2.log("and C-5 (real round-id) are now active on-chain.");
    }
}
