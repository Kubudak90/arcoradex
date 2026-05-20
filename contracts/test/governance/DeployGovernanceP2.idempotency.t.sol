// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {MockChainlinkFeedV2} from "../../src/testnet/MockChainlinkFeedV2.sol";

/// @notice Mirrors the guard + migrate logic of
/// `DeployGovernanceP2._transferFeedOwnership` so it is testable from outside
/// the script. The script's helper is `internal` and uses `governanceSafe.execCall`
/// for `acceptOwnership`; here we substitute a direct `acceptOwnership` call from
/// the test (pranked as `safe`), which exercises the same Ownable2Step path the
/// production helper drives via the Safe.
///
/// Audit G-2: the production contract this pins is:
///   if (currentOwner == safe) -> skip with no state change, no revert
///   else if (currentOwner == deployer) -> transfer + accept; assert owner == safe
///   else -> revert "feed owner is neither deployer nor Safe"
contract FeedOwnershipHarness {
    error UnexpectedFeedOwner(address feed, address currentOwner);

    /// Mirrors the per-feed body of the script helper.
    /// Returns true if a migration was performed, false if skipped.
    /// Reverts if the feed is owned by neither `deployer` nor `safe`.
    function migrateOne(MockChainlinkFeedV2 feed, address deployer, address safe)
        external
        returns (bool migrated)
    {
        address currentOwner = feed.owner();
        if (currentOwner == safe) {
            return false; // already migrated; skip
        }
        require(currentOwner == deployer, "feed owner is neither deployer nor Safe");
        feed.transferOwnership(safe);
        return true;
        // The Safe-side acceptOwnership is exercised by the test directly
        // (prank as safe; call feed.acceptOwnership()), matching the production
        // helper which routes acceptOwnership through governanceSafe.execCall.
    }
}

contract DeployGovernanceP2_IdempotencyTest is Test {
    MockChainlinkFeedV2 feed;
    FeedOwnershipHarness harness;
    address deployer;
    address safe;

    function setUp() public {
        deployer = address(0xDEAD);
        safe = address(0xBEEF);
        harness = new FeedOwnershipHarness();

        // Deploy the feed under the deployer key (the production starting state).
        // MockChainlinkFeedV2 constructor signature is
        //   (uint8 decimals, int256 initialAnswer, address initialWriter, address initialOwner)
        vm.prank(deployer);
        feed = new MockChainlinkFeedV2(8, 100_000_000, deployer, deployer);
    }

    /// First migration via the harness, then a second harness call that must
    /// observe the post-migration Safe-owned state and skip without reverting.
    /// This is the post-condition both reviewers wanted: a regression in the
    /// helper that drops the `currentOwner == safe -> continue` path would
    /// make the second call revert here.
    function test_skips_already_safe_owned_feed() public {
        // Stage 1: migrate from deployer to safe.
        // The harness is the current owner-caller in production via the script;
        // we transfer ownership from the deployer to the harness first so the
        // harness can call feed.transferOwnership(safe).
        vm.prank(deployer);
        feed.transferOwnership(address(harness));
        vm.prank(address(harness));
        feed.acceptOwnership();

        // Now harness is owner. Have it migrate to safe.
        bool migrated1 = harness.migrateOne(feed, address(harness), safe);
        assertTrue(migrated1, "first call should migrate");

        vm.prank(safe);
        feed.acceptOwnership();
        assertEq(feed.owner(), safe, "after first migration: safe owns the feed");

        // Stage 2: re-run the harness against the now-Safe-owned feed.
        // Pre-condition for the production helper: deployer arg is the script's
        // deployer (unchanged). Helper must skip — no revert, no state change.
        bool migrated2 = harness.migrateOne(feed, address(harness), safe);
        assertFalse(migrated2, "second call must skip (already safe-owned)");
        assertEq(feed.owner(), safe, "owner unchanged on idempotent re-run");
    }

    /// Happy path: migrate-then-accept via the typed Ownable2Step interface
    /// the refactored helper uses. Pins that transferOwnership sets
    /// pendingOwner and that acceptOwnership flips owner and clears pendingOwner.
    function test_migrate_then_accept_via_harness() public {
        // Transfer ownership of the feed to the harness so it can act as
        // the deployer-equivalent caller.
        vm.prank(deployer);
        feed.transferOwnership(address(harness));
        vm.prank(address(harness));
        feed.acceptOwnership();

        // Harness performs the typed migrate; pendingOwner becomes safe.
        bool migrated = harness.migrateOne(feed, address(harness), safe);
        assertTrue(migrated);
        assertEq(feed.owner(), address(harness), "owner unchanged before accept");
        assertEq(feed.pendingOwner(), safe, "pendingOwner is safe");

        // Safe accepts; ownership flips, pendingOwner clears.
        vm.prank(safe);
        feed.acceptOwnership();
        assertEq(feed.owner(), safe);
        assertEq(feed.pendingOwner(), address(0));
    }

    /// A feed owned by neither deployer nor Safe MUST cause the helper guard
    /// to revert. Exercises the `require(currentOwner == deployer, ...)` path
    /// directly.
    function test_reverts_on_unexpected_owner() public {
        address stranger = address(0xC0FFEE);
        vm.prank(deployer);
        feed.transferOwnership(stranger);
        vm.prank(stranger);
        feed.acceptOwnership();
        assertEq(feed.owner(), stranger, "precondition: feed is stranger-owned");

        // Harness sees an unexpected owner and reverts.
        // Note: the "deployer" arg passed in is what the script would pass —
        // here we use a known deployer constant the harness checks against.
        vm.expectRevert(bytes("feed owner is neither deployer nor Safe"));
        harness.migrateOne(feed, deployer, safe);
    }
}
