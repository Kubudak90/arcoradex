// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockChainlinkFeedV2} from "../src/testnet/MockChainlinkFeedV2.sol";

contract MockChainlinkFeedV2Test is Test {
    MockChainlinkFeedV2 feed;

    address owner = makeAddr("owner");
    address writer = makeAddr("writer");
    address other = makeAddr("other");

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

    function test_setAnswer_emitsAnswerUpdated() public {
        vm.warp(block.timestamp + 600);
        vm.expectEmit(false, false, false, true, address(feed));
        emit MockChainlinkFeedV2.AnswerUpdated(1.05e8, block.timestamp);
        vm.prank(writer);
        feed.setAnswer(1.05e8);
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
        address newWriter = makeAddr("newWriter");
        vm.prank(owner);
        feed.setWriter(newWriter);
        assertEq(feed.writer(), newWriter);

        // Old writer can no longer write
        vm.prank(writer);
        vm.expectRevert(MockChainlinkFeedV2.NotWriter.selector);
        feed.setAnswer(1.1e8);

        // New writer can
        vm.prank(newWriter);
        feed.setAnswer(1.1e8);
        assertEq(feed.latestAnswer(), 1.1e8);
    }

    function test_setWriter_emitsWriterUpdated() public {
        address newWriter = makeAddr("newWriter");
        vm.expectEmit(true, true, false, false, address(feed));
        emit MockChainlinkFeedV2.WriterUpdated(writer, newWriter);
        vm.prank(owner);
        feed.setWriter(newWriter);
    }

    function test_transferOwnership_isTwoStep() public {
        address newOwner = makeAddr("newOwner");

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
        assertGt(roundId, 0, "roundId must be non-zero after construction");
        assertEq(answer, 1.0e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, roundId, "answeredInRound must equal roundId");
    }

    // ── D1 new tests: positivity check + monotonic roundId ────────────────────

    function test_setAnswer_reverts_on_zero() public {
        vm.prank(writer);
        vm.expectRevert(MockChainlinkFeedV2.AnswerNotPositive.selector);
        feed.setAnswer(0);
    }

    function test_setAnswer_reverts_on_negative() public {
        vm.prank(writer);
        vm.expectRevert(MockChainlinkFeedV2.AnswerNotPositive.selector);
        feed.setAnswer(-1);
    }

    function test_setAnswer_accepts_positive_after_zero_reverts() public {
        vm.startPrank(writer);
        vm.expectRevert(MockChainlinkFeedV2.AnswerNotPositive.selector);
        feed.setAnswer(0);
        feed.setAnswer(123_000_000); // must not revert
        assertEq(feed.latestAnswer(), 123_000_000);
        vm.stopPrank();
    }

    function test_roundId_is_monotonic() public {
        vm.startPrank(writer);
        feed.setAnswer(1e8);
        (uint80 r1,,,, uint80 air1) = feed.latestRoundData();
        feed.setAnswer(2e8);
        (uint80 r2,,,, uint80 air2) = feed.latestRoundData();
        feed.setAnswer(3e8);
        (uint80 r3,,,, uint80 air3) = feed.latestRoundData();
        vm.stopPrank();
        assertGt(r2, r1);
        assertGt(r3, r2);
        assertEq(air1, r1, "answeredInRound matches roundId");
        assertEq(air2, r2);
        assertEq(air3, r3);
    }

    function test_roundId_does_not_advance_on_revert() public {
        vm.startPrank(writer);
        feed.setAnswer(1e8);
        (uint80 rBefore,,,,) = feed.latestRoundData();

        vm.expectRevert(MockChainlinkFeedV2.AnswerNotPositive.selector);
        feed.setAnswer(0);

        (uint80 rAfter,,,,) = feed.latestRoundData();
        assertEq(rBefore, rAfter, "failed setAnswer must not advance roundId");
        vm.stopPrank();
    }
}
