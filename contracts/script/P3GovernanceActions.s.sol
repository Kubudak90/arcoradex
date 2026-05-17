// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Ownable }      from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { SafeSigHelpers }            from "../test/governance/SafeSigHelpers.sol";
import { P3BatchBuilder }            from "./P3BatchBuilder.sol";

/// @notice Phase 3 operational script. Phase A: Governance Safe accepts
/// ownership of the 15 P3 contracts (guard + 7 aggregators + 7 secondary
/// feeds). Phase B: Governance Safe schedules, through the 48h Timelock,
/// a 9-operation batch on the Registry — 7 setOracle (point each token
/// at its aggregator) + 2 setDeviation (tighten TRYC/BRLC caps to 200).
///
/// P3 contract addresses are read from env vars set by the operator after
/// the DeployOraclesP3.s.sol broadcast (P3_GUARD, P3_SECONDARY_*, P3_AGG_*).
/// Execution of the scheduled batch happens 48h later (separate step —
/// run ExecuteP3Batch.s.sol with the same P3_AGG_* env vars).
///
/// This script is re-runnable: Phase A skips any contract already owned
/// by the Governance Safe, so a partial broadcast can be safely resumed.
///
/// Required env: DEPLOYER_PRIVATE_KEY, P3_GUARD, P3_SECONDARY_<SYM>x7,
/// P3_AGG_<SYM>x7.
contract P3GovernanceActions is P3BatchBuilder {
    using SafeSigHelpers for Safe;

    string constant MNEMONIC =
        "test test test test test test test test test test test junk";

    Safe               constant GOV_SAFE  = Safe(payable(0x715f669D79Cc72d6685F8724c0B86f7B53d7e624));
    TimelockController constant TIMELOCK  = TimelockController(payable(0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83));

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address GUARD = vm.envAddress("P3_GUARD");
        require(GUARD != address(0), "P3_GUARD: zero address");

        address[7] memory SECONDARIES = [
            vm.envAddress("P3_SECONDARY_USDC"),
            vm.envAddress("P3_SECONDARY_USDT"),
            vm.envAddress("P3_SECONDARY_PYUSD"),
            vm.envAddress("P3_SECONDARY_DAI"),
            vm.envAddress("P3_SECONDARY_EURC"),
            vm.envAddress("P3_SECONDARY_TRYC"),
            vm.envAddress("P3_SECONDARY_BRLC")
        ];
        for (uint256 i = 0; i < 7; i++) {
            require(SECONDARIES[i] != address(0), "P3_SECONDARY_*: zero address");
        }

        // _readAggregators() also validates all 7 are non-zero.
        address[7] memory aggs = _readAggregators();

        // Derive the 5 governance signer keys from the standard test mnemonic
        // (matches the P2 governance Safe deployment).
        uint256[5] memory govKeys;
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i] = vm.deriveKey(MNEMONIC, uint32(i));
        }

        vm.startBroadcast(deployerKey);

        // ── Phase A: Governance Safe accepts ownership of all 15 P3 contracts ──
        // Order: guard first, then aggregator+secondary per token (14 calls).
        // Re-runnable: _accept skips contracts already owned by GOV_SAFE.
        _accept(GUARD, govKeys);
        for (uint256 i = 0; i < 7; i++) {
            _accept(aggs[i], govKeys);
            _accept(SECONDARIES[i], govKeys);
        }
        console2.log("Phase A: Governance Safe accepted ownership of 15 contracts");

        // ── Phase B: schedule 9-operation batch through the 48h Timelock ──
        // 7 x Registry.setOracle  (point each token at its new OracleAggregator)
        // 2 x Registry.setDeviation (tighten TRYC [5] and BRLC [6] caps to 200 bps)
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _buildP3Batch(aggs);

        bytes memory schedBatchCall = abi.encodeCall(
            TimelockController.scheduleBatch,
            (targets, values, payloads, PREDECESSOR, SALT, TIMELOCK_DELAY)
        );

        require(
            GOV_SAFE.execCall(address(TIMELOCK), schedBatchCall, _keys3(govKeys)),
            "scheduleBatch failed"
        );
        console2.log("Phase B: scheduled 9-operation batch through Timelock (48h delay)");

        bytes32 batchId = TIMELOCK.hashOperationBatch(targets, values, payloads, PREDECESSOR, SALT);
        console2.log("Batch id (executable after 48h):");
        console2.logBytes32(batchId);
        console2.log("Run ExecuteP3Batch.s.sol after 48h with the same P3_AGG_* env vars to execute this batch.");

        require(TIMELOCK.isOperationPending(batchId), "batch not pending after scheduleBatch");

        vm.stopBroadcast();
    }

    /// @dev Have the Governance Safe accept ownership of `target` (Ownable2Step).
    /// Skips silently if the Governance Safe is already the owner (re-runnable).
    /// After accepting, asserts that ownership transferred correctly.
    function _accept(address target, uint256[5] memory govKeys) internal {
        if (Ownable(target).owner() == address(GOV_SAFE)) {
            console2.log("skip acceptOwnership (already owned):", target);
            return;
        }
        require(
            GOV_SAFE.execCall(target, abi.encodeCall(Ownable2Step.acceptOwnership, ()), _keys3(govKeys)),
            "acceptOwnership failed"
        );
        require(Ownable(target).owner() == address(GOV_SAFE), "ownership not transferred");
        console2.log("accepted ownership:", target);
    }

    /// @dev Slices the first 3 keys from the 5-key governance array.
    /// Centralises the 3-of-5 key selection used by _accept and Phase B.
    function _keys3(uint256[5] memory govKeys) private pure returns (uint256[] memory keys3) {
        keys3 = new uint256[](3);
        keys3[0] = govKeys[0];
        keys3[1] = govKeys[1];
        keys3[2] = govKeys[2];
    }
}
