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
        feed = _newFeed(8, 1.0e8, writer, owner);
    }

    /// @dev Permissive-bounds helper: preserves pre-H-2 behaviour byte-identically
    /// (any positive answer, no max-jump, no min-interval) so existing assertions
    /// remain valid. New H-2 tests construct feeds with TIGHT bounds directly.
    function _newFeed(uint8 dec, int256 ans, address w, address o) internal returns (MockChainlinkFeedV2) {
        return new MockChainlinkFeedV2(dec, ans, w, o, 1, type(int256).max, 0, 0);
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

    function test_roundId_does_not_advance_on_NotWriter_revert() public {
        // First record a real round so we have a known _roundId baseline.
        vm.prank(writer);
        feed.setAnswer(1e8);
        (uint80 rBefore,,,,) = feed.latestRoundData();

        // A non-writer call must revert AND must not advance _roundId.
        vm.prank(address(0xDEAD)); // anyone NOT the writer
        vm.expectRevert(MockChainlinkFeedV2.NotWriter.selector);
        feed.setAnswer(2e8);

        (uint80 rAfter,,,,) = feed.latestRoundData();
        assertEq(rBefore, rAfter, "NotWriter revert must not advance _roundId");
    }

    // ── H-2 new tests: on-chain sanity band + max-jump + min-interval ──────────

    int256 constant LO = 0.95e8; //  95_000_000
    int256 constant HI = 1.05e8; // 105_000_000
    uint32 constant JUMP_BPS = 1000; // 10%
    uint32 constant MIN_SECS = 60;

    /// @dev Tight-bounds feed: initial answer = 1.0e8 (in-band).
    function _newTightFeed() internal returns (MockChainlinkFeedV2) {
        return new MockChainlinkFeedV2(8, 1.0e8, writer, owner, LO, HI, JUMP_BPS, MIN_SECS);
    }

    function test_h2_constructor_revertsInitialBelowBand() public {
        vm.expectRevert(abi.encodeWithSelector(MockChainlinkFeedV2.AnswerOutOfBounds.selector, int256(0.5e8), LO, HI));
        new MockChainlinkFeedV2(8, 0.5e8, writer, owner, LO, HI, JUMP_BPS, MIN_SECS);
    }

    function test_h2_constructor_revertsInitialAboveBand() public {
        vm.expectRevert(abi.encodeWithSelector(MockChainlinkFeedV2.AnswerOutOfBounds.selector, int256(2e8), LO, HI));
        new MockChainlinkFeedV2(8, 2e8, writer, owner, LO, HI, JUMP_BPS, MIN_SECS);
    }

    function test_h2_setAnswer_revertsBelowMinBand() public {
        MockChainlinkFeedV2 f = _newTightFeed();
        vm.warp(block.timestamp + 600);
        vm.prank(writer);
        // 0.90e8 is below LO (0.95e8)
        vm.expectRevert(abi.encodeWithSelector(MockChainlinkFeedV2.AnswerOutOfBounds.selector, int256(0.90e8), LO, HI));
        f.setAnswer(0.90e8);
    }

    function test_h2_setAnswer_revertsAboveMaxBand() public {
        MockChainlinkFeedV2 f = _newTightFeed();
        vm.warp(block.timestamp + 600);
        vm.prank(writer);
        // 1.10e8 is above HI (1.05e8)
        vm.expectRevert(abi.encodeWithSelector(MockChainlinkFeedV2.AnswerOutOfBounds.selector, int256(1.10e8), LO, HI));
        f.setAnswer(1.10e8);
    }

    function test_h2_setAnswer_revertsOnMaxJump() public {
        MockChainlinkFeedV2 f = _newTightFeed();
        vm.warp(block.timestamp + 600);
        // From 1.0e8 to 1.04e8 is a 4% jump but band allows it; cap is 10% (1000 bps).
        // Use a move that is in-band yet exceeds the jump cap: choose tighter bounds.
        // Construct a feed with wide band but tight jump cap to isolate the jump guard.
        MockChainlinkFeedV2 g = new MockChainlinkFeedV2(8, 1.0e8, writer, owner, 1, type(int256).max, JUMP_BPS, 0);
        vm.prank(writer);
        // 1.0e8 -> 1.2e8 is a 20% jump, exceeds 10% cap. diffBps = 2000.
        vm.expectRevert(abi.encodeWithSelector(MockChainlinkFeedV2.MaxJumpExceeded.selector, uint256(2000), JUMP_BPS));
        g.setAnswer(1.2e8);
    }

    function test_h2_setAnswer_revertsBeforeMinInterval() public {
        MockChainlinkFeedV2 f = _newTightFeed();
        uint256 t0 = block.timestamp;
        // First in-band write at t0+60 to establish a fresh timestamp.
        vm.warp(t0 + MIN_SECS);
        vm.prank(writer);
        f.setAnswer(1.01e8);
        uint256 last = block.timestamp;

        // Second write only 30s later: below the 60s min interval.
        vm.warp(last + 30);
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(MockChainlinkFeedV2.MinIntervalNotMet.selector, block.timestamp, last + MIN_SECS)
        );
        f.setAnswer(1.02e8);
    }

    function test_h2_setAnswer_acceptsInBandWithinJump() public {
        MockChainlinkFeedV2 f = _newTightFeed();
        vm.warp(block.timestamp + MIN_SECS);
        vm.prank(writer);
        // 1.0e8 -> 1.04e8: in band [0.95e8,1.05e8], 4% jump < 10% cap, interval >= 60s. OK.
        f.setAnswer(1.04e8);
        assertEq(f.latestAnswer(), 1.04e8);
        assertEq(f.latestUpdatedAt(), block.timestamp);
    }

    function test_h2_immutableBoundsExposed() public {
        MockChainlinkFeedV2 f = _newTightFeed();
        assertEq(f.minAnswer(), LO);
        assertEq(f.maxAnswer(), HI);
        assertEq(uint256(f.maxJumpBps()), uint256(JUMP_BPS));
        assertEq(uint256(f.minUpdateSeconds()), uint256(MIN_SECS));
    }
}
