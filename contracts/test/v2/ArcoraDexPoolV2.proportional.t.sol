// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";

contract ArcoraDexPoolV2ProportionalTest is V2Fixture {
    function setUp() public {
        _deployV2();
        _seed(usdc, alice, 1_000_000e6);
        _seed(eurc, alice, 1_000_000e6); // alice is the only LP across both tokens
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
    }

    function test_proportional_returns_pro_rata_basket() public {
        uint256 lpBal = lp.balanceOf(alice);
        uint256 half = lpBal / 2;
        uint256 supply = lp.totalSupply();
        uint256 expUsdc = (half * pool.reserves(address(usdc))) / supply;
        uint256 expEurc = (half * pool.reserves(address(eurc))) / supply;

        uint256 u0 = usdc.balanceOf(alice);
        uint256 e0 = eurc.balanceOf(alice);
        vm.prank(alice);
        pool.withdrawProportional(half, block.timestamp + 1);
        assertEq(usdc.balanceOf(alice) - u0, expUsdc, "usdc pro-rata");
        assertEq(eurc.balanceOf(alice) - e0, expEurc, "eurc pro-rata");
    }

    function test_proportional_works_when_paused() public {
        vm.prank(guardian);
        pool.pause();
        uint256 lpBal = lp.balanceOf(alice);
        vm.prank(alice);
        pool.withdrawProportional(lpBal / 4, block.timestamp + 1); // must NOT revert
    }

    function test_proportional_works_when_oracle_unsafe() public {
        adapter.setSafe(address(usdc), false);
        adapter.setSafe(address(eurc), false);
        uint256 lpBal = lp.balanceOf(alice);
        vm.prank(alice);
        pool.withdrawProportional(lpBal / 4, block.timestamp + 1); // no oracle read → succeeds
    }
}
