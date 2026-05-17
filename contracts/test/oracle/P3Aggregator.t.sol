// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { SafeProxyFactory } from "@safe-global/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import { IChainlinkAggregator } from "../../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeedV2 } from "../../src/testnet/MockChainlinkFeedV2.sol";
import { OracleAggregator } from "../../src/oracle/OracleAggregator.sol";
import { RevertingMockFeed } from "./RevertingMockFeed.sol";
import { ArcoraDexRegistry } from "../../src/ArcoraDexRegistry.sol";
import { MockERC20 } from "../helpers/MockERC20.sol";
import { SafeSigHelpers } from "../governance/SafeSigHelpers.sol";

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
    string constant MNEMONIC =
        "test test test test test test test test test test test junk";
    uint256 constant TIMELOCK_DELAY = 48 hours;

    address constant DEPLOYER = address(0xD3);

    Safe                governanceSafe;
    TimelockController  timelock;
    ArcoraDexRegistry   reg;
    MockChainlinkFeedV2 primary;
    MockChainlinkFeedV2 secondary;
    OracleAggregator    aggregator;

    uint256[5] govKeys;
    MockERC20  usdc;

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
            Safe.setup,
            (govOwners, 3, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
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
        reg     = new ArcoraDexRegistry(DEPLOYER);
        usdc    = new MockERC20("USDC", "USDC", 6);
        primary = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(primary)), 50, 3600);
        reg.transferOwnership(address(timelock));
        vm.stopPrank();

        // Timelock (at delay=0) accepts Registry ownership.
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(reg), 0, abi.encodeCall(reg.acceptOwnership, ()), bytes32(0), bytes32(0), 0)));
        _govExec(address(timelock), abi.encodeCall(TimelockController.execute,
            (address(reg), 0, abi.encodeCall(reg.acceptOwnership, ()), bytes32(0), bytes32(0))));

        // Lockdown: raise minDelay to 48h (mirrors P2 setup).
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(timelock), 0, abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY)), bytes32(0), bytes32(0), 0)));
        _govExec(address(timelock), abi.encodeCall(TimelockController.execute,
            (address(timelock), 0, abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY)), bytes32(0), bytes32(0))));

        // Deploy the P3 OracleAggregator (two matching-decimals sources, 2% cap).
        secondary = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER);
        aggregator = new OracleAggregator(
            IChainlinkAggregator(address(primary)),
            IChainlinkAggregator(address(secondary)),
            200,
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
        bytes memory call = abi.encodeCall(
            reg.setOracle,
            (address(usdc), IChainlinkAggregator(address(aggregator)))
        );

        // 1. Schedule with the 48h delay.
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(reg), 0, call, bytes32(0), bytes32(0), TIMELOCK_DELAY)));

        // 2. Attempt execution before delay — must revert with the Timelock not-ready error.
        bytes32 opId = timelock.hashOperation(address(reg), 0, call, bytes32(0), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(
            TimelockController.TimelockUnexpectedOperationState.selector,
            opId,
            bytes32(1 << uint8(TimelockController.OperationState.Ready))
        ));
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
        (, int256 ans, , , ) = aggregator.latestRoundData();
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
