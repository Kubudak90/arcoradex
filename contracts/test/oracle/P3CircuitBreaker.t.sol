// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { CumulativeDeviationGuard } from "../../src/oracle/CumulativeDeviationGuard.sol";

contract P3CircuitBreakerTest is Test {
    address constant OWNER = address(0x0a);
    address constant TOKEN = address(0x100);
    CumulativeDeviationGuard guard;

    function setUp() public {
        vm.warp(1_000_000); // avoid Foundry's default block.timestamp=1
        guard = new CumulativeDeviationGuard(OWNER);
        vm.prank(OWNER);
        guard.setConfig(TOKEN, 500, 86_400); // 5% cap, 24h window
    }

    function test_guard_emits_PriceObserved_on_first_record() public {
        vm.expectEmit(true, false, false, true);
        emit CumulativeDeviationGuard.PriceObserved(TOKEN, 1e18, block.timestamp);
        guard.record(TOKEN, 1e18);

        (uint256 startPrice, uint256 startTime) = guard.windows(TOKEN);
        assertEq(startPrice, 1e18);
        assertEq(startTime, block.timestamp);
    }

    function test_guard_emits_Trip_when_deviation_exceeds_cap() public {
        guard.record(TOKEN, 1e18);
        // Move price 6% within window -> exceeds 5% cap
        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(true, false, false, true);
        emit CumulativeDeviationGuard.PriceObserved(TOKEN, 1.06e18, block.timestamp);
        vm.expectEmit(true, false, false, true);
        emit CumulativeDeviationGuard.CircuitBreakerTripped(TOKEN, 600, block.timestamp);
        guard.record(TOKEN, 1.06e18);
    }

    function test_guard_resets_window_after_expiry() public {
        guard.record(TOKEN, 1e18);
        // Warp past the 24h window
        vm.warp(block.timestamp + 25 hours);
        guard.record(TOKEN, 1.1e18);

        (uint256 startPrice, uint256 startTime) = guard.windows(TOKEN);
        assertEq(startPrice, 1.1e18, "new window starts at the new observation");
        assertEq(startTime, block.timestamp);
    }

    function test_setConfig_onlyOwner() public {
        vm.expectRevert();
        guard.setConfig(TOKEN, 1000, 3600);

        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit CumulativeDeviationGuard.ConfigUpdated(TOKEN, 1000, 3600);
        guard.setConfig(TOKEN, 1000, 3600);

        (uint32 cap, uint32 window) = guard.configs(TOKEN);
        assertEq(cap, 1000);
        assertEq(window, 3600);
    }

    /// @dev Verifies that a sub-cap move (4% < 5%) emits PriceObserved but does
    /// NOT emit CircuitBreakerTripped. Uses vm.recordLogs to prove absence of
    /// the trip event.
    function test_guard_no_trip_when_within_cap() public {
        // Anchor the window.
        guard.record(TOKEN, 1e18);

        // Move into the window by 1 hour (well within the 24h window).
        vm.warp(block.timestamp + 1 hours);

        // Capture all logs emitted by the next call.
        vm.recordLogs();
        guard.record(TOKEN, 1.04e18); // 4% up — below the 5% cap

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 observedTopic  = keccak256("PriceObserved(address,uint256,uint256)");
        bytes32 trippedTopic   = keccak256("CircuitBreakerTripped(address,uint256,uint256)");

        bool foundObserved = false;
        bool foundTripped  = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == observedTopic)  foundObserved = true;
            if (logs[i].topics[0] == trippedTopic)   foundTripped  = true;
        }

        assertTrue(foundObserved,  "PriceObserved must be emitted");
        assertFalse(foundTripped,  "CircuitBreakerTripped must NOT be emitted within cap");
    }

    /// @dev Verifies that a downward move exceeding the cap (7% drop > 5%) emits
    /// both PriceObserved and CircuitBreakerTripped, exercising the
    /// price < startPrice branch of the diff ternary.
    function test_guard_trips_on_downward_deviation() public {
        // Anchor the window at 1e18.
        guard.record(TOKEN, 1e18);

        // Move into the window by 1 hour.
        vm.warp(block.timestamp + 1 hours);

        // diff = 0.07e18; deviationBps = (0.07e18 * 10_000) / 1e18 = 700 > 500 cap.
        vm.expectEmit(true, false, false, true);
        emit CumulativeDeviationGuard.PriceObserved(TOKEN, 0.93e18, block.timestamp);
        vm.expectEmit(true, false, false, true);
        emit CumulativeDeviationGuard.CircuitBreakerTripped(TOKEN, 700, block.timestamp);
        guard.record(TOKEN, 0.93e18);
    }
}
