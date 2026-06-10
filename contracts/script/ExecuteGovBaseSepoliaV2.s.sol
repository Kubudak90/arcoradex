// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Safe} from "@safe-global/safe-contracts/contracts/Safe.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {SafeSigHelpers} from "../test/governance/SafeSigHelpers.sol";

interface IOwnable2StepLike {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
}

interface IPoolPauseLike {
    function paused() external view returns (bool);
    function pauseGuardian() external view returns (address);
    function pause() external;
    function unpause() external;
}

/// @title ExecuteGovBaseSepoliaV2 - LIVE Base Sepolia V2 governance finalization
/// @notice One-shot driver for every multisig action the live Base Sepolia V2
/// deploy left pending. Modeled exactly on the proven Arc ExecuteGovernanceAccepts
/// script. Base Sepolia has no project-hosted Safe UI in this flow, so Safe
/// transactions are signed locally (eth_sign over the safeTxHash by >=threshold
/// owner keys) and submitted as `execTransaction` by the funded deployer EOA - the
/// exact pattern the P2 governance tests exercise via `SafeSigHelpers`.
///
/// This deploy used GOV_USE_TEST_MNEMONIC=true, so all Safe owners are derived
/// from the public Foundry test mnemonic. Gov owners = HD indices 0-4 (3/5: use
/// 0,1,2); PG owners = HD indices 5-7 (2/3: use 5,6). The Gov and PG owner sets
/// are DISJOINT here (unlike Arc), so signer keys are derived per-Safe.
///
/// Sequence (delay-0 window - run BEFORE the Timelock is locked to 48h):
///   A. Gov Safe accepts the 3 oracle adapters (pendingOwner = Gov Safe). Idempotent.
///      The V2 oracle layer is JUST the 3 adapters - there is no guard/feed accept
///      list. The EURC mock Chainlink leg stays deployer-owned by design; it is NOT
///      accepted here.
///   B. Gov Safe drives the Timelock (schedule+execute, delay 0) to accept
///      Pool + Registry ownership.
///   C. Pause drill: PG Safe pauses the Pool; Gov Safe unpauses it through the
///      Timelock (still delay 0, so no 48h wait).
///   D. Lockdown: Timelock.updateDelay(172800) - from here on every governance
///      op waits 48h.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY - broadcaster (pays gas; the Safe signatures carry the
///                          authority). Signer keys are derived from the public
///                          test mnemonic - NO env keys for signers.
contract ExecuteGovBaseSepoliaV2 is Script {
    using SafeSigHelpers for Safe;

    // The public Foundry test mnemonic this deploy used (GOV_USE_TEST_MNEMONIC=true).
    string constant TEST_MNEMONIC = "test test test test test test test test test test test junk";

    // -- Base Sepolia live ledger -------------------------------------------------
    Safe constant GOV_SAFE = Safe(payable(0x262d4069348093D1Fe8860EEB7483ce1FEd068d2));
    Safe constant PG_SAFE = Safe(payable(0x1516Bc7e614ba71AE95dD226df7F783FeD32c01c));
    TimelockController constant TIMELOCK = TimelockController(payable(0x62Bf16e9921A1b9C2d8ec58e84b155AE9c9FbaD6));
    address constant POOL = 0x63FD6180dC6Aa5aE2941Bd28D2dc34c54F2b7820;
    address constant REGISTRY = 0xae1f10b007cDC4131797A45232a3D52Ff2C314e2;

    uint256 constant FINAL_DELAY = 172_800; // 48h

    /// @dev The V2 oracle layer is exactly the 3 ChainlinkPythAdapterV2 adapters
    /// (USDC / USDT / EURC). There is NO guard/feed accept list like Arc.
    function _pendingAccepts() internal pure returns (address[3] memory a) {
        a[0] = 0x7C5eAf40638Bb99595F1cD7d08d4C72e3833577e; // USDC adapter
        a[1] = 0x4D350eA1BfEb3ccE076d4bd3ade26FFcedb1C4C9; // USDT adapter
        a[2] = 0xf141246C632d19157C1222591CFab64e3025C108; // EURC adapter
    }

    /// @dev Tolerant private-key reader: accepts the 64-hex key with or without
    /// a 0x/0X prefix and ignores surrounding whitespace/newlines - wallet
    /// exports and shell paste paths disagree on the prefix, and a strict
    /// envUint read turns that into an opaque parse revert. Used ONLY for the
    /// broadcaster - signer keys come from the test mnemonic.
    function _envKey(string memory name) internal view returns (uint256 k) {
        bytes memory b = bytes(vm.envString(name));
        uint256 start = 0;
        while (start < b.length && (b[start] == 0x20 || b[start] == 0x09 || b[start] == 0x0a || b[start] == 0x0d)) {
            start++;
        }
        if (b.length >= start + 2 && b[start] == "0" && (b[start + 1] == "x" || b[start + 1] == "X")) {
            start += 2;
        }
        require(b.length >= start + 64, string.concat(name, ": expected 64 hex chars (got too few)"));
        bytes memory hexPart = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            hexPart[i] = b[start + i];
        }
        k = vm.parseUint(string.concat("0x", string(hexPart)));
        require(k != 0, string.concat(name, " parses to zero"));
    }

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");

        uint256 broadcaster = _envKey("DEPLOYER_PRIVATE_KEY");

        // -- Signers from the public test mnemonic (NO env keys for signers) -------
        // Gov owners = HD indices 0-4; take 0,1,2 for the 3/5 threshold.
        uint256[] memory govKeys = new uint256[](3);
        govKeys[0] = vm.deriveKey(TEST_MNEMONIC, 0);
        govKeys[1] = vm.deriveKey(TEST_MNEMONIC, 1);
        govKeys[2] = vm.deriveKey(TEST_MNEMONIC, 2);
        // PG owners = HD indices 5-7; take 5,6 for the 2/3 threshold.
        uint256[] memory pgKeys = new uint256[](2);
        pgKeys[0] = vm.deriveKey(TEST_MNEMONIC, 5);
        pgKeys[1] = vm.deriveKey(TEST_MNEMONIC, 6);

        // -- Validate signer sets against each Safe (sets are DISJOINT here) -------
        for (uint256 i = 0; i < govKeys.length; i++) {
            address signer = vm.addr(govKeys[i]);
            require(GOV_SAFE.isOwner(signer), "gov key is not a Gov Safe owner");
            console2.log("gov signer ok:", signer);
        }
        for (uint256 i = 0; i < pgKeys.length; i++) {
            address signer = vm.addr(pgKeys[i]);
            require(PG_SAFE.isOwner(signer), "pg key is not a PG Safe owner");
            console2.log("pg signer ok:", signer);
        }
        require(GOV_SAFE.getThreshold() == 3 && PG_SAFE.getThreshold() == 2, "unexpected thresholds");

        vm.startBroadcast(broadcaster);

        _phaseA_adapterAccepts(govKeys);
        _phaseB_poolRegistryAccept(govKeys);
        _phaseC_pauseDrill(govKeys, pgKeys);
        _phaseD_lockdown(govKeys);

        vm.stopBroadcast();

        _finalAsserts();
    }

    // -- A. adapter acceptOwnership via Gov Safe (idempotent) --------------------
    function _phaseA_adapterAccepts(uint256[] memory govKeys) internal {
        console2.log("--- A. oracle-adapter accepts (USDC + USDT + EURC) ---");
        address[3] memory targets = _pendingAccepts();
        for (uint256 i = 0; i < targets.length; i++) {
            IOwnable2StepLike t = IOwnable2StepLike(targets[i]);
            if (t.owner() == address(GOV_SAFE)) {
                console2.log("  already accepted:", targets[i]);
                continue;
            }
            require(t.pendingOwner() == address(GOV_SAFE), "pendingOwner != Gov Safe");
            require(
                GOV_SAFE.execCall(targets[i], abi.encodeCall(IOwnable2StepLike.acceptOwnership, ()), govKeys),
                "Safe execTransaction failed"
            );
            require(t.owner() == address(GOV_SAFE), "accept did not land");
            console2.log("  accepted:", targets[i]);
        }
    }

    // -- B. Pool + Registry accept via Timelock (delay 0) -----------------------
    function _phaseB_poolRegistryAccept(uint256[] memory govKeys) internal {
        console2.log("--- B. Pool + Registry acceptOwnership via Timelock ---");
        if (
            IOwnable2StepLike(POOL).owner() == address(TIMELOCK)
                && IOwnable2StepLike(REGISTRY).owner() == address(TIMELOCK)
        ) {
            console2.log("  already owned by Timelock - skip");
            return;
        }
        address[] memory targets = new address[](2);
        targets[0] = POOL;
        targets[1] = REGISTRY;
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(IOwnable2StepLike.acceptOwnership, ());
        payloads[1] = abi.encodeCall(IOwnable2StepLike.acceptOwnership, ());
        _timelockBatchViaGovSafe(targets, values, payloads, keccak256("arcora.base-sepolia-v2.accept"), govKeys);
        require(IOwnable2StepLike(POOL).owner() == address(TIMELOCK), "Pool owner != Timelock");
        require(IOwnable2StepLike(REGISTRY).owner() == address(TIMELOCK), "Registry owner != Timelock");
        console2.log("  Pool + Registry now owned by the Timelock");
    }

    // -- C. pause drill: PG pauses, Gov unpauses through the Timelock -----------
    function _phaseC_pauseDrill(uint256[] memory govKeys, uint256[] memory pgKeys) internal {
        console2.log("--- C. pause drill ---");
        IPoolPauseLike pool = IPoolPauseLike(POOL);
        require(pool.pauseGuardian() == address(PG_SAFE), "pool.pauseGuardian != PG Safe");
        require(!pool.paused(), "pool already paused before drill");

        require(PG_SAFE.execCall(POOL, abi.encodeCall(IPoolPauseLike.pause, ()), pgKeys), "PG pause exec failed");
        require(pool.paused(), "pause did not land");
        console2.log("  PG Safe paused the pool: ok");

        address[] memory targets = new address[](1);
        targets[0] = POOL;
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(IPoolPauseLike.unpause, ());
        _timelockBatchViaGovSafe(targets, values, payloads, keccak256("arcora.base-sepolia-v2.unpause"), govKeys);
        require(!pool.paused(), "unpause did not land");
        console2.log("  Gov Safe unpaused via Timelock: ok");
    }

    // -- D. lock the Timelock to 48h --------------------------------------------
    function _phaseD_lockdown(uint256[] memory govKeys) internal {
        console2.log("--- D. Timelock.updateDelay(172800) ---");
        if (TIMELOCK.getMinDelay() == FINAL_DELAY) {
            console2.log("  already 48h - skip");
            return;
        }
        address[] memory targets = new address[](1);
        targets[0] = address(TIMELOCK);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(TimelockController.updateDelay, (FINAL_DELAY));
        _timelockBatchViaGovSafe(targets, values, payloads, keccak256("arcora.base-sepolia-v2.delay48h"), govKeys);
        require(TIMELOCK.getMinDelay() == FINAL_DELAY, "delay not 48h");
        console2.log("  Timelock min delay locked to 48h");
    }

    /// @dev Gov Safe schedules then executes one Timelock batch. Valid only
    /// while the Timelock delay is 0 (the launch window) - schedule and execute
    /// land back-to-back in the same broadcast.
    function _timelockBatchViaGovSafe(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 salt,
        uint256[] memory govKeys
    ) internal {
        bytes32 id = TIMELOCK.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        if (!TIMELOCK.isOperation(id)) {
            require(
                GOV_SAFE.execCall(
                    address(TIMELOCK),
                    abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), salt, 0)),
                    govKeys
                ),
                "scheduleBatch exec failed"
            );
        }
        require(TIMELOCK.isOperationReady(id), "batch not ready (is the delay still 0?)");
        require(
            GOV_SAFE.execCall(
                address(TIMELOCK),
                abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, bytes32(0), salt)),
                govKeys
            ),
            "executeBatch exec failed"
        );
        require(TIMELOCK.isOperationDone(id), "batch not done");
    }

    function _finalAsserts() internal view {
        console2.log("");
        console2.log("=== FINAL STATE ===");
        require(IOwnable2StepLike(POOL).owner() == address(TIMELOCK), "final: Pool owner");
        require(IOwnable2StepLike(REGISTRY).owner() == address(TIMELOCK), "final: Registry owner");
        address[3] memory adapters = _pendingAccepts();
        for (uint256 i = 0; i < adapters.length; i++) {
            require(IOwnable2StepLike(adapters[i]).owner() == address(GOV_SAFE), "final: adapter owner");
        }
        require(TIMELOCK.getMinDelay() == FINAL_DELAY, "final: delay");
        require(!IPoolPauseLike(POOL).paused(), "final: pool paused");
        console2.log("Pool/Registry owner == Timelock: ok");
        console2.log("Adapters (3) owner == Gov Safe: ok");
        console2.log("Timelock delay == 48h: ok");
        console2.log("Pool unpaused, drill complete: ok");
        console2.log("Governance finalization COMPLETE.");
    }
}
