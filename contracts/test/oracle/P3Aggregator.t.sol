// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IChainlinkAggregator } from "../../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeedV2 } from "../../src/testnet/MockChainlinkFeedV2.sol";
import { OracleAggregator } from "../../src/oracle/OracleAggregator.sol";
import { RevertingMockFeed } from "./RevertingMockFeed.sol";

contract P3AggregatorTest is Test {
    address constant OWNER = address(0x0a);
    MockChainlinkFeedV2 primary;
    MockChainlinkFeedV2 secondary;

    function setUp() public {
        primary   = new MockChainlinkFeedV2(8, 100_000_000, OWNER, OWNER); // $1.00
        secondary = new MockChainlinkFeedV2(8, 100_000_000, OWNER, OWNER); // $1.00
    }

    function test_aggregator_returns_average_within_divergence_cap() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200, // 2% divergence cap
            OWNER
        );
        // primary $1.00, secondary $1.01 -> avg $1.005, within 200 bps
        vm.prank(OWNER);
        secondary.setAnswer(101_000_000);

        (, int256 ans, , , ) = agg.latestRoundData();
        assertEq(ans, int256(100_500_000), "avg of 1.00 and 1.01 = 1.005");
    }

    function test_aggregator_reverts_on_sources_diverge() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200, // 2% cap
            OWNER
        );
        // primary $1.00, secondary $1.05 -> 5% divergence, exceeds 200 bps
        vm.prank(OWNER);
        secondary.setAnswer(105_000_000);

        vm.expectRevert(abi.encodeWithSelector(
            OracleAggregator.SourcesDiverge.selector,
            uint256(100_000_000), uint256(105_000_000), uint16(200)
        ));
        agg.latestRoundData();
    }

    function test_aggregator_returns_primary_when_secondary_reverts() public {
        RevertingMockFeed bad = new RevertingMockFeed(8);
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(bad)),
            200,
            OWNER
        );
        (, int256 ans, , , ) = agg.latestRoundData();
        assertEq(ans, int256(100_000_000), "should return primary when secondary reverts");
    }

    function test_aggregator_reverts_when_both_sources_revert() public {
        RevertingMockFeed bad1 = new RevertingMockFeed(8);
        RevertingMockFeed bad2 = new RevertingMockFeed(8);
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(bad1)),
            IChainlinkAggregator(address(bad2)),
            200,
            OWNER
        );
        vm.expectRevert(abi.encodeWithSelector(OracleAggregator.AllSourcesUnavailable.selector));
        agg.latestRoundData();
    }

    function test_setMaxDivergenceBps_onlyOwner() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,
            OWNER
        );

        // Non-owner reverts
        vm.expectRevert();
        agg.setMaxDivergenceBps(500);

        // Owner succeeds
        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit OracleAggregator.MaxDivergenceUpdated(200, 500);
        agg.setMaxDivergenceBps(500);
        assertEq(agg.maxDivergenceBps(), 500);
    }

    function test_constructor_reverts_on_decimals_mismatch() public {
        MockChainlinkFeedV2 sec6 = new MockChainlinkFeedV2(6, 1_000_000, OWNER, OWNER);
        vm.expectRevert(abi.encodeWithSelector(
            OracleAggregator.DecimalsMismatch.selector, uint8(8), uint8(6)
        ));
        new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(sec6)),
            200,
            OWNER
        );
    }

    // M3-1: divergence exactly at the cap must NOT revert (strict > means AT cap passes)
    // cap=200 bps, primary=100_000_000, secondary=102_000_000
    // absDiff=2_000_000; minAns=100_000_000
    // 2_000_000 * 10_000 = 20_000_000_000 == 100_000_000 * 200 => NOT strictly greater, passes
    function test_aggregator_divergence_exactly_at_cap_passes() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200, // 2% cap
            OWNER
        );
        vm.prank(OWNER);
        secondary.setAnswer(102_000_000); // exactly 200 bps above primary

        (, int256 ans, , , ) = agg.latestRoundData();
        assertEq(ans, int256(101_000_000), "avg of 1.00 and 1.02 = 1.01 at exact cap boundary");
    }

    // M3-2: _tryRead REJECT path (not revert): secondary returns answer=0, falls back to primary
    function test_aggregator_falls_back_when_source_returns_zero_answer() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,
            OWNER
        );
        vm.prank(OWNER);
        secondary.setAnswer(0); // _tryRead will reject (a > 0 fails)

        (, int256 ans, , , ) = agg.latestRoundData();
        assertEq(ans, int256(100_000_000), "should fall back to primary when secondary returns zero answer");
    }

    // M3-3: both sources return answer=0 => AllSourcesUnavailable
    function test_aggregator_reverts_when_both_sources_return_zero() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,
            OWNER
        );
        vm.prank(OWNER);
        primary.setAnswer(0);
        vm.prank(OWNER);
        secondary.setAnswer(0);

        vm.expectRevert(abi.encodeWithSelector(OracleAggregator.AllSourcesUnavailable.selector));
        agg.latestRoundData();
    }

    // I1: sourceHealth() reports degraded mode correctly
    function test_sourceHealth_reports_degraded() public {
        // One reverting secondary -> (true, false)
        RevertingMockFeed bad = new RevertingMockFeed(8);
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(bad)),
            200,
            OWNER
        );
        (bool pOk, bool sOk) = agg.sourceHealth();
        assertTrue(pOk,  "primary should be healthy");
        assertFalse(sOk, "secondary (reverting) should be unhealthy");

        // Both healthy -> (true, true)
        OracleAggregator agg2 = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,
            OWNER
        );
        (bool p2Ok, bool s2Ok) = agg2.sourceHealth();
        assertTrue(p2Ok, "primary should be healthy");
        assertTrue(s2Ok, "secondary should be healthy");
    }
}
