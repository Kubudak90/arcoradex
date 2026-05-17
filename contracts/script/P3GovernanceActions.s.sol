// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { OracleAggregator }          from "../src/oracle/OracleAggregator.sol";
import { CumulativeDeviationGuard }  from "../src/oracle/CumulativeDeviationGuard.sol";
import { ArcoraDexRegistry }         from "../src/ArcoraDexRegistry.sol";
import { IChainlinkAggregator }      from "../src/interfaces/IChainlinkAggregator.sol";
import { SafeSigHelpers }            from "../test/governance/SafeSigHelpers.sol";

/// @notice Phase 3 operational script. Phase A: Governance Safe accepts
/// ownership of the 15 P3 contracts (guard + 7 aggregators + 7 secondary
/// feeds). Phase B: Governance Safe schedules, through the 48h Timelock,
/// a 9-operation batch on the Registry — 7 setOracle (point each token
/// at its aggregator) + 2 setDeviation (tighten TRYC/BRLC caps to 200).
///
/// P3 contract addresses are read from env vars set by the operator after
/// the DeployOraclesP3.s.sol broadcast (P3_GUARD, P3_SECONDARY_*, P3_AGG_*).
/// Execution of the scheduled batch happens 48h later (separate step).
///
/// Required env: DEPLOYER_PRIVATE_KEY, P3_GUARD, P3_SECONDARY_<SYM>x7,
/// P3_AGG_<SYM>x7.
contract P3GovernanceActions is Script {
    using SafeSigHelpers for Safe;

    string constant MNEMONIC =
        "test test test test test test test test test test test junk";

    Safe              constant GOV_SAFE  = Safe(payable(0x715f669D79Cc72d6685F8724c0B86f7B53d7e624));
    TimelockController constant TIMELOCK = TimelockController(payable(0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83));
    ArcoraDexRegistry  constant REGISTRY = ArcoraDexRegistry(0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB);

    // TRYC index = 5, BRLC index = 6 (matching TOKENS order below)
    address[7] TOKENS = [
        0x3BFa09fF6467639f0981948385bA1018Ac07d22C,  // USDC
        0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B,  // USDT
        0xfdB2c86d010698401f0b969348DC58b6659B96a3,  // PYUSD
        0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE,  // DAI
        0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD,  // EURC
        0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61,  // TRYC
        0xa13c0935A98e2c175b31A4054f698819271a8FfC   // BRLC
    ];

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address GUARD = vm.envAddress("P3_GUARD");
        address[7] memory SECONDARIES = [
            vm.envAddress("P3_SECONDARY_USDC"),
            vm.envAddress("P3_SECONDARY_USDT"),
            vm.envAddress("P3_SECONDARY_PYUSD"),
            vm.envAddress("P3_SECONDARY_DAI"),
            vm.envAddress("P3_SECONDARY_EURC"),
            vm.envAddress("P3_SECONDARY_TRYC"),
            vm.envAddress("P3_SECONDARY_BRLC")
        ];
        address[7] memory AGGREGATORS = [
            vm.envAddress("P3_AGG_USDC"),
            vm.envAddress("P3_AGG_USDT"),
            vm.envAddress("P3_AGG_PYUSD"),
            vm.envAddress("P3_AGG_DAI"),
            vm.envAddress("P3_AGG_EURC"),
            vm.envAddress("P3_AGG_TRYC"),
            vm.envAddress("P3_AGG_BRLC")
        ];

        // Derive the 5 governance signer keys from the standard test mnemonic
        // (matches the P2 governance Safe deployment).
        uint256[5] memory govKeys;
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i] = vm.deriveKey(MNEMONIC, uint32(i));
        }

        vm.startBroadcast(deployerKey);

        // ── Phase A: Governance Safe accepts ownership of all 15 P3 contracts ──
        // Order: guard first, then aggregator+secondary per token (14 calls).
        _accept(GUARD, govKeys);
        for (uint256 i = 0; i < 7; i++) {
            _accept(AGGREGATORS[i], govKeys);
            _accept(SECONDARIES[i], govKeys);
        }
        console2.log("Phase A: Governance Safe accepted ownership of 15 contracts");

        // ── Phase B: schedule 9-operation batch through the 48h Timelock ──
        // 7 x Registry.setOracle  (point each token at its new OracleAggregator)
        // 2 x Registry.setDeviation (tighten TRYC [5] and BRLC [6] caps to 200 bps)
        address[] memory targets = new address[](9);
        uint256[] memory values  = new uint256[](9);
        bytes[]   memory payloads = new bytes[](9);

        for (uint256 i = 0; i < 7; i++) {
            targets[i]  = address(REGISTRY);
            values[i]   = 0;
            payloads[i] = abi.encodeCall(
                ArcoraDexRegistry.setOracle,
                (TOKENS[i], IChainlinkAggregator(AGGREGATORS[i]))
            );
        }
        // TRYC -> 200 bps
        targets[7]   = address(REGISTRY);
        values[7]    = 0;
        payloads[7]  = abi.encodeCall(ArcoraDexRegistry.setDeviation, (TOKENS[5], uint16(200)));
        // BRLC -> 200 bps
        targets[8]   = address(REGISTRY);
        values[8]    = 0;
        payloads[8]  = abi.encodeCall(ArcoraDexRegistry.setDeviation, (TOKENS[6], uint16(200)));

        bytes memory schedBatchCall = abi.encodeCall(
            TimelockController.scheduleBatch,
            (targets, values, payloads, bytes32(0), bytes32(0), 48 hours)
        );

        uint256[] memory keys3 = new uint256[](3);
        keys3[0] = govKeys[0];
        keys3[1] = govKeys[1];
        keys3[2] = govKeys[2];
        require(
            GOV_SAFE.execCall(address(TIMELOCK), schedBatchCall, keys3),
            "scheduleBatch failed"
        );
        console2.log("Phase B: scheduled 9-operation batch through Timelock (48h delay)");

        bytes32 batchId = TIMELOCK.hashOperationBatch(targets, values, payloads, bytes32(0), bytes32(0));
        console2.log("Batch id (executable after 48h):");
        console2.logBytes32(batchId);

        vm.stopBroadcast();
    }

    /// @dev Have the Governance Safe accept ownership of `target` (Ownable2Step).
    function _accept(address target, uint256[5] memory govKeys) internal {
        uint256[] memory keys3 = new uint256[](3);
        keys3[0] = govKeys[0];
        keys3[1] = govKeys[1];
        keys3[2] = govKeys[2];
        require(
            GOV_SAFE.execCall(target, abi.encodeWithSignature("acceptOwnership()"), keys3),
            "acceptOwnership failed"
        );
    }
}
