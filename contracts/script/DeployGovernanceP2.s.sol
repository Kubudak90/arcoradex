// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Safe} from "@safe-global/safe-contracts/contracts/Safe.sol";

import {ArcoraDexPool} from "../src/ArcoraDexPool.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {MockChainlinkFeedV2} from "../src/testnet/MockChainlinkFeedV2.sol";
import {SafeSigHelpers} from "../test/governance/SafeSigHelpers.sol";
import {GovernanceFactory} from "./GovernanceFactory.sol";

/// @title DeployGovernanceP2 — parameterized ArcoraDEX governance bring-up
/// @notice Deploys the Gov Safe + Pause-Guardian Safe + Timelock and hands
/// Pool/Registry/feed ownership to them.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// M-1 (audit 2026-05-31) FIX — owners come from env ADDRESSES, NOT the mnemonic.
///
/// DEFAULT path: owners/thresholds are read from env (GOV_SAFE_OWNERS,
/// GOV_SAFE_THRESHOLD, PG_SAFE_OWNERS, PG_SAFE_THRESHOLD) via `GovernanceFactory`.
/// No private keys are needed — Safe owners sign off-chain afterwards. Because
/// the script does NOT hold the owner keys, it CANNOT drive the 3/5 Safe to
/// schedule+execute the Timelock setup ops; it deploys the Timelock directly at
/// the final `TIMELOCK_MIN_DELAY`, transfers Pool/Registry/feed ownership to the
/// new governance, and leaves the `acceptOwnership` (Ownable2Step) pending for
/// the real signers to run via the Gov Safe (see the printed NEXT-STEPS log).
///
/// OPT-IN path (`GOV_USE_TEST_MNEMONIC=true`, testnet throwaway only): owners are
/// derived from the PUBLIC Foundry test mnemonic. Because the script then holds
/// the keys, it runs the FULL self-contained flow (delay 0 → schedule+execute the
/// accepts/setPauseGuardian → lock down delay). Reverts on the mainnet chainid.
/// ─────────────────────────────────────────────────────────────────────────────
contract DeployGovernanceP2 is Script {
    using SafeSigHelpers for Safe;

    uint256 constant SIGNER_FUND_AMT = 0.1 ether;

    // Reused feed addresses from 2026-05-10 cutover (owners get transferred to GovSafe)
    address[7] FEEDS = [
        0x2E6B862E1Ac74328238494B22317262004534B39,
        0x741af784a1d4C69843A1764099433160088a1c70,
        0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896,
        0xAAC5a5855deF9414f7330f350c2E00119C2097c8,
        0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170,
        0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C,
        0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d
    ];

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        ArcoraDexPool pool = ArcoraDexPool(vm.envAddress("POOL_V3"));
        ArcoraDexRegistry reg = ArcoraDexRegistry(vm.envAddress("REGISTRY_V3"));

        // M-1: resolve governance owners/thresholds from env (real addresses by
        // default; public mnemonic ONLY behind the explicit opt-in flag).
        GovernanceFactory.Config memory gcfg = GovernanceFactory.resolveConfig();

        if (gcfg.usedTestMnemonic) {
            _runMnemonicSelfDriving(deployerKey, pool, reg, gcfg);
        } else {
            _runRealOwners(deployerKey, pool, reg, gcfg);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DEFAULT path — real env-provided owners (script holds no Safe keys)
    // ─────────────────────────────────────────────────────────────────────────
    /// @dev Deploys the stack at the FINAL Timelock delay, transfers
    /// Pool/Registry/feed ownership to the new governance, and leaves the
    /// Ownable2Step `acceptOwnership`s pending for the real signers to execute
    /// via the Gov Safe / Timelock. No signer funding (real signers fund their
    /// own gas).
    function _runRealOwners(
        uint256 deployerKey,
        ArcoraDexPool pool,
        ArcoraDexRegistry reg,
        GovernanceFactory.Config memory gcfg
    ) internal {
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Deploy Safes + Timelock directly at the final delay (no setup-phase
        // updateDelay op — the script can't drive the 3/5 Safe without keys).
        GovernanceFactory.Stack memory s = GovernanceFactory.deploy(gcfg, gcfg.timelockMinDelay);

        // Feed ownership → Gov Safe (transferOwnership only; the Safe accepts
        // off-chain). Done FIRST so a failure here leaves Pool/Registry still
        // deployer-owned (recoverable).
        for (uint256 i = 0; i < 7; i++) {
            MockChainlinkFeedV2 feed = MockChainlinkFeedV2(FEEDS[i]);
            address currentOwner = feed.owner();
            if (currentOwner == address(s.govSafe) || feed.pendingOwner() == address(s.govSafe)) {
                console2.log("feed already Safe-owned / pending, skipping:", FEEDS[i]);
                continue;
            }
            require(currentOwner == deployer, "feed owner is neither deployer nor Safe");
            feed.transferOwnership(address(s.govSafe));
        }

        // Pool + Registry: transferOwnership → Timelock (pending until accepted).
        pool.transferOwnership(address(s.timelock));
        reg.transferOwnership(address(s.timelock));

        vm.stopBroadcast();

        require(pool.pendingOwner() == address(s.timelock), "pool pendingOwner != timelock");
        require(reg.pendingOwner() == address(s.timelock), "registry pendingOwner != timelock");
        require(s.timelock.getMinDelay() == gcfg.timelockMinDelay, "timelock delay mismatch");

        console2.log("");
        console2.log("=== Governance deployed (real owners; pending accepts) ===");
        console2.log("Gov Safe:          ", address(s.govSafe));
        console2.log("Pause-Guardian Safe:", address(s.pgSafe));
        console2.log("Timelock:          ", address(s.timelock));
        console2.log("Pool pendingOwner -> Timelock:    ", pool.pendingOwner());
        console2.log("Registry pendingOwner -> Timelock:", reg.pendingOwner());
        console2.log("");
        console2.log("NEXT (real signers, off-chain via the Gov Safe 3/5):");
        console2.log("  1. Gov Safe execTransaction: feed.acceptOwnership() for each of the 7 feeds.");
        console2.log("  2. Gov Safe schedule+execute Timelock ops calling:");
        console2.log("       Pool.acceptOwnership(), Registry.acceptOwnership(),");
        console2.log("       Pool.setPauseGuardian(pgSafe).");
        console2.log("     NOTE: each Timelock op incurs the configured delay:", gcfg.timelockMinDelay);
        console2.log("     To minimize the wait, the operator MAY first run a setup-delay-0 deploy");
        console2.log("     then updateDelay once accepts are in; the default here ships the final delay.");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // OPT-IN path — public test mnemonic, script self-drives the 3/5 Safe
    // ─────────────────────────────────────────────────────────────────────────
    function _runMnemonicSelfDriving(
        uint256 deployerKey,
        ArcoraDexPool pool,
        ArcoraDexRegistry reg,
        GovernanceFactory.Config memory gcfg
    ) internal {
        // Re-derive the 5 gov keys so the script can sign the setup-phase Safe txs.
        uint256[5] memory govKeys;
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i] = vm.deriveKey(GovernanceFactory.TEST_MNEMONIC, uint32(i));
        }
        uint256[3] memory pgKeys;
        for (uint256 i = 0; i < 3; i++) {
            pgKeys[i] = vm.deriveKey(GovernanceFactory.TEST_MNEMONIC, uint32(5 + i));
        }

        vm.startBroadcast(deployerKey);

        // Fund signers — use .call to forward all gas (Arc testnet has code at
        // these well-known mnemonic-derived addresses, so .transfer's 2300
        // stipend OOMs).
        for (uint256 i = 0; i < 5; i++) {
            (bool ok,) = payable(gcfg.govOwners[i]).call{value: SIGNER_FUND_AMT}("");
            require(ok, "fund gov signer failed");
        }
        for (uint256 i = 0; i < 3; i++) {
            (bool ok,) = payable(gcfg.pgOwners[i]).call{value: SIGNER_FUND_AMT}("");
            require(ok, "fund pg signer failed");
        }
        console2.log("Funded 8 signers (0.1 ARC each)");

        // Deploy Safes + Timelock at delay 0 (setup phase), then lock down.
        GovernanceFactory.Stack memory s = GovernanceFactory.deploy(gcfg, 0);
        Safe governanceSafe = s.govSafe;
        TimelockController timelock = s.timelock;

        // Feed ownership → Gov Safe FIRST (transfer + Safe-driven accept).
        _transferFeedOwnership(governanceSafe, govKeys);

        // Pool + Registry: transferOwnership to Timelock, then accept via Safe.
        pool.transferOwnership(address(timelock));
        reg.transferOwnership(address(timelock));
        _scheduleAndExec(governanceSafe, govKeys, timelock, address(pool), abi.encodeCall(pool.acceptOwnership, ()));
        _scheduleAndExec(governanceSafe, govKeys, timelock, address(reg), abi.encodeCall(reg.acceptOwnership, ()));

        // setPauseGuardian
        _scheduleAndExec(
            governanceSafe, govKeys, timelock, address(pool), abi.encodeCall(pool.setPauseGuardian, (address(s.pgSafe)))
        );

        // Lockdown: updateDelay to the configured final delay.
        _scheduleAndExec(
            governanceSafe,
            govKeys,
            timelock,
            address(timelock),
            abi.encodeCall(TimelockController.updateDelay, (gcfg.timelockMinDelay))
        );

        vm.stopBroadcast();

        // Hard-fail final-state assertions.
        require(pool.owner() == address(timelock), "pool owner != timelock");
        require(reg.owner() == address(timelock), "registry owner != timelock");
        require(pool.pauseGuardian() == address(s.pgSafe), "pauseGuardian mismatch");
        require(timelock.getMinDelay() == gcfg.timelockMinDelay, "minDelay not locked down");

        console2.log("=== Final state (asserted) ===");
        console2.log("Pool owner:       ", pool.owner());
        console2.log("Registry owner:   ", reg.owner());
        console2.log("Pool pauseGuardian:", pool.pauseGuardian());
        console2.log("Timelock minDelay:", timelock.getMinDelay());
    }

    /// @dev Transfers all 7 feed ownerships to governanceSafe and accepts them.
    /// Re-runnable: skips any feed already owned by the Safe. Fails loudly if a
    /// feed is owned by neither the deployer nor the Safe.
    function _transferFeedOwnership(Safe governanceSafe, uint256[5] memory govKeys) internal {
        address safe = address(governanceSafe);
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        uint256[] memory acceptKeys = new uint256[](3);
        acceptKeys[0] = govKeys[0];
        acceptKeys[1] = govKeys[1];
        acceptKeys[2] = govKeys[2];

        for (uint256 i = 0; i < 7; i++) {
            MockChainlinkFeedV2 feed = MockChainlinkFeedV2(FEEDS[i]);
            address currentOwner = feed.owner();

            if (currentOwner == safe) {
                console2.log("feed already Safe-owned, skipping:", FEEDS[i]);
                continue;
            }

            require(currentOwner == deployer, "feed owner is neither deployer nor Safe");

            feed.transferOwnership(safe);
            require(
                governanceSafe.execCall(FEEDS[i], abi.encodeCall(Ownable2Step.acceptOwnership, ()), acceptKeys),
                "feed acceptOwnership failed"
            );
            require(feed.owner() == safe, "post-transfer owner check failed");
        }
    }

    /// @dev Schedules an action via Governance Safe at the current Timelock delay,
    /// then executes it (delay=0 setup mode).
    function _scheduleAndExec(
        Safe gov,
        uint256[5] memory govKeys,
        TimelockController timelock,
        address target,
        bytes memory call
    ) internal {
        uint256[] memory keys = new uint256[](3);
        keys[0] = govKeys[0];
        keys[1] = govKeys[1];
        keys[2] = govKeys[2];

        require(
            gov.execCall(
                address(timelock),
                abi.encodeCall(TimelockController.schedule, (target, 0, call, bytes32(0), bytes32(0), 0)),
                keys
            ),
            "schedule failed"
        );
        require(
            gov.execCall(
                address(timelock),
                abi.encodeCall(TimelockController.execute, (target, 0, call, bytes32(0), bytes32(0))),
                keys
            ),
            "execute failed"
        );
    }
}
