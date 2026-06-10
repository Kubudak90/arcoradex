// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPythAdapterV2} from "../../src/v2/ChainlinkPythAdapterV2.sol";
import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";
import {IPythV2} from "../../src/v2/interfaces/IPythV2.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract ChainlinkPythAdapterV2Test is Test {
    ChainlinkPythAdapterV2 adapter;
    MockChainlinkFeed cl;
    MockPyth pyth;

    address token = makeAddr("USDC");
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    bytes32 constant PID = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    uint32 constant CL_STALE = 90_000; // > 86400 heartbeat (verified mainnet)
    uint32 constant PY_STALE = 120;
    uint16 constant CONF_BPS = 50; // 0.50% confidence cap
    uint16 constant DIV_BPS = 50; // 0.50% divergence cap

    function setUp() public {
        // Foundry's genesis block.timestamp is 1; warp to a realistic epoch so the
        // staleness tests' `block.timestamp - window` arithmetic cannot underflow.
        vm.warp(1_750_000_000);
        cl = new MockChainlinkFeed(8, 1e8); // $1.00 at 8 dec
        pyth = new MockPyth();
        pyth.setPrice(PID, 100_000_000, 100_000, -8, block.timestamp); // $1.00, conf 0.001, expo -8
        adapter = new ChainlinkPythAdapterV2(
            token,
            IChainlinkAggregator(address(cl)),
            IPythV2(address(pyth)),
            PID,
            CL_STALE,
            PY_STALE,
            CONF_BPS,
            DIV_BPS,
            owner
        );
    }

    // ── Happy path + normalization ──────────────────────────────────────
    function test_both_fresh_safe_and_normalized_1e18() public {
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertTrue(safe, "both fresh => safe");
        // CL $1.00 (1e18) and Pyth $1.00 (1e18) => mid 1e18.
        assertEq(p, 1e18, "normalized to 1e18");
    }

    function test_wrongToken_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPythAdapterV2.WrongToken.selector, makeAddr("other"), token));
        adapter.peekPrice(makeAddr("other"));
    }

    // ── O6: peek == read within a block ─────────────────────────────────
    function test_peek_equals_read_same_block() public {
        (uint256 rp, bool rs) = adapter.readPrice(token);
        (uint256 pp, bool ps) = adapter.peekPrice(token);
        assertEq(rp, pp, "price parity");
        assertEq(rs, ps, "safe parity");
        // read cached the safe price for display (§11), but returned the same tuple.
        assertEq(adapter.lastSafePrice1e18(), rp, unicode"§11 display cache set on safe read");
    }

    // ── Per-source staleness ────────────────────────────────────────────
    function test_chainlink_stale_is_unsafe() public {
        cl.setUpdatedAt(block.timestamp - CL_STALE - 1);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "CL beyond stale window => unsafe");
    }

    function test_chainlink_tolerates_24h_heartbeat() public {
        // A feed updated exactly 86400s ago is still fresh (window 90000).
        cl.setUpdatedAt(block.timestamp - 86_400);
        (, bool safe) = adapter.peekPrice(token);
        assertTrue(safe, unicode"must tolerate the verified 24h heartbeat");
    }

    function test_pyth_stale_is_unsafe() public {
        pyth.setPrice(PID, 100_000_000, 100_000, -8, block.timestamp - PY_STALE - 1);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "Pyth beyond stale window => unsafe");
    }

    // ── Pyth confidence-ratio bound ─────────────────────────────────────
    function test_pyth_confidence_over_bound_is_unsafe() public {
        // conf 0.6% of price > 0.50% cap.
        pyth.setPrice(PID, 100_000_000, 600_000, -8, block.timestamp);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "blown confidence => unsafe");
    }

    function test_pyth_confidence_at_bound_is_safe() public {
        // conf exactly 0.50% (== cap, not over).
        pyth.setPrice(PID, 100_000_000, 500_000, -8, block.timestamp);
        (, bool safe) = adapter.peekPrice(token);
        assertTrue(safe, "confidence at cap is allowed");
    }

    // ── Cross-source divergence ─────────────────────────────────────────
    function test_divergence_over_bound_is_unsafe() public {
        // CL $1.00, Pyth $1.006 => 0.6% > 0.50% cap.
        pyth.setPrice(PID, 100_600_000, 100_000, -8, block.timestamp);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "diverged sources => unsafe");
    }

    function test_divergence_within_bound_is_safe() public {
        // Pyth $1.004 => 0.4% < 0.50% cap.
        pyth.setPrice(PID, 100_400_000, 100_000, -8, block.timestamp);
        (, bool safe) = adapter.peekPrice(token);
        assertTrue(safe, "within divergence => safe");
    }

    // ── Zero / negative / malformed ─────────────────────────────────────
    function test_chainlink_negative_is_unsafe() public {
        cl.setAnswer(-1);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
    }

    function test_chainlink_zero_is_unsafe() public {
        cl.setAnswer(0);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
    }

    function test_pyth_negative_is_unsafe() public {
        pyth.setPrice(PID, -100_000_000, 100_000, -8, block.timestamp);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
    }

    function test_pyth_malformed_expo_is_unsafe() public {
        pyth.setPrice(PID, 100_000_000, 100_000, -19, block.timestamp); // expo < -18
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "out-of-range expo => unsafe");
    }

    function test_pyth_positive_expo_normalizes() public {
        // price 1 with expo +0 (==$1) just to exercise the expo>=0 branch; keep CL at $1.
        pyth.setPrice(PID, 1, 0, 0, block.timestamp); // conf 0 ok; price 1 * 10**18 = 1e18
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertTrue(safe);
        assertEq(p, 1e18);
    }

    // ── Reverting legs fail closed ──────────────────────────────────────
    function test_chainlink_revert_is_unsafe() public {
        cl.setRevert(true);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "CL revert caught => unsafe");
    }

    function test_pyth_revert_is_unsafe() public {
        pyth.setRevert(true);
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, "Pyth revert caught => unsafe");
    }

    // ── Single-source ⇒ unsafe (both directions) ────────────────────────
    function test_only_chainlink_alive_is_unsafe() public {
        pyth.setRevert(true);
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertFalse(safe, unicode"single surviving source insufficient (§10)");
        assertEq(p, 1e18, "surviving CL price shown for display only");
    }

    function test_only_pyth_alive_is_unsafe() public {
        cl.setRevert(true);
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
        assertEq(p, 1e18, "surviving Pyth price shown for display only");
    }

    // ── §11: last price retained while unsafe, never re-flagged safe ─────
    function test_last_price_retained_while_unsafe() public {
        adapter.readPrice(token); // cache 1e18 while safe
        cl.setRevert(true); // now unsafe
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
        // display falls back to surviving Pyth leg here; cache still queryable.
        assertEq(adapter.lastSafePrice1e18(), 1e18, unicode"last safe price retained (§11)");
        assertEq(p, 1e18);
    }

    // ── Roundness checks (incomplete round) ─────────────────────────────
    function test_chainlink_incomplete_round_is_unsafe() public {
        cl.setRound(5, 4); // answeredInRound < roundId
        (, bool safe) = adapter.peekPrice(token);
        assertFalse(safe);
    }

    // ── updatePyth isolation + fee/refund ───────────────────────────────
    function test_updatePyth_forwards_fee_and_refunds() public {
        pyth.setUpdateFee(0.001 ether);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(PID);
        vm.deal(keeper, 1 ether);
        uint256 before = keeper.balance;
        vm.prank(keeper);
        adapter.updatePyth{value: 0.01 ether}(data);
        // Spent exactly the fee; remainder refunded.
        assertEq(before - keeper.balance, 0.001 ether, "only the fee is spent");
    }

    function test_updatePyth_insufficient_fee_reverts() public {
        pyth.setUpdateFee(0.01 ether);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(PID);
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPythAdapterV2.InsufficientUpdateFee.selector, 0.001 ether, 0.01 ether)
        );
        adapter.updatePyth{value: 0.001 ether}(data);
    }

    function test_updatePyth_does_not_affect_read_in_same_block() public {
        // Drive Pyth stale, then a pull refreshes publishTime; peek BEFORE pull is unsafe,
        // AFTER pull is safe — but read/peek themselves never pull (O6).
        pyth.setPrice(PID, 100_000_000, 100_000, -8, block.timestamp - PY_STALE - 1);
        (, bool beforePull) = adapter.peekPrice(token);
        assertFalse(beforePull, "stale Pyth, no pull in peek");
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(PID);
        adapter.updatePyth(data); // keeper pull bumps publishTime
        (uint256 rp, bool rs) = adapter.readPrice(token);
        (uint256 pp, bool ps) = adapter.peekPrice(token);
        assertEq(rp, pp);
        assertEq(rs, ps, "peek==read still holds after an external pull");
        assertTrue(rs, "fresh after the keeper pull");
    }

    // ── Governance setters ──────────────────────────────────────────────
    function test_setters_onlyOwner() public {
        vm.expectRevert();
        adapter.setMaxDivergenceBps(100);
        vm.prank(owner);
        adapter.setMaxDivergenceBps(100);
        assertEq(adapter.maxDivergenceBps(), 100);
    }

    function test_constructor_rejects_bad_params() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPythAdapterV2.InvalidConfBps.selector, uint16(0)));
        new ChainlinkPythAdapterV2(
            token, IChainlinkAggregator(address(cl)), IPythV2(address(pyth)), PID, CL_STALE, PY_STALE, 0, DIV_BPS, owner
        );
    }
}
