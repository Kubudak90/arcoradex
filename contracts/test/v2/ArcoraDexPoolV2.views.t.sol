// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";

contract ArcoraDexPoolV2ViewsTest is V2Fixture {
    function setUp() public {
        _deployV2();
        _seed(usdc, alice, 1_500_000e6); // health 50%
        _seed(eurc, bob, 1_500_000e6);
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
    }

    function test_reserveHealth_reports_50pct() public view {
        assertEq(pool.reserveHealth(address(usdc)), 5_000);
    }

    function test_maxSwapOut_does_not_overstate() public {
        (uint256 netMax, uint256 grossUsd1e18) = pool.maxSwapOut(address(eurc));
        assertGt(netMax, 0);
        // Swapping for exactly the advertised max gross must succeed at (or just above) the
        // floor; the executed output must not exceed the advertised netMax. The §8.1 floor
        // stop reverts on any gross beyond this, so we request exactly the max gross: at $1
        // a USDC (6-dec) input of grossUsd1e18/1e12 yields grossUsd1e18 of gross.
        uint256 amountIn = grossUsd1e18 / 1e12; // USDC has 6 decimals; price $1
        _mint(usdc, alice, amountIn);
        vm.startPrank(alice);
        usdc.approve(address(pool), amountIn);
        uint256 got = pool.swap(address(usdc), address(eurc), amountIn, 0, block.timestamp + 1, alice);
        vm.stopPrank();
        assertLe(got, netMax, "execution output must not exceed advertised maxSwapOut");
    }

    function test_maxWithdraw_does_not_overstate() public {
        (uint256 lpMax, uint256 netOut) = pool.maxWithdraw(address(eurc), alice);
        assertGt(lpMax, 0);
        vm.prank(alice);
        uint256 got = pool.withdrawSingle(address(eurc), lpMax, 0, block.timestamp + 1);
        assertApproxEqAbs(got, netOut, 2, "withdraw of maxWithdraw lp matches advertised netOut");
    }
}
