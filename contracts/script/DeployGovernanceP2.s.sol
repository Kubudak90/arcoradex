// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Safe} from "@safe-global/safe-contracts/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-contracts/contracts/proxies/SafeProxyFactory.sol";

import {ArcoraDexPool} from "../src/ArcoraDexPool.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {MockChainlinkFeedV2} from "../src/testnet/MockChainlinkFeedV2.sol";
import {SafeSigHelpers} from "../test/governance/SafeSigHelpers.sol";

contract DeployGovernanceP2 is Script {
    using SafeSigHelpers for Safe;

    // Foundry standard test mnemonic (NOT for mainnet — throwaway testnet wallets only).
    // All 12 words are valid BIP39 wordlist members.
    string constant MNEMONIC = "test test test test test test test test test test test junk";
    uint256 constant TIMELOCK_DELAY = 48 hours;
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

        vm.startBroadcast(deployerKey);

        // Steps 1-5: fund signers, deploy Safe infrastructure, deploy Timelock
        (Safe governanceSafe, Safe pauseGuardianSafe, TimelockController timelock, uint256[5] memory govKeys) =
            _deployInfra();

        // Step 6: Feed ownership → Governance Safe FIRST so a failure here leaves
        // Pool/Registry still owned by the deployer (recoverable). The Pool/Registry
        // handoff below is irreversible from the deployer's side once it lands.
        _transferFeedOwnership(governanceSafe, govKeys);

        // Step 7: Pool + Registry: transferOwnership to Timelock
        pool.transferOwnership(address(timelock));
        reg.transferOwnership(address(timelock));

        // Step 8: Governance Safe schedules + executes Pool/Registry acceptOwnership
        _scheduleAndExec(governanceSafe, govKeys, timelock, address(pool), abi.encodeCall(pool.acceptOwnership, ()));
        _scheduleAndExec(governanceSafe, govKeys, timelock, address(reg), abi.encodeCall(reg.acceptOwnership, ()));

        // Step 9: setPauseGuardian
        _scheduleAndExec(
            governanceSafe,
            govKeys,
            timelock,
            address(pool),
            abi.encodeCall(pool.setPauseGuardian, (address(pauseGuardianSafe)))
        );

        // Step 10: Lockdown: updateDelay(48h)
        _scheduleAndExec(
            governanceSafe,
            govKeys,
            timelock,
            address(timelock),
            abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY))
        );

        vm.stopBroadcast();

        // Hard-fail final-state assertions: catch encoder mistakes that would let
        // the broadcast succeed at the tx level but leave the system in a wrong state.
        require(pool.owner() == address(timelock), "pool owner != timelock");
        require(reg.owner() == address(timelock), "registry owner != timelock");
        require(pool.pauseGuardian() == address(pauseGuardianSafe), "pauseGuardian mismatch");
        require(timelock.getMinDelay() == TIMELOCK_DELAY, "minDelay not locked down");

        console2.log("=== Final state (asserted) ===");
        console2.log("Pool owner:       ", pool.owner());
        console2.log("Registry owner:   ", reg.owner());
        console2.log("Pool pauseGuardian:", pool.pauseGuardian());
        console2.log("Timelock minDelay:", timelock.getMinDelay());
    }

    /// @dev Deploys and funds signers, Safe singleton + factory, both Safes, and Timelock.
    /// Returns the two Safes, Timelock, and the 5 governance keys (for later use in run()).
    function _deployInfra()
        internal
        returns (Safe governanceSafe, Safe pauseGuardianSafe, TimelockController timelock, uint256[5] memory govKeys)
    {
        // Derive signers (8 total: 5 gov + 3 pg)
        address[5] memory govAddrs;
        uint256[3] memory pgKeys;
        address[3] memory pgAddrs;
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i] = vm.deriveKey(MNEMONIC, uint32(i));
            govAddrs[i] = vm.addr(govKeys[i]);
        }
        for (uint256 i = 0; i < 3; i++) {
            pgKeys[i] = vm.deriveKey(MNEMONIC, uint32(5 + i));
            pgAddrs[i] = vm.addr(pgKeys[i]);
        }

        // 1. Fund signers — use .call to forward all gas (Arc testnet has code at
        // these well-known mnemonic-derived addresses, so .transfer's 2300 stipend OOMs).
        for (uint256 i = 0; i < 5; i++) {
            (bool ok,) = payable(govAddrs[i]).call{value: SIGNER_FUND_AMT}("");
            require(ok, "fund gov signer failed");
        }
        for (uint256 i = 0; i < 3; i++) {
            (bool ok,) = payable(pgAddrs[i]).call{value: SIGNER_FUND_AMT}("");
            require(ok, "fund pg signer failed");
        }
        console2.log("Funded 8 signers (0.1 ARC each)");

        // 2. Deploy Safe singleton + factory
        Safe safeSingleton = new Safe();
        SafeProxyFactory factory = new SafeProxyFactory();
        console2.log("Safe singleton:", address(safeSingleton));
        console2.log("Safe factory:  ", address(factory));

        // 3. Governance Safe (3/5)
        {
            address[] memory govOwners = new address[](5);
            for (uint256 i = 0; i < 5; i++) {
                govOwners[i] = govAddrs[i];
            }
            bytes memory govSetup = abi.encodeCall(
                Safe.setup, (govOwners, 3, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
            );
            governanceSafe = Safe(payable(address(factory.createProxyWithNonce(address(safeSingleton), govSetup, 1))));
            console2.log("Governance Safe:", address(governanceSafe));
        }

        // 4. Pause Guardian Safe (2/3)
        {
            address[] memory pgOwners = new address[](3);
            for (uint256 i = 0; i < 3; i++) {
                pgOwners[i] = pgAddrs[i];
            }
            bytes memory pgSetup = abi.encodeCall(
                Safe.setup, (pgOwners, 2, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
            );
            pauseGuardianSafe = Safe(payable(address(factory.createProxyWithNonce(address(safeSingleton), pgSetup, 2))));
            console2.log("Pause Guardian Safe:", address(pauseGuardianSafe));
        }

        // 5. TimelockController (minDelay = 0 for setup)
        {
            address[] memory proposers = new address[](1);
            proposers[0] = address(governanceSafe);
            // L-8 (audit 2026-05-31): executor = Governance Safe (controlled
            // execution), NOT address(0) (open execution where any EOA could
            // execute a scheduled op after the delay). Execution now requires a
            // 3/5 Safe tx: less liveness, more control — acceptable here because
            // the same 3/5 Safe is already the sole proposer, so it is the
            // trust anchor for both ends of every Timelock op.
            address[] memory executors = new address[](1);
            executors[0] = address(governanceSafe);
            timelock = new TimelockController(0, proposers, executors, address(0));
            console2.log("Timelock:", address(timelock));
        }
    }

    /// @dev Transfers all 7 feed ownerships to governanceSafe and accepts them.
    /// Re-runnable: skips any feed already owned by the Safe (mirrors the
    /// P3GovernanceActions._accept idempotency pattern). Fails loudly if a feed
    /// is owned by neither the deployer nor the Safe — that indicates a partial
    /// or corrupt state that must not silently no-op.
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

            // transferOwnership is onlyOwner on Ownable2Step — sets pendingOwner.
            feed.transferOwnership(safe);

            // The Safe (the pendingOwner) calls acceptOwnership via the standard
            // execCall helper used elsewhere in this script.
            require(
                governanceSafe.execCall(FEEDS[i], abi.encodeCall(Ownable2Step.acceptOwnership, ()), acceptKeys),
                "feed acceptOwnership failed"
            );

            require(feed.owner() == safe, "post-transfer owner check failed");
        }
    }

    /// @dev Schedules an action via Governance Safe at the current Timelock delay,
    /// then executes it. Used in setup mode where delay=0 lets us schedule+execute
    /// in immediate succession.
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
