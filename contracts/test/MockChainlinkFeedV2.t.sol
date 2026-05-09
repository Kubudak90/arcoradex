// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockChainlinkFeedV2 } from "../src/testnet/MockChainlinkFeedV2.sol";

contract MockChainlinkFeedV2Test is Test {
    MockChainlinkFeedV2 feed;

    address owner   = address(0xA11CE);
    address writer  = address(0xBEEF);
    address other   = address(0xCAFE);

    function setUp() public {
        feed = new MockChainlinkFeedV2(8, 1.0e8, writer, owner);
    }

    function test_constructor_setsState() public view {
        assertEq(feed.owner(), owner);
        assertEq(feed.writer(), writer);
        assertEq(feed.latestAnswer(), 1.0e8);
        assertEq(feed.latestUpdatedAt(), block.timestamp);
        assertEq(feed.decimals(), 8);
    }

    function test_setAnswer_revertsIfNotWriter() public {
        vm.prank(other);
        vm.expectRevert(MockChainlinkFeedV2.NotWriter.selector);
        feed.setAnswer(1.01e8);

        vm.prank(owner); // owner is NOT writer
        vm.expectRevert(MockChainlinkFeedV2.NotWriter.selector);
        feed.setAnswer(1.01e8);
    }

    function test_setAnswer_succeedsIfWriter() public {
        vm.warp(block.timestamp + 600);
        vm.prank(writer);
        feed.setAnswer(1.05e8);
        assertEq(feed.latestAnswer(), 1.05e8);
        assertEq(feed.latestUpdatedAt(), block.timestamp);
    }

    function test_setWriter_revertsIfNotOwner() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        feed.setWriter(other);

        vm.prank(writer); // writer is NOT owner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, writer));
        feed.setWriter(other);
    }

    function test_setWriter_updatesWriterAndOldWriterLosesAccess() public {
        address newWriter = address(0xD00D);
        vm.prank(owner);
        feed.setWriter(newWriter);
        assertEq(feed.writer(), newWriter);

        // Old writer can no longer write
        vm.prank(writer);
        vm.expectRevert(MockChainlinkFeedV2.NotWriter.selector);
        feed.setAnswer(1.10e8);

        // New writer can
        vm.prank(newWriter);
        feed.setAnswer(1.10e8);
        assertEq(feed.latestAnswer(), 1.10e8);
    }

    function test_transferOwnership_isTwoStep() public {
        address newOwner = address(0xE0F);

        vm.prank(owner);
        feed.transferOwnership(newOwner);

        // Until accepted, old owner still in control
        assertEq(feed.owner(), owner);
        assertEq(feed.pendingOwner(), newOwner);

        // Old owner can still setWriter at this point
        vm.prank(owner);
        feed.setWriter(other);
        assertEq(feed.writer(), other);

        // New owner accepts
        vm.prank(newOwner);
        feed.acceptOwnership();
        assertEq(feed.owner(), newOwner);
        assertEq(feed.pendingOwner(), address(0));

        // Old owner no longer admin
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        feed.setWriter(writer);
    }

    function test_latestRoundData_shape() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, 1.0e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }
}
