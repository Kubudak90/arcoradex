// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Safe} from "@safe-global/safe-contracts/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-contracts/contracts/proxies/SafeProxyFactory.sol";

/// @title GovernanceFactory — parameterized ArcoraDEX governance deployment
/// @notice Shared internal helper used by BOTH `DeployGovernanceP2.s.sol` and the
/// turnkey `DeployPublicTestnet.s.sol` orchestrator (mirrors the existing
/// `_cfg()` / `_aggWiring()` factoring: one source of truth both call sites and
/// the tests exercise).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// M-1 (audit 2026-05-31) ROOT-CAUSE FIX
///
/// The legacy `DeployGovernanceP2` derived the 3-of-5 Gov Safe + 2-of-3
/// Pause-Guardian Safe owners from the PUBLIC Foundry test mnemonic
/// ("test test ... junk"). Anyone can reconstruct those keys → instant
/// governance takeover. This factory makes the DEFAULT path use REAL,
/// env-provided owner ADDRESSES (no private keys needed at deploy time — Safe
/// owners sign off-chain later), and gates the public-mnemonic derivation behind
/// an explicit `GOV_USE_TEST_MNEMONIC=true` opt-in with a loud warning + a
/// mainnet guard, so a real deploy can NEVER silently ship the mnemonic.
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Env consumed by `resolveConfig()`:
///   GOV_SAFE_OWNERS       — comma-separated addresses (the 3-of-5 Gov Safe owners)
///   GOV_SAFE_THRESHOLD    — uint (signatures required; default path)
///   PG_SAFE_OWNERS        — comma-separated addresses (the 2-of-3 Pause-Guardian owners)
///   PG_SAFE_THRESHOLD     — uint
///   TIMELOCK_MIN_DELAY    — uint seconds (default 48h = 172800)
///   GOV_USE_TEST_MNEMONIC — "true" to OPT IN to the public-mnemonic derivation
///                           (testnet-only; reverts on the mainnet chainid)
library GovernanceFactory {
    /// @dev Forge's deterministic Vm address (libraries can't inherit Script).
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// Foundry standard test mnemonic — PUBLIC, throwaway only. Reachable ONLY
    /// behind the explicit GOV_USE_TEST_MNEMONIC opt-in (see resolveConfig).
    string constant TEST_MNEMONIC = "test test test test test test test test test test test junk";

    /// Default Timelock min delay if TIMELOCK_MIN_DELAY is unset (48h).
    uint256 constant DEFAULT_TIMELOCK_MIN_DELAY = 48 hours;

    /// Chain id the mnemonic path must NEVER run on (Ethereum mainnet). Defense
    /// in depth: the orchestrators already require the Arc-testnet chainid, but a
    /// future reuse of this factory must also refuse the public mnemonic on a
    /// production chain.
    uint256 constant MAINNET_CHAINID = 1;

    /// @notice Resolved governance config: who owns each Safe + the thresholds +
    /// the Timelock delay. Pure data — no contracts deployed yet.
    struct Config {
        address[] govOwners;
        uint256 govThreshold;
        address[] pgOwners;
        uint256 pgThreshold;
        uint256 timelockMinDelay;
        bool usedTestMnemonic; // true only when the explicit opt-in was taken
    }

    /// @notice The deployed governance stack.
    struct Stack {
        Safe govSafe;
        Safe pgSafe;
        TimelockController timelock;
        Safe safeSingleton;
        SafeProxyFactory factory;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Config resolution (env → validated Config)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Resolve the governance config from env. DEFAULT path = real,
    /// env-provided owner ADDRESSES. The public-mnemonic derivation is reachable
    /// ONLY via the explicit `GOV_USE_TEST_MNEMONIC=true` opt-in.
    /// @dev Thin env-reading shell over the pure `buildConfig` (the env reads are
    /// the only non-deterministic part; all validation + mnemonic-derivation
    /// logic lives in `buildConfig` so it is unit-testable without mutating the
    /// shared process env).
    function resolveConfig() internal view returns (Config memory cfg) {
        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", DEFAULT_TIMELOCK_MIN_DELAY);
        bool useMnemonic = vm.envOr("GOV_USE_TEST_MNEMONIC", false);

        if (useMnemonic) {
            // Mnemonic owners are derived inside buildConfig; pass empties.
            address[] memory empty = new address[](0);
            cfg = buildConfig(empty, 0, empty, 0, minDelay, true);
        } else {
            cfg = buildConfig(
                vm.envAddress("GOV_SAFE_OWNERS", ","),
                vm.envUint("GOV_SAFE_THRESHOLD"),
                vm.envAddress("PG_SAFE_OWNERS", ","),
                vm.envUint("PG_SAFE_THRESHOLD"),
                minDelay,
                false
            );
        }
    }

    /// @notice Pure config builder: validates + (optionally) derives the public
    /// mnemonic owners. DEFAULT (useTestMnemonic=false) uses the passed-in real
    /// owner ADDRESSES. OPT-IN (useTestMnemonic=true) derives the 5 gov + 3 pg
    /// owners from the PUBLIC Foundry mnemonic (testnet throwaway; reverts on the
    /// mainnet chainid + emits a loud warning). Validates owners/thresholds for
    /// BOTH Safes via `_validate`.
    function buildConfig(
        address[] memory govOwners,
        uint256 govThreshold,
        address[] memory pgOwners,
        uint256 pgThreshold,
        uint256 timelockMinDelay,
        bool useTestMnemonic
    ) internal view returns (Config memory cfg) {
        cfg.timelockMinDelay = timelockMinDelay;

        if (useTestMnemonic) {
            // ── OPT-IN: public-mnemonic derivation (testnet throwaway only). ──
            require(block.chainid != MAINNET_CHAINID, "GovernanceFactory: test mnemonic forbidden on mainnet");
            console2.log("");
            console2.log("################################################################");
            console2.log("## WARNING: GOV_USE_TEST_MNEMONIC=true                        ##");
            console2.log("## Deriving Gov/PG Safe owners from the PUBLIC Foundry test    ##");
            console2.log("## mnemonic. These keys are KNOWN TO EVERYONE. Throwaway       ##");
            console2.log("## testnet use ONLY. A real launch MUST pass GOV_SAFE_OWNERS.  ##");
            console2.log("################################################################");
            console2.log("");

            cfg.govOwners = new address[](5);
            for (uint256 i = 0; i < 5; i++) {
                cfg.govOwners[i] = vm.addr(vm.deriveKey(TEST_MNEMONIC, uint32(i)));
            }
            cfg.govThreshold = 3;

            cfg.pgOwners = new address[](3);
            for (uint256 i = 0; i < 3; i++) {
                cfg.pgOwners[i] = vm.addr(vm.deriveKey(TEST_MNEMONIC, uint32(5 + i)));
            }
            cfg.pgThreshold = 2;
            cfg.usedTestMnemonic = true;
        } else {
            // ── DEFAULT: real owner ADDRESSES (no private keys at deploy time). ──
            cfg.govOwners = govOwners;
            cfg.govThreshold = govThreshold;
            cfg.pgOwners = pgOwners;
            cfg.pgThreshold = pgThreshold;
            cfg.usedTestMnemonic = false;
        }

        _validate(cfg.govOwners, cfg.govThreshold, "GOV");
        _validate(cfg.pgOwners, cfg.pgThreshold, "PG");
    }

    /// @dev Sanity-check a Safe owner set + threshold. Reverts loudly on any
    /// misconfiguration so a bad env can never produce a broken/seizable Safe.
    function _validate(address[] memory owners, uint256 threshold, string memory tag) internal pure {
        require(owners.length > 0, string.concat(tag, "_SAFE_OWNERS empty"));
        require(threshold >= 1, string.concat(tag, "_SAFE_THRESHOLD < 1"));
        require(threshold <= owners.length, string.concat(tag, "_SAFE_THRESHOLD > owners.length"));
        for (uint256 i = 0; i < owners.length; i++) {
            require(owners[i] != address(0), string.concat(tag, "_SAFE_OWNERS contains zero address"));
            for (uint256 j = i + 1; j < owners.length; j++) {
                require(owners[i] != owners[j], string.concat(tag, "_SAFE_OWNERS contains duplicate"));
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deployment (Config → on-chain Safes + Timelock)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploy a fresh Safe singleton + factory, the Gov Safe, the
    /// Pause-Guardian Safe, and a TimelockController wired with
    /// proposer = Gov Safe, executor = Gov Safe (L-8: NOT address(0)),
    /// admin = address(0).
    /// @dev MUST be called inside an active `vm.startBroadcast(...)` (the caller
    /// owns the broadcast lifecycle, matching the orchestrator's other steps).
    /// `minDelay` is the Timelock delay to construct WITH. The orchestrators
    /// deploy with delay 0 for the setup phase (schedule+execute in succession)
    /// then lock it down to `cfg.timelockMinDelay` via an `updateDelay` op — so
    /// pass 0 here for the setup-then-lockdown flow.
    function deploy(Config memory cfg, uint256 minDelayAtConstruction) internal returns (Stack memory s) {
        s.safeSingleton = new Safe();
        s.factory = new SafeProxyFactory();

        s.govSafe = _deploySafe(s.safeSingleton, s.factory, cfg.govOwners, cfg.govThreshold, 1);
        s.pgSafe = _deploySafe(s.safeSingleton, s.factory, cfg.pgOwners, cfg.pgThreshold, 2);

        address[] memory proposers = new address[](1);
        proposers[0] = address(s.govSafe);
        // L-8 (audit 2026-05-31): executor = Gov Safe (controlled execution),
        // NOT address(0) (open execution where any EOA could execute after the
        // delay). The same 3-of-5 Safe is the sole proposer AND executor — it is
        // the trust anchor for both ends of every Timelock op.
        address[] memory executors = new address[](1);
        executors[0] = address(s.govSafe);
        s.timelock = new TimelockController(minDelayAtConstruction, proposers, executors, address(0));

        console2.log("--- Governance (parameterized owners) ---");
        console2.log("  Safe singleton:    ", address(s.safeSingleton));
        console2.log("  Safe factory:      ", address(s.factory));
        console2.log("  Governance Safe:   ", address(s.govSafe));
        console2.log("    threshold:       ", cfg.govThreshold);
        console2.log("  Pause-Guardian Safe:", address(s.pgSafe));
        console2.log("    threshold:       ", cfg.pgThreshold);
        console2.log("  Timelock:          ", address(s.timelock));
        console2.log("    proposer = executor = Gov Safe (L-8); admin = 0");
    }

    function _deploySafe(
        Safe safeSingleton,
        SafeProxyFactory factory,
        address[] memory owners,
        uint256 threshold,
        uint256 saltNonce
    ) private returns (Safe) {
        bytes memory setup = abi.encodeCall(
            Safe.setup, (owners, threshold, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        return Safe(payable(address(factory.createProxyWithNonce(address(safeSingleton), setup, saltNonce))));
    }
}
