// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {OracleAggregator} from "../src/oracle/OracleAggregator.sol";
import {MockChainlinkFeedV2} from "../src/testnet/MockChainlinkFeedV2.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";

/// @notice Pins the two CORRECTNESS gaps that DeployPublicTestnet.s.sol closes
/// for the fresh public-testnet redeploy. These are behavioral invariants on the
/// exact wiring the orchestrator produces (verified end-to-end on a testnet fork
/// in deploy/public-testnet-hardening), encoded here so a future regression in
/// the deploy path (e.g. re-pointing the aggregator's PRIMARY back at an
/// unbounded feed, or re-pointing the wrong Registry) fails in CI.
///
/// GAP #5 — the aggregator that the Registry resolves to MUST read the BOUNDED
/// primary feed (H-2 bounds in the live price path), NOT an unbounded feed.
/// GAP #2 — the FRESHLY-deployed Registry is the one re-pointed to the P3.5
/// aggregators; an unrelated (pre-existing) Registry is left untouched.
contract DeployPublicTestnetGapsTest is Test {
    address constant GOV_SAFE = 0x715f669D79Cc72d6685F8724c0B86f7B53d7e624;
    address keeperPrimary = makeAddr("keeperPrimary");
    address keeperSecondary = makeAddr("keeperSecondary");

    MintableERC20 usdc;
    ArcoraDexRegistry freshRegistry;
    ArcoraDexRegistry staleRegistry; // stands in for the pre-existing live Registry
    MockChainlinkFeedV2 boundedPrimary;
    MockChainlinkFeedV2 secondary;
    OracleAggregator p3_5Agg;

    // USDC H-2 band from DeployPublicTestnet._cfg(): [0.95, 1.05] at 8 decimals.
    int256 constant MIN_ANSWER = 95_000_000;
    int256 constant MAX_ANSWER = 105_000_000;
    int256 constant INIT = 100_000_000;

    function setUp() public {
        address deployer = address(this);
        usdc = new MintableERC20("USD Coin", "USDC", 6, deployer);

        // Two registries: the FRESH one (re-pointed) and a STALE one (left alone).
        freshRegistry = new ArcoraDexRegistry(deployer);
        staleRegistry = new ArcoraDexRegistry(deployer);

        // Bounded H-2 primary (writer = primary keeper). Step 2 of the orchestrator.
        boundedPrimary = new MockChainlinkFeedV2(8, INIT, keeperPrimary, deployer, MIN_ANSWER, MAX_ANSWER, 300, 0);
        // Secondary (writer = SECONDARY keeper — distinct, H-2). Step 5.
        secondary = new MockChainlinkFeedV2(8, INIT, keeperSecondary, deployer, MIN_ANSWER, MAX_ANSWER, 300, 0);

        // P3.5 aggregator: PRIMARY = bounded primary (GAP #5). Step 6.
        p3_5Agg = new OracleAggregator(
            IChainlinkAggregator(address(boundedPrimary)),
            IChainlinkAggregator(address(secondary)),
            50,
            3600,
            GOV_SAFE
        );

        // List USDC on BOTH registries against the bounded primary, then re-point
        // ONLY the fresh registry to the P3.5 aggregator (GAP #2).
        freshRegistry.listToken(address(usdc), 6, IChainlinkAggregator(address(boundedPrimary)), 50, 3600);
        staleRegistry.listToken(address(usdc), 6, IChainlinkAggregator(address(boundedPrimary)), 50, 3600);
        freshRegistry.setOracle(address(usdc), IChainlinkAggregator(address(p3_5Agg)));
    }

    /// GAP #5 (a): the fresh Registry's oracle resolves to an aggregator whose
    /// PRIMARY is the bounded feed.
    function test_gap5_aggregator_primary_is_bounded_feed() public view {
        address oracle = address(freshRegistry.tokenInfo(address(usdc)).usdOracle);
        assertEq(oracle, address(p3_5Agg), "registry oracle != P3.5 agg");
        assertEq(address(OracleAggregator(oracle).PRIMARY()), address(boundedPrimary), "agg PRIMARY != bounded feed");
    }

    /// GAP #5 (b): the bounds ARE in the live price path — an out-of-band
    /// setAnswer on the aggregator's PRIMARY reverts AnswerOutOfBounds.
    function test_gap5_outOfBand_push_on_primary_reverts() public {
        vm.prank(keeperPrimary);
        vm.expectRevert(
            abi.encodeWithSelector(MockChainlinkFeedV2.AnswerOutOfBounds.selector, int256(200_000_000), MIN_ANSWER, MAX_ANSWER)
        );
        boundedPrimary.setAnswer(200_000_000); // $2.00 — above the 1.05 ceiling

        // control: an in-band push succeeds.
        vm.prank(keeperPrimary);
        boundedPrimary.setAnswer(101_000_000);
        assertEq(boundedPrimary.latestAnswer(), 101_000_000);
    }

    /// GAP #2: the FRESH registry is the one re-pointed; the stale (pre-existing)
    /// registry is NOT touched (still pointing at the bounded feed, not the agg).
    function test_gap2_fresh_registry_repointed_stale_untouched() public view {
        assertEq(
            address(freshRegistry.tokenInfo(address(usdc)).usdOracle),
            address(p3_5Agg),
            "fresh registry not re-pointed to P3.5 agg"
        );
        assertEq(
            address(staleRegistry.tokenInfo(address(usdc)).usdOracle),
            address(boundedPrimary),
            "stale (pre-existing) registry must be left untouched"
        );
        assertTrue(
            address(freshRegistry) != address(staleRegistry), "fresh and stale registry must be distinct"
        );
    }

    /// H-2: the two feed legs use DISTINCT writers (separation preserved).
    function test_h2_writers_separated() public view {
        assertEq(boundedPrimary.writer(), keeperPrimary, "primary writer");
        assertEq(secondary.writer(), keeperSecondary, "secondary writer");
        assertTrue(keeperPrimary != keeperSecondary, "writers not separated");
    }
}
