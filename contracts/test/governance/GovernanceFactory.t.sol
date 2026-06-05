// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Safe} from "@safe-global/safe-contracts/contracts/Safe.sol";

import {GovernanceFactory} from "../../script/GovernanceFactory.sol";

/// @dev External harness so `vm.expectRevert` sees the revert at a LOWER call
/// depth than the cheatcode (library `internal` fns inline into the caller, so a
/// direct call would revert at the test's own depth and trip expectRevert).
/// Drives the PURE `buildConfig` so the tests are deterministic and free of the
/// process-env races that `vm.setEnv` + forge's parallel test scheduler cause.
contract GovFactoryHarness {
    function buildConfig(
        address[] memory govOwners,
        uint256 govThreshold,
        address[] memory pgOwners,
        uint256 pgThreshold,
        uint256 timelockMinDelay,
        bool useTestMnemonic
    ) external view returns (GovernanceFactory.Config memory) {
        return GovernanceFactory.buildConfig(
            govOwners, govThreshold, pgOwners, pgThreshold, timelockMinDelay, useTestMnemonic
        );
    }
}

/// @notice M-1 (audit 2026-05-31): the parameterized governance factory MUST
/// build the Gov/PG Safes from owner ADDRESSES passed in (the real-owners
/// DEFAULT), NOT the public Foundry test mnemonic. The mnemonic derivation is
/// reachable ONLY when the explicit `useTestMnemonic` flag is set (wired to the
/// `GOV_USE_TEST_MNEMONIC=true` opt-in by `resolveConfig`).
///
/// These tests couple to the REAL factory code (`GovernanceFactory.buildConfig`
/// + `GovernanceFactory.deploy`) — the same functions both `DeployGovernanceP2`
/// and the `DeployPublicTestnet` orchestrator call through `resolveConfig`.
///
/// MUTATION COVERAGE (verified — see PR description):
///   - factory wiring proposer/executor away from the Gov Safe
///     -> test_executor_is_gov_safe / test_proposer_is_gov_safe FAIL
///   - factory deriving owners from the mnemonic on the default path
///     -> test_default_owners_are_given_addresses_not_mnemonic FAILS
///   - dropping the threshold / zero-address / duplicate validation
///     -> the corresponding test_reverts_* FAILS
contract GovernanceFactoryTest is Test {
    // Foundry standard test mnemonic — the PUBLIC keys M-1 forbids on the default path.
    string constant TEST_MNEMONIC = "test test test test test test test test test test test junk";

    GovFactoryHarness harness;

    function setUp() public {
        harness = new GovFactoryHarness();
    }

    // Real, non-public owner addresses an operator would supply.
    function _realGovOwners() internal pure returns (address[] memory o) {
        o = new address[](5);
        o[0] = 0x1111111111111111111111111111111111111111;
        o[1] = 0x2222222222222222222222222222222222222222;
        o[2] = 0x3333333333333333333333333333333333333333;
        o[3] = 0x4444444444444444444444444444444444444444;
        o[4] = 0x5555555555555555555555555555555555555555;
    }

    function _realPgOwners() internal pure returns (address[] memory o) {
        o = new address[](3);
        o[0] = 0x6666666666666666666666666666666666666666;
        o[1] = 0x7777777777777777777777777777777777777777;
        o[2] = 0x8888888888888888888888888888888888888888;
    }

    function _realConfig() internal view returns (GovernanceFactory.Config memory) {
        return GovernanceFactory.buildConfig(_realGovOwners(), 3, _realPgOwners(), 2, 172_800, false);
    }

    // ───────────────────────────────────────────────────────────────────────
    // DEFAULT path — real given addresses, NOT the mnemonic
    // ───────────────────────────────────────────────────────────────────────

    /// The Gov Safe deployed via the factory's REAL code has EXACTLY the given
    /// owners + threshold — and they are NOT the public mnemonic-derived gov0..4.
    function test_default_owners_are_given_addresses_not_mnemonic() public {
        GovernanceFactory.Config memory cfg = _realConfig();
        assertFalse(cfg.usedTestMnemonic, "default path must not flag mnemonic");
        assertEq(cfg.govOwners.length, 5, "gov owners passed through");
        assertEq(cfg.govThreshold, 3, "gov threshold passed through");

        GovernanceFactory.Stack memory s = GovernanceFactory.deploy(cfg, 0);

        // Gov Safe owners == given owners + threshold.
        assertEq(s.govSafe.getOwners().length, 5, "gov owner count");
        assertEq(s.govSafe.getThreshold(), 3, "gov threshold");
        assertTrue(
            s.govSafe.isOwner(0x1111111111111111111111111111111111111111)
                && s.govSafe.isOwner(0x5555555555555555555555555555555555555555),
            "given owners present"
        );

        // PG Safe.
        assertEq(s.pgSafe.getOwners().length, 3, "pg owner count");
        assertEq(s.pgSafe.getThreshold(), 2, "pg threshold");
        assertTrue(s.pgSafe.isOwner(0x6666666666666666666666666666666666666666), "pg given owner present");

        // CRITICAL (M-1): none of the public-mnemonic gov0..gov4 own the Safe.
        for (uint32 i = 0; i < 5; i++) {
            address mnemonicAddr = vm.addr(vm.deriveKey(TEST_MNEMONIC, i));
            assertFalse(s.govSafe.isOwner(mnemonicAddr), "public-mnemonic key must NOT own the Gov Safe (M-1)");
        }
    }

    /// L-8: the Timelock executor is the Gov Safe, NOT address(0) (open execution).
    function test_executor_is_gov_safe() public {
        GovernanceFactory.Stack memory s = GovernanceFactory.deploy(_realConfig(), 0);

        bytes32 execRole = s.timelock.EXECUTOR_ROLE();
        assertTrue(s.timelock.hasRole(execRole, address(s.govSafe)), "Gov Safe must be EXECUTOR (L-8)");
        // address(0) (open executor) must NOT hold the role.
        assertFalse(s.timelock.hasRole(execRole, address(0)), "open executor (address(0)) must NOT hold EXECUTOR (L-8)");
    }

    /// The Gov Safe is the sole proposer; admin is renounced (address(0)).
    function test_proposer_is_gov_safe() public {
        GovernanceFactory.Stack memory s = GovernanceFactory.deploy(_realConfig(), 0);

        assertTrue(s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), address(s.govSafe)), "Gov Safe must be PROPOSER");
        // No admin retained by the deployer/factory.
        assertFalse(
            s.timelock.hasRole(s.timelock.DEFAULT_ADMIN_ROLE(), address(this)), "deployer must not hold admin role"
        );
    }

    /// Timelock min delay honours the passed value.
    function test_timelock_min_delay_constructed() public {
        GovernanceFactory.Config memory cfg = _realConfig();
        assertEq(cfg.timelockMinDelay, 172_800, "delay carried in config");
        GovernanceFactory.Stack memory s = GovernanceFactory.deploy(cfg, cfg.timelockMinDelay);
        assertEq(s.timelock.getMinDelay(), 172_800, "timelock minDelay == config");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Validation guards
    // ───────────────────────────────────────────────────────────────────────

    function test_reverts_on_threshold_out_of_range() public {
        vm.expectRevert(bytes("GOV_SAFE_THRESHOLD > owners.length"));
        harness.buildConfig(_realGovOwners(), 6, _realPgOwners(), 2, 172_800, false);
    }

    function test_reverts_on_zero_threshold() public {
        vm.expectRevert(bytes("GOV_SAFE_THRESHOLD < 1"));
        harness.buildConfig(_realGovOwners(), 0, _realPgOwners(), 2, 172_800, false);
    }

    function test_reverts_on_empty_owners() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(bytes("GOV_SAFE_OWNERS empty"));
        harness.buildConfig(empty, 1, _realPgOwners(), 2, 172_800, false);
    }

    function test_reverts_on_zero_address_owner() public {
        address[] memory o = _realGovOwners();
        o[1] = address(0);
        vm.expectRevert(bytes("GOV_SAFE_OWNERS contains zero address"));
        harness.buildConfig(o, 2, _realPgOwners(), 2, 172_800, false);
    }

    function test_reverts_on_duplicate_owner() public {
        address[] memory o = _realGovOwners();
        o[1] = o[0]; // duplicate
        vm.expectRevert(bytes("GOV_SAFE_OWNERS contains duplicate"));
        harness.buildConfig(o, 2, _realPgOwners(), 2, 172_800, false);
    }

    function test_reverts_on_pg_misconfig() public {
        address[] memory pg = _realPgOwners();
        pg[2] = address(0);
        vm.expectRevert(bytes("PG_SAFE_OWNERS contains zero address"));
        harness.buildConfig(_realGovOwners(), 3, pg, 2, 172_800, false);
    }

    // ───────────────────────────────────────────────────────────────────────
    // OPT-IN path — mnemonic gated behind the explicit flag
    // ───────────────────────────────────────────────────────────────────────

    /// With the explicit opt-in, the factory derives the public-mnemonic owners
    /// (testnet throwaway). This is the ONLY way to reach the mnemonic.
    function test_optin_uses_mnemonic_owners() public {
        // owners args ignored on the mnemonic path; pass empties.
        address[] memory empty = new address[](0);
        GovernanceFactory.Config memory cfg = GovernanceFactory.buildConfig(empty, 0, empty, 0, 0, true);
        assertTrue(cfg.usedTestMnemonic, "opt-in flag must set usedTestMnemonic");
        assertEq(cfg.govOwners.length, 5, "5 gov owners derived");
        assertEq(cfg.govThreshold, 3, "3/5 default");
        assertEq(cfg.pgThreshold, 2, "2/3 default");

        GovernanceFactory.Stack memory s = GovernanceFactory.deploy(cfg, 0);
        // The mnemonic-derived gov0 IS an owner on this opt-in path.
        address gov0 = vm.addr(vm.deriveKey(TEST_MNEMONIC, 0));
        assertTrue(s.govSafe.isOwner(gov0), "opt-in: mnemonic key owns the Safe");
    }

    /// M-1 hard guard: the mnemonic opt-in MUST revert on the mainnet chainid so
    /// a real deploy can never ship the public keys.
    function test_optin_reverts_on_mainnet() public {
        address[] memory empty = new address[](0);
        vm.chainId(1); // Ethereum mainnet
        vm.expectRevert(bytes("GovernanceFactory: test mnemonic forbidden on mainnet"));
        harness.buildConfig(empty, 0, empty, 0, 0, true);
    }
}
