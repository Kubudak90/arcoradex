// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexLPV2} from "../../src/v2/ArcoraDexLPV2.sol";
import {IArcoraDexLPV2} from "../../src/v2/interfaces/IArcoraDexLPV2.sol";

contract ArcoraDexLPV2Test is Test {
    ArcoraDexLPV2 lp;
    address minter = makeAddr("minter");
    address alice = makeAddr("alice");

    function setUp() public {
        lp = new ArcoraDexLPV2(minter);
    }

    function test_minter_set() public view {
        assertEq(lp.MINTER(), minter);
        assertEq(lp.name(), "Arcora DEX LP V2");
        assertEq(lp.symbol(), "ADEX-LP2");
    }

    function test_mint_onlyMinter() public {
        vm.prank(alice);
        vm.expectRevert(IArcoraDexLPV2.NotMinter.selector);
        lp.mint(alice, 1e18);
        vm.prank(minter);
        lp.mint(alice, 1e18);
        assertEq(lp.balanceOf(alice), 1e18);
    }

    function test_burn_onlyMinter() public {
        vm.prank(minter);
        lp.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(IArcoraDexLPV2.NotMinter.selector);
        lp.burn(alice, 1e18);
        vm.prank(minter);
        lp.burn(alice, 1e18);
        assertEq(lp.balanceOf(alice), 0);
    }

    function test_ctor_rejectsZeroMinter() public {
        vm.expectRevert(IArcoraDexLPV2.ZeroAddress.selector);
        new ArcoraDexLPV2(address(0));
    }
}
