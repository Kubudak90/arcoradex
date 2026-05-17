// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
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
}
