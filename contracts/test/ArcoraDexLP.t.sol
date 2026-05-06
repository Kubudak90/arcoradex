// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ArcoraDexLP }  from "../src/ArcoraDexLP.sol";
import { IArcoraDexLP } from "../src/interfaces/IArcoraDexLP.sol";

contract ArcoraDexLPTest is Test {
    ArcoraDexLP lp;
    address minter = makeAddr("minter");
    address alice  = makeAddr("alice");
    address bob    = makeAddr("bob");

    function setUp() public {
        lp = new ArcoraDexLP(minter);
    }

    function test_metadata() public view {
        assertEq(lp.name(), "Arcora DEX LP");
        assertEq(lp.symbol(), "ADEX-LP");
        assertEq(lp.decimals(), 18);
        assertEq(lp.MINTER(), minter);
        assertEq(lp.totalSupply(), 0);
    }

    function test_constructor_revertsZeroMinter() public {
        vm.expectRevert(IArcoraDexLP.ZeroAddress.selector);
        new ArcoraDexLP(address(0));
    }

    function test_mint_byMinter() public {
        vm.prank(minter);
        lp.mint(alice, 100e18);
        assertEq(lp.balanceOf(alice), 100e18);
        assertEq(lp.totalSupply(), 100e18);
    }

    function test_mint_revertsNotMinter() public {
        vm.prank(alice);
        vm.expectRevert(IArcoraDexLP.NotMinter.selector);
        lp.mint(alice, 100e18);
    }

    function test_burn_byMinter() public {
        vm.startPrank(minter);
        lp.mint(alice, 100e18);
        lp.burn(alice, 40e18);
        vm.stopPrank();
        assertEq(lp.balanceOf(alice), 60e18);
        assertEq(lp.totalSupply(), 60e18);
    }

    function test_burn_revertsNotMinter() public {
        vm.prank(minter);
        lp.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(IArcoraDexLP.NotMinter.selector);
        lp.burn(alice, 40e18);
    }

    function test_transfer_works_freely() public {
        vm.prank(minter);
        lp.mint(alice, 100e18);

        vm.prank(alice);
        lp.transfer(bob, 30e18);
        assertEq(lp.balanceOf(alice), 70e18);
        assertEq(lp.balanceOf(bob), 30e18);
    }
}
