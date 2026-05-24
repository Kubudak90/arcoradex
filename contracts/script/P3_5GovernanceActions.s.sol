// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Safe} from "@safe-global/safe-contracts/contracts/Safe.sol";
import {SafeSigHelpers} from "../test/governance/SafeSigHelpers.sol";
import {P3_5BatchBuilder} from "./P3_5BatchBuilder.sol";
import {OracleAggregator} from "../src/oracle/OracleAggregator.sol";

/// @notice Phase 3.5 operational script. Schedules, through the 48h
/// Timelock, the 7-operation Registry batch that migrates usdOracle
/// pointers to the new V2 OracleAggregator instances.
///
/// Unlike P3, there is no Phase A (ownership-accept step) because
/// DeployOraclesP3_5.s.sol sets initialOwner = Governance Safe directly
/// at construction — no Ownable2Step pending-accept is needed.
///
/// This is Phase B only: Governance Safe calls Timelock.scheduleBatch.
///
/// Audit fix G-7 (idempotency): before scheduling, this script checks
/// whether the batch is already pending or done on the Timelock, and
/// skips the scheduleBatch call if so. This makes the script safe to
/// re-run after a partial broadcast without double-scheduling.
///
/// Audit fix G-3 (non-zero salt): the batch operation id is keyed by
/// P3_5BatchBuilder.SALT = keccak256("ArcoraDEX-P3_5-aggregator-migration-v1"),
/// eliminating the front-run griefing vector the P3 zero-salt batch had.
///
/// Required env: DEPLOYER_PRIVATE_KEY, P3_5_AGG_USDC, P3_5_AGG_USDT,
/// P3_5_AGG_PYUSD, P3_5_AGG_DAI, P3_5_AGG_EURC, P3_5_AGG_TRYC,
/// P3_5_AGG_BRLC.
contract P3_5GovernanceActions is P3_5BatchBuilder {
    using SafeSigHelpers for Safe;

    string constant MNEMONIC = "test test test test test test test test test test test junk";

    Safe constant GOV_SAFE = Safe(payable(0x715f669D79Cc72d6685F8724c0B86f7B53d7e624));

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // _readP3_5Aggregators() validates all 7 are non-zero.
        address[7] memory aggs = _readP3_5Aggregators();

        // ── N-1: env-var sanity check — aggregators must have code and be Safe-owned ──
        for (uint256 i = 0; i < 7; i++) {
            require(aggs[i].code.length > 0, "P3_5: aggregator has no code");
            require(OracleAggregator(aggs[i]).owner() == address(GOV_SAFE), "P3_5: aggregator not Safe-owned");
        }

        // Build the batch payload — identical to what ExecuteP3_5Batch will use.
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildP3_5Batch(aggs);

        // ── Compute batchId before broadcast — no broadcast needed for a view call ──
        bytes32 batchId = TIMELOCK.hashOperationBatch(targets, values, payloads, PREDECESSOR, SALT);
        console2.log("batch id:", uint256(batchId));

        // ── G-7 idempotency guard (BEFORE startBroadcast) ─────────────────────
        // Skip scheduleBatch if the batch is already pending or done on the
        // Timelock. This allows the script to be safely re-run after a partial
        // or failed broadcast without reverting on an already-scheduled operation.
        // Moving this check outside startBroadcast prevents an empty broadcast
        // from being emitted on re-runs of an already-scheduled batch.
        if (TIMELOCK.isOperationPending(batchId) || TIMELOCK.isOperationDone(batchId)) {
            console2.log("batch already scheduled/done, nothing to do");
            return;
        }

        // ── I-1: minDelay guard — refuse to schedule if Timelock is misconfigured ──
        uint256 minDelay = TIMELOCK.getMinDelay();
        require(minDelay >= TIMELOCK_DELAY, "P3_5: Timelock min delay < 48h - refuse to schedule");

        // Derive the 5 governance signer keys from the standard test mnemonic
        // (matches the P2 governance Safe deployment).
        uint256[5] memory govKeys;
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i] = vm.deriveKey(MNEMONIC, uint32(i));
        }

        // ── Schedule 7-operation batch through the 48h Timelock ───────────────
        // 7 x Registry.setOracle — point each stablecoin at its new V2 aggregator.
        // Only start broadcast when we actually need to schedule.
        vm.startBroadcast(deployerKey);

        bytes memory schedBatchCall =
            abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, PREDECESSOR, SALT, minDelay));

        require(GOV_SAFE.execCall(address(TIMELOCK), schedBatchCall, _keys3(govKeys)), "scheduleBatch failed");

        vm.stopBroadcast();

        // Post-condition: batch must now be pending on the Timelock.
        require(TIMELOCK.isOperationPending(batchId), "batch not pending after scheduleBatch");

        console2.log("P3.5 batch scheduled through Timelock (salt: non-zero G-3 fix)");
        console2.log("Batch id (executable after Timelock delay):");
        console2.logBytes32(batchId);
        console2.log("Timelock min delay (seconds):", minDelay);
        console2.log("Run ExecuteP3_5Batch.s.sol after the delay elapses with the same P3_5_AGG_* env vars.");

        // ── N-5: log executable timestamp ─────────────────────────────────────
        console2.log("Executable after Unix timestamp:", block.timestamp + minDelay);
        console2.log("(That's", minDelay / 3600, "hours from now.)");
    }

    /// @dev Slices the first 3 keys from the 5-key governance array.
    /// Centralises the 3-of-5 key selection used by Phase B.
    function _keys3(uint256[5] memory govKeys) private pure returns (uint256[] memory keys3) {
        keys3 = new uint256[](3);
        keys3[0] = govKeys[0];
        keys3[1] = govKeys[1];
        keys3[2] = govKeys[2];
    }
}
