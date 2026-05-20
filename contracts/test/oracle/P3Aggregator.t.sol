// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Safe} from "@safe-global/safe-contracts/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";
import {MockChainlinkFeedV2} from "../../src/testnet/MockChainlinkFeedV2.sol";
import {OracleAggregator} from "../../src/oracle/OracleAggregator.sol";
import {RevertingMockFeed} from "./RevertingMockFeed.sol";
import {ArcoraDexRegistry} from "../../src/ArcoraDexRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {SafeSigHelpers} from "../governance/SafeSigHelpers.sol";

contract P3AggregatorTest is Test {
    address constant OWNER = address(0x0a);
    MockChainlinkFeedV2 primary;
    MockChainlinkFeedV2 secondary;

    function setUp() public {
        primary = new MockChainlinkFeedV2(8, 100_000_000, OWNER, OWNER); // $1.00
        secondary = new MockChainlinkFeedV2(8, 100_000_000, OWNER, OWNER); // $1.00
    }

    function test_aggregator_returns_average_within_divergence_cap() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200, // 2% divergence cap
            3600, // MAX_STALE_SECONDS
            OWNER
        );
        // primary $1.00, secondary $1.01 -> avg $1.005, within 200 bps
        vm.prank(OWNER);
        secondary.setAnswer(101_000_000);

        (, int256 ans,,,) = agg.latestRoundData();
        assertEq(ans, int256(100_500_000), "avg of 1.00 and 1.01 = 1.005");
    }

    function test_aggregator_reverts_on_sources_diverge() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200, // 2% cap
            3600, // MAX_STALE_SECONDS
            OWNER
        );
        // primary $1.00, secondary $1.05 -> 5% divergence, exceeds 200 bps
        vm.prank(OWNER);
        secondary.setAnswer(105_000_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAggregator.SourcesDiverge.selector, uint256(100_000_000), uint256(105_000_000), uint16(200)
            )
        );
        agg.latestRoundData();
    }

    function test_aggregator_returns_primary_when_secondary_reverts() public {
        RevertingMockFeed bad = new RevertingMockFeed(8);
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)), IChainlinkAggregator(address(bad)), 200, 3600, OWNER
        );
        (, int256 ans,,,) = agg.latestRoundData();
        assertEq(ans, int256(100_000_000), "should return primary when secondary reverts");
    }

    function test_aggregator_reverts_when_both_sources_revert() public {
        RevertingMockFeed bad1 = new RevertingMockFeed(8);
        RevertingMockFeed bad2 = new RevertingMockFeed(8);
        OracleAggregator agg =
            new OracleAggregator(IChainlinkAggregator(address(bad1)), IChainlinkAggregator(address(bad2)), 200, 3600, OWNER);
        vm.expectRevert(abi.encodeWithSelector(OracleAggregator.AllSourcesUnavailable.selector));
        agg.latestRoundData();
    }

    function test_setMaxDivergenceBps_onlyOwner() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)), IChainlinkAggregator(address(secondary)), 200, 3600, OWNER
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
        vm.expectRevert(abi.encodeWithSelector(OracleAggregator.DecimalsMismatch.selector, uint8(8), uint8(6)));
        new OracleAggregator(IChainlinkAggregator(address(primary)), IChainlinkAggregator(address(sec6)), 200, 3600, OWNER);
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
            3600, // MAX_STALE_SECONDS
            OWNER
        );
        vm.prank(OWNER);
        secondary.setAnswer(102_000_000); // exactly 200 bps above primary

        (, int256 ans,,,) = agg.latestRoundData();
        assertEq(ans, int256(101_000_000), "avg of 1.00 and 1.02 = 1.01 at exact cap boundary");
    }

    // M3-2: _tryRead REJECT path: secondary returns a bad read (reverts), falls back to primary.
    // After D1 MockChainlinkFeedV2 rejects non-positive answers, a "zero-answer" source is
    // represented by RevertingMockFeed — the _tryRead catch path covers the same aggregator logic.
    function test_aggregator_falls_back_when_source_is_unavailable() public {
        RevertingMockFeed badSecondary = new RevertingMockFeed(8);
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)), IChainlinkAggregator(address(badSecondary)), 200, 3600, OWNER
        );

        (, int256 ans,,,) = agg.latestRoundData();
        assertEq(ans, int256(100_000_000), "should fall back to primary when secondary is unavailable");
    }

    // M3-3: both sources unavailable => AllSourcesUnavailable
    function test_aggregator_reverts_when_both_sources_are_unavailable() public {
        RevertingMockFeed badPrimary = new RevertingMockFeed(8);
        RevertingMockFeed badSecondary = new RevertingMockFeed(8);
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(badPrimary)), IChainlinkAggregator(address(badSecondary)), 200, 3600, OWNER
        );

        vm.expectRevert(abi.encodeWithSelector(OracleAggregator.AllSourcesUnavailable.selector));
        agg.latestRoundData();
    }

    // ── New coverage tests ─────────────────────────────────────────────────────

    // Constructor revert: zero divergence bps
    function test_constructor_reverts_on_zero_divergence_bps() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAggregator.InvalidDivergenceBps.selector, uint16(0)));
        new OracleAggregator(IChainlinkAggregator(address(primary)), IChainlinkAggregator(address(secondary)), 0, 3600, OWNER);
    }

    // Constructor revert: divergence bps above 10_000
    function test_constructor_reverts_on_divergence_bps_above_max() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAggregator.InvalidDivergenceBps.selector, uint16(10_001)));
        new OracleAggregator(
            IChainlinkAggregator(address(primary)), IChainlinkAggregator(address(secondary)), 10_001, 3600, OWNER
        );
    }

    // Constructor revert: zero maxStaleSeconds
    function test_constructor_reverts_on_zero_stale_seconds() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAggregator.InvalidStaleSeconds.selector, uint32(0)));
        new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,    // divergence bps
            0,      // maxStaleSeconds_ - must be > 0
            OWNER
        );
    }

    // setMaxDivergenceBps reverts on both invalid boundary values
    function test_setMaxDivergenceBps_reverts_on_invalid() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)), IChainlinkAggregator(address(secondary)), 200, 3600, OWNER
        );

        // zero bps
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(OracleAggregator.InvalidDivergenceBps.selector, uint16(0)));
        agg.setMaxDivergenceBps(0);

        // above-max bps
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(OracleAggregator.InvalidDivergenceBps.selector, uint16(10_001)));
        agg.setMaxDivergenceBps(10_001);
    }

    // decimals() external view returns the feed's decimals
    function test_decimals_returns_feed_decimals() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)), IChainlinkAggregator(address(secondary)), 200, 3600, OWNER
        );
        assertEq(agg.decimals(), 8, "DECIMALS should equal the feed's 8 decimals");
    }

    // I1: sourceHealth() reports degraded mode correctly
    function test_sourceHealth_reports_degraded() public {
        // One reverting secondary -> (true, false)
        RevertingMockFeed bad = new RevertingMockFeed(8);
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)), IChainlinkAggregator(address(bad)), 200, 3600, OWNER
        );
        (bool pOk, bool sOk) = agg.sourceHealth();
        assertTrue(pOk, "primary should be healthy");
        assertFalse(sOk, "secondary (reverting) should be unhealthy");

        // Both healthy -> (true, true)
        OracleAggregator agg2 = new OracleAggregator(
            IChainlinkAggregator(address(primary)), IChainlinkAggregator(address(secondary)), 200, 3600, OWNER
        );
        (bool p2Ok, bool s2Ok) = agg2.sourceHealth();
        assertTrue(p2Ok, "primary should be healthy");
        assertTrue(s2Ok, "secondary should be healthy");
    }

    // ── D2 new tests: per-source staleness + degraded-mode signal ─────────────

    function test_tryRead_rejects_stale_per_source() public {
        // primary is stale, secondary is fresh — aggregator should run in degraded
        // mode using the secondary's price, and signal that via roundId == 0.
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200, // divergence cap
            60, // MAX_STALE_SECONDS — tight to keep the test deterministic
            OWNER
        );
        vm.warp(block.timestamp + 120); // primary now 120s old, > 60s threshold
        vm.prank(OWNER);
        secondary.setAnswer(102_000_000); // refresh secondary at the new block.timestamp

        (uint80 roundId, int256 ans,, uint256 updatedAt,) = agg.latestRoundData();
        assertEq(roundId, 0, "degraded mode signals roundId == 0");
        assertEq(ans, int256(102_000_000), "ans comes from the fresh secondary");
        assertEq(updatedAt, block.timestamp, "updatedAt == secondary's timestamp");
    }

    function test_latestRoundData_uses_min_updatedAt_when_both_ok() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,
            3600, // MAX_STALE_SECONDS generous
            OWNER
        );
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 30);
        vm.prank(OWNER);
        secondary.setAnswer(101_000_000); // secondary now fresher than primary

        (,,, uint256 updatedAt,) = agg.latestRoundData();
        assertEq(updatedAt, t0, "returns min(pAt, sAt) = primary's older timestamp");
    }

    function test_latestRoundData_returns_nonzero_roundId_when_both_ok() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,
            3600,
            OWNER
        );
        vm.prank(OWNER);
        secondary.setAnswer(101_000_000);
        (uint80 roundId,,,,) = agg.latestRoundData();
        assertGt(roundId, 0, "healthy two-source must report a real (non-zero) roundId");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// P3AggregatorGovernanceTest
