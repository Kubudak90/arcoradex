// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";
import {IArcoraDexPoolV2} from "../../src/v2/interfaces/IArcoraDexPoolV2.sol";

contract ArcoraDexPoolV2PauseTest is V2Fixture {
    function setUp() public {
        _deployV2();
        _seed(usdc, alice, 2_000_000e6);
        _seed(eurc, bob, 2_000_000e6);
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
    }

    function test_guardian_can_pause_but_not_unpause() public {
        vm.prank(guardian);
        pool.pause();
        assertTrue(pool.paused());
        vm.prank(guardian);
        vm.expectRevert(); // Ownable: guardian is not owner
        pool.unpause();
        vm.prank(owner);
        pool.unpause();
        assertFalse(pool.paused());
    }

    function test_rando_cannot_pause() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(IArcoraDexPoolV2.NotAuthorized.selector);
        pool.pause();
    }

    // §11: swap, deposit, single-withdraw into an unsafe token all stop.
    function test_unsafe_token_stops_swap_deposit_withdraw() public {
        adapter.setSafe(address(eurc), false);
        _mint(usdc, alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, address(eurc)));
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp + 1, alice);
        vm.stopPrank();

        _mint(eurc, alice, 1_000e6);
        vm.startPrank(alice);
        eurc.approve(address(pool), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, address(eurc)));
        pool.deposit(address(eurc), 1_000e6, 0, block.timestamp + 1);
        vm.stopPrank();

        // single-token withdraw whose NAV requires the unsafe price also stops.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, address(eurc)));
        pool.withdrawSingle(address(usdc), 1e18, 0, block.timestamp + 1);
    }

    // ── Controller-sanctioned additions (Task 7+8 adversarial review) ──

    /// @dev (a) withdrawSingle is gated by whenNotPaused: it must stop while paused.
    function test_withdrawSingle_reverts_when_paused() public {
        vm.prank(guardian);
        pool.pause();
        vm.prank(alice);
        vm.expectRevert(IArcoraDexPoolV2.PoolPaused.selector);
        pool.withdrawSingle(address(usdc), 1e18, 0, block.timestamp + 1);
    }

    /// @dev (b) §11 any-token-unsafe via NAV, exact orientation: withdrawing EURC
    /// (whose own oracle is safe) must revert OracleUnsafe(usdc) when USDC is unsafe.
    function test_withdrawSingle_other_token_unsafe_stops_via_nav() public {
        adapter.setSafe(address(usdc), false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, address(usdc)));
        pool.withdrawSingle(address(eurc), 1e18, 0, block.timestamp + 1);
    }
}
