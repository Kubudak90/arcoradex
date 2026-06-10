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

/// @title ExecuteGovernanceAccepts — 2026-06-10 fresh-redeploy governance finalization
/// @notice One-shot driver for every multisig action the fresh redeploy left pending.
/// Arc testnet has NO hosted Safe UI, so Safe transactions are signed locally
/// (eth_sign over the safeTxHash by ≥threshold owner keys) and submitted as
/// `execTransaction` by the funded deployer EOA — the exact pattern the P2
/// governance tests exercise via `SafeSigHelpers`.
///
/// Sequence (delay-0 window — run BEFORE the Timelock is locked to 48h):
///   A. Gov Safe accepts the pending oracle-layer ownerships
///      (guard + 7 bounded primaries + 7 secondaries). Idempotent.
///   B. Gov Safe drives the Timelock (schedule+execute, delay 0) to accept
///      Pool + Registry ownership.
///   C. Pause drill: PG Safe pauses the Pool; Gov Safe unpauses it through the
///      Timelock (still delay 0, so no 48h wait).
///   D. Lockdown: Timelock.updateDelay(172800) — from here on every governance
///      op waits 48h.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY — broadcaster (pays gas; signatures carry authority)
///   GOV_OWNER_KEY_1..3   — three Gov Safe owner keys (shell-only export).
///                          All three must be Gov owners (3/5 threshold); at
///                          least two must also be PG owners (2/3 threshold).
contract ExecuteGovernanceAccepts is Script {
    using SafeSigHelpers for Safe;

    // ── 2026-06-10 fresh ledger ──────────────────────────────────────────────
    Safe constant GOV_SAFE = Safe(payable(0x396145BAB316d84F958368d93ec8984559f0261B));
    Safe constant PG_SAFE = Safe(payable(0x1098e88b8b243451109D7eA7690f9e2ca7b18280));
    TimelockController constant TIMELOCK = TimelockController(payable(0xEb2E77144F5BcB854ED75C687988c4F19100e5D7));
    address constant POOL = 0x214825E3e24a07cd58e48267e492320dAccCe2f6;
    address constant REGISTRY = 0x372f83a1432Aa43b72eDCE083DC8352d9Bfb47f1;
    address constant GUARD = 0x06f4EbCd1780721ab2eCDd776294699d2697761d;

    uint256 constant FINAL_DELAY = 172_800; // 48h

    function _pendingAccepts() internal pure returns (address[15] memory a) {
        a[0] = GUARD;
        // bounded primary feeds
        a[1] = 0xa57B5b023335DAeadE30024b11eA9caC2Eb08212; // USDC
        a[2] = 0x9Fb7FF1Fab0f8557a73aaa8299ED3Aa7deA1c611; // USDT
        a[3] = 0x054818FB22De2Ab111362FE05DeD221d51d7fd43; // PYUSD
        a[4] = 0xfd7701ed4685a4240294F1010bA62AF3BfD398f2; // DAI
        a[5] = 0xBdFCa92587CDcF4ed150343A30B19F29C80917aD; // EURC
        a[6] = 0x9B5d25E1e58D32F5B9624943FEeD5D27350BC5ED; // TRYC
        a[7] = 0x3ff4d256b4cC25ab0f0Fff5aB7D3bAf35CA5d329; // BRLC
        // secondary feeds
        a[8] = 0x344634C00573A1678a9B3594c7bC070c608B1708;
        a[9] = 0x0D2118E485fD4cb7F40a73ECAc2Eae330A97F717;
        a[10] = 0x612Dd283afFe8235b70A9Cf3ccEa9f0cE9fa271e;
        a[11] = 0x67a1744363830B63809BC01FDd7020Ea8eF4bd91;
        a[12] = 0x56eD0616119924bD69E440123274E9dABA97a80C;
        a[13] = 0x1f218DD7DD6858D67912496a49c3F8bc8500Ea0e;
        a[14] = 0xCbdD7381766f3021C5fae2a5bBeAe5CF0Fc20bcF;
    }

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");

        uint256 broadcaster = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256[] memory govKeys = new uint256[](3);
        govKeys[0] = vm.envUint("GOV_OWNER_KEY_1");
        govKeys[1] = vm.envUint("GOV_OWNER_KEY_2");
        govKeys[2] = vm.envUint("GOV_OWNER_KEY_3");

        // ── Validate signer sets against BOTH Safes ──────────────────────────
        uint256 pgCount = 0;
        uint256[] memory pgKeys = new uint256[](2);
        for (uint256 i = 0; i < 3; i++) {
            address signer = vm.addr(govKeys[i]);
            require(GOV_SAFE.isOwner(signer), "key is not a Gov Safe owner");
            if (PG_SAFE.isOwner(signer) && pgCount < 2) {
                pgKeys[pgCount++] = govKeys[i];
            }
            console2.log("signer ok:", signer);
        }
        require(pgCount == 2, "need >=2 keys that are also PG Safe owners");
        require(GOV_SAFE.getThreshold() == 3 && PG_SAFE.getThreshold() == 2, "unexpected thresholds");

        vm.startBroadcast(broadcaster);

        _phaseA_oracleAccepts(govKeys);
        _phaseB_poolRegistryAccept(govKeys);
        _phaseC_pauseDrill(govKeys, pgKeys);
        _phaseD_lockdown(govKeys);

        vm.stopBroadcast();

        _finalAsserts();
    }

    // ── A. oracle-layer acceptOwnership via Gov Safe (idempotent) ───────────
    function _phaseA_oracleAccepts(uint256[] memory govKeys) internal {
        console2.log("--- A. oracle-layer accepts (guard + 14 feeds) ---");
        address[15] memory targets = _pendingAccepts();
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

    // ── B. Pool + Registry accept via Timelock (delay 0) ────────────────────
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
        _timelockBatchViaGovSafe(targets, values, payloads, keccak256("arcora.2026-06-10.accept"), govKeys);
        require(IOwnable2StepLike(POOL).owner() == address(TIMELOCK), "Pool owner != Timelock");
        require(IOwnable2StepLike(REGISTRY).owner() == address(TIMELOCK), "Registry owner != Timelock");
        console2.log("  Pool + Registry now owned by the Timelock");
    }

    // ── C. pause drill: PG pauses, Gov unpauses through the Timelock ────────
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
        _timelockBatchViaGovSafe(targets, values, payloads, keccak256("arcora.2026-06-10.unpause"), govKeys);
        require(!pool.paused(), "unpause did not land");
        console2.log("  Gov Safe unpaused via Timelock: ok");
    }

    // ── D. lock the Timelock to 48h ──────────────────────────────────────────
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
        _timelockBatchViaGovSafe(targets, values, payloads, keccak256("arcora.2026-06-10.delay48h"), govKeys);
        require(TIMELOCK.getMinDelay() == FINAL_DELAY, "delay not 48h");
        console2.log("  Timelock min delay locked to 48h");
    }

    /// @dev Gov Safe schedules then executes one Timelock batch. Valid only
    /// while the Timelock delay is 0 (the launch window) — schedule and execute
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
        require(IOwnable2StepLike(GUARD).owner() == address(GOV_SAFE), "final: guard owner");
        require(TIMELOCK.getMinDelay() == FINAL_DELAY, "final: delay");
        require(!IPoolPauseLike(POOL).paused(), "final: pool paused");
        console2.log("Pool/Registry owner == Timelock: ok");
        console2.log("Oracle layer owner == Gov Safe: ok");
        console2.log("Timelock delay == 48h: ok");
        console2.log("Pool unpaused, drill complete: ok");
        console2.log("Governance finalization COMPLETE.");
    }
}