//
// End-to-end governance integration test: proves the P3 OracleAggregator
// migration via the P2 governance stack (Safe 3/5 + TimelockController 48h).
//
// Sequence: schedule → cannot-execute-before-delay → warp 48h → execute →
//           verify Registry.tokenInfo(usdc).usdOracle == aggregator address.
// ─────────────────────────────────────────────────────────────────────────────
contract P3AggregatorGovernanceTest is Test {
    using SafeSigHelpers for Safe;

    // Standard Foundry/Hardhat test mnemonic — deterministic throwaway keys.
    string constant MNEMONIC = "test test test test test test test test test test test junk";
    uint256 constant TIMELOCK_DELAY = 48 hours;

    address constant DEPLOYER = address(0xD3);

    Safe governanceSafe;
    TimelockController timelock;
    ArcoraDexRegistry reg;
    MockChainlinkFeedV2 primary;
    MockChainlinkFeedV2 secondary;
    OracleAggregator aggregator;

    uint256[5] govKeys;
    MockERC20 usdc;

    function setUp() public {
        // Advance past timestamp=1 (OZ TimelockController uses DONE_TIMESTAMP=1;
        // delay=0 at timestamp=1 would set _timestamps[id]=1 which looks Done).
        vm.warp(1_000_000);

        // Derive 5 governance signer keys/addresses from standard test mnemonic.
        address[] memory govOwners = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i] = vm.deriveKey(MNEMONIC, uint32(i));
            govOwners[i] = vm.addr(govKeys[i]);
        }

        // Deploy Safe singleton + factory, then create a 3/5 governance Safe.
        Safe safeSingleton = new Safe();
        SafeProxyFactory factory = new SafeProxyFactory();
        bytes memory govSetup = abi.encodeCall(
            Safe.setup, (govOwners, 3, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        governanceSafe = Safe(payable(address(factory.createProxyWithNonce(address(safeSingleton), govSetup, 1))));

        // TimelockController: minDelay = 0 (setup mode), proposer = govSafe, executors open.
        address[] memory proposers = new address[](1);
        proposers[0] = address(governanceSafe);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution
        timelock = new TimelockController(0, proposers, executors, address(0));

        // Deploy Registry + mock token + initial oracle feed under DEPLOYER.
        vm.startPrank(DEPLOYER);
        reg = new ArcoraDexRegistry(DEPLOYER);
        usdc = new MockERC20("USDC", "USDC", 6);
        primary = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(primary)), 50, 3600);
        reg.transferOwnership(address(timelock));
        vm.stopPrank();

        // Timelock (at delay=0) accepts Registry ownership.
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.schedule,
                (address(reg), 0, abi.encodeCall(reg.acceptOwnership, ()), bytes32(0), bytes32(0), 0)
            )
        );
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.execute,
                (address(reg), 0, abi.encodeCall(reg.acceptOwnership, ()), bytes32(0), bytes32(0))
            )
        );

        // Lockdown: raise minDelay to 48h (mirrors P2 setup).
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.schedule,
                (
                    address(timelock),
                    0,
                    abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY)),
                    bytes32(0),
                    bytes32(0),
                    0
                )
            )
        );
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.execute,
                (
                    address(timelock),
                    0,
                    abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY)),
                    bytes32(0),
                    bytes32(0)
                )
            )
        );

        // Deploy the P3 OracleAggregator (two matching-decimals sources, 2% cap).
        secondary = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER);
        aggregator = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,
            3600, // MAX_STALE_SECONDS
            address(governanceSafe)
        );
    }

    /// @notice Proves the full Registry.setOracle migration sequence:
    ///   1. Governance schedules setOracle through the Timelock.
    ///   2. Execution is blocked before the 48h delay elapses.
    ///   3. After warping 48h+1s, execution succeeds.
    ///   4. Registry now points at the new OracleAggregator.
    ///   5. The aggregator returns the expected average price.
    function test_governance_migrates_registry_to_aggregator() public {
        bytes memory call = abi.encodeCall(reg.setOracle, (address(usdc), IChainlinkAggregator(address(aggregator))));

        // 1. Schedule with the 48h delay.
        _govExec(
            address(timelock),
            abi.encodeCall(TimelockController.schedule, (address(reg), 0, call, bytes32(0), bytes32(0), TIMELOCK_DELAY))
        );

        // 2. Attempt execution before delay — must revert with the Timelock not-ready error.
        bytes32 opId = timelock.hashOperation(address(reg), 0, call, bytes32(0), bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                opId,
                bytes32(1 << uint8(TimelockController.OperationState.Ready))
            )
        );
        timelock.execute(address(reg), 0, call, bytes32(0), bytes32(0));

        // 3. Warp past the delay and execute.
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        timelock.execute(address(reg), 0, call, bytes32(0), bytes32(0));

        // 4. Registry must now point at the aggregator.
        assertEq(
            address(reg.tokenInfo(address(usdc)).usdOracle),
            address(aggregator),
            "Registry.usdOracle must point at the new OracleAggregator"
        );

        // 5. Aggregator returns the average of both $1.00 sources = $1.00.
        // Refresh feeds so they are not stale after the 48h timelock warp —
        // the aggregator V2 per-source staleness check (MAX_STALE_SECONDS=3600)
        // would reject feeds last updated at setUp time (>48h ago).
        vm.startPrank(DEPLOYER);
        primary.setAnswer(100_000_000);
        secondary.setAnswer(100_000_000);
        vm.stopPrank();
        (, int256 ans,,,) = aggregator.latestRoundData();
        assertEq(ans, int256(100_000_000), "aggregator returns avg of two $1.00 sources");
    }

    /// @dev Signs + executes a call via the governance Safe (3-of-5 signers).
    function _govExec(address to, bytes memory data) internal {
        uint256[] memory keys = new uint256[](3);
        keys[0] = govKeys[0];
        keys[1] = govKeys[1];
        keys[2] = govKeys[2];
        require(governanceSafe.execCall(to, data, keys), "gov exec failed");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// P3AggregatorDegradedConsumerTest  (Task D3 — audit C-1 regression)
//
// Pins the integration contract between OracleAggregator V2 and any
// Chainlink-style consumer that uses the standard roundId-based freshness
// pattern (the Pool's _readOracle: roundOk = roundId != 0 && air >= roundId).
//
// When one source goes stale the aggregator returns roundId = 0; a consumer
// that checks roundId falls back to cache rather than accepting the
// degraded read. This test ensures that invariant cannot silently regress.
// ─────────────────────────────────────────────────────────────────────────────
contract P3AggregatorDegradedConsumerTest is Test {
    address constant OWNER = address(0x0a);
    MockChainlinkFeedV2 primary;
    MockChainlinkFeedV2 secondary;

    function setUp() public {
        primary = new MockChainlinkFeedV2(8, 100_000_000, OWNER, OWNER); // $1.00
        secondary = new MockChainlinkFeedV2(8, 100_000_000, OWNER, OWNER); // $1.00
    }

    /// @dev D3 regression test: aggregator in degraded (single-source) mode
    ///      returns roundId == 0, causing the Pool-style roundOk check to reject
    ///      the read and fall back to the lastValidPrice cache.
    ///
    ///      The Pool's _readOracle computes:
    ///          bool roundOk = (roundId != 0 && answeredInRound >= roundId);
    ///          bool isFresh = roundOk && (block.timestamp - updatedAt <= maxStaleSeconds);
    ///      When isFresh is false, it falls back to lastValidPrice instead of
    ///      using the aggregator's degraded reading.
    function test_aggregator_degraded_signals_roundId_zero_to_consumer() public {
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,
            60, // MAX_STALE_SECONDS — tight so the primary goes stale quickly
            OWNER
        );

        // Make primary stale: warp 120s (> 60s threshold) without refreshing primary.
        vm.warp(block.timestamp + 120);

        // Refresh secondary so it's the only fresh source.
        vm.prank(OWNER);
        secondary.setAnswer(102_000_000);

        // Degraded read: roundId must be 0 (single-source signal).
        (uint80 roundId, int256 ans,,, uint80 answeredInRound) = agg.latestRoundData();
        assertEq(roundId, 0, "degraded mode signals roundId == 0");
        assertGt(ans, 0, "value is present but consumer must ignore it via roundOk");

        // Cross-check: simulate the Pool's _readOracle roundOk computation.
        // Mirror the full Pool _readOracle expression at
        // contracts/src/ArcoraDexPool.sol:110 exactly, so a future regression
        // where the aggregator emits roundId>0 but inconsistent answeredInRound
        // would also be caught.
        bool roundOk = (roundId != 0 && answeredInRound >= roundId);
        assertFalse(roundOk, "Pool-side roundOk must reject degraded reads, triggering cache fallback");
    }
}
