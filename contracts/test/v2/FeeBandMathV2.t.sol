// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeBandMathV2} from "../../src/v2/lib/FeeBandMathV2.sol";

contract FeeBandMathV2Test is Test {
    uint256 constant BPS = 10_000;

    // Default §7 schedule, descending: (upperHealthBps, rateBps).
    function _bands() internal pure returns (FeeBandMathV2.Band[] memory b) {
        b = new FeeBandMathV2.Band[](4);
        b[0] = FeeBandMathV2.Band({upperHealthBps: 10_000, rateBps: 5});
        b[1] = FeeBandMathV2.Band({upperHealthBps: 7_500, rateBps: 20});
        b[2] = FeeBandMathV2.Band({upperHealthBps: 5_000, rateBps: 75});
        b[3] = FeeBandMathV2.Band({upperHealthBps: 2_500, rateBps: 300});
    }

    // Reserve well above target → entire (small) gross charged at band-0 rate 0.05%.
    function test_healthiest_band_flat_5bps() public pure {
        // available = target - min = 1_000_000e18; reserve = 2_000_000e18 (health clamps 100%).
        FeeBandMathV2.Result memory r = FeeBandMathV2.traverse(
            1_000e18, // grossUsd
            2_000_000e18, // reserveUsd
            1_000_000e18, // minUsd
            2_000_000e18, // targetUsd  (available = 1_000_000e18)
            _bands(),
            1_000 // protocolFeeShareBps = 10%
        );
        assertTrue(r.ok);
        // fee = ceil(1000e18 * 5 / 10000) = 0.5e18 ; user = 999.5e18 ; protocol = floor(0.5e18*1000/10000)=0.05e18
        assertEq(r.totalFeeUsd, 5e17);
        assertEq(r.totalUserOutputUsd, 1_000e18 - 5e17);
        assertEq(r.totalProtocolFeeUsd, 5e16);
        assertEq(r.totalReserveDebitUsd, r.totalUserOutputUsd + r.totalProtocolFeeUsd);
    }

    // Gross that straddles bands 0 and 1: reserve at exactly 75% health, consume
    // enough debit to dip into band 1. Verifies marginal sum, not flat-rate.
    function test_two_band_marginal_sum() public pure {
        // available 1_000_000e18, reserve at health 75% => usable 750_000e18.
        FeeBandMathV2.Result memory r =
            FeeBandMathV2.traverse(300_000e18, 1_750_000e18, 1_000_000e18, 2_000_000e18, _bands(), 1_000);
        assertTrue(r.ok);
        // First ~250_000e18 debit sits in band 0 (5bps) down to health 50%? No:
        // band 0 spans 100%..75%; at start health is exactly 75% so band 0 is empty,
        // all consumption is band 1 (20bps) until 50%, then band 2. Assert > flat-5bps
        // fee and that user+protocol == debit.
        assertEq(r.totalReserveDebitUsd, r.totalUserOutputUsd + r.totalProtocolFeeUsd);
        assertGt(r.totalFeeUsd, (300_000e18 * 5) / 10_000); // strictly more than 0.05% flat
    }

    // Split-equals-single within rounding tolerance: one 100_000e18 gross vs two
    // 50_000e18 grosses must charge ~the same total fee (bounded by a few wei).
    function test_split_equals_single_within_tolerance() public pure {
        FeeBandMathV2.Band[] memory b = _bands();
        FeeBandMathV2.Result memory single =
            FeeBandMathV2.traverse(100_000e18, 1_400_000e18, 1_000_000e18, 2_000_000e18, b, 1_000);
        // First half against the starting reserve.
        FeeBandMathV2.Result memory half1 =
            FeeBandMathV2.traverse(50_000e18, 1_400_000e18, 1_000_000e18, 2_000_000e18, b, 1_000);
        // Second half against the reserve after half1's debit.
        uint256 reserveAfter = 1_400_000e18 - half1.totalReserveDebitUsd;
        FeeBandMathV2.Result memory half2 =
            FeeBandMathV2.traverse(50_000e18, reserveAfter, 1_000_000e18, 2_000_000e18, b, 1_000);
        uint256 splitFee = half1.totalFeeUsd + half2.totalFeeUsd;
        // Tolerance: ≤ 4 wei of 1e18-USD (one ceil per band crossed per call; two calls).
        uint256 diff = single.totalFeeUsd > splitFee ? single.totalFeeUsd - splitFee : splitFee - single.totalFeeUsd;
        assertLe(diff, 4, "split vs single fee divergence exceeds rounding tolerance");
    }

    // Floor breach: gross exceeds total debit capacity down to 0% health => ok=false.
    function test_floor_breach_returns_not_ok() public pure {
        // usable at start = 1_000_000e18 (health 100%); total debit capacity to floor
        // is < 1_000_000e18 (fee retained by LPs reduces debit per gross), so a gross
        // of 2_000_000e18 cannot be placed.
        FeeBandMathV2.Result memory r =
            FeeBandMathV2.traverse(2_000_000e18, 2_000_000e18, 1_000_000e18, 2_000_000e18, _bands(), 1_000);
        assertFalse(r.ok, "must signal floor breach");
    }

    // healthBps clamps to 100% above target and to 0 below floor.
    function test_health_clamps() public pure {
        assertEq(FeeBandMathV2.healthBps(3_000_000e18, 1_000_000e18, 2_000_000e18), 10_000);
        assertEq(FeeBandMathV2.healthBps(1_000_000e18, 1_000_000e18, 2_000_000e18), 0);
        assertEq(FeeBandMathV2.healthBps(1_500_000e18, 1_000_000e18, 2_000_000e18), 5_000);
    }

    // ── §7 anti-split guarantee above target ─────────────────────────────
    // The reserve ABOVE targetReserveUsd is "in the healthiest band" (§7), so its excess
    // is band-0 debit capacity. When that excess is credited, a single contiguous gross and
    // a sequence of split grosses charge the SAME total fee (a single large tx must not be
    // overcharged, and splitting must not undercharge). Pre-fix the excess is dropped: a big
    // single tx spills into bands 1-3 while split txs re-clamp at 100% and refill band 0.

    // Reserve 3M / target 2M / min 1M => excess = 1M. With excess credited, band-0 debit
    // capacity = (target-min)*(1-0.75) + excess = 250k + 1M = 1.25M, so a 500k gross sits
    // entirely in band 0 (rate 5bps). single == 2-split == 10-split, and single fee == G*5bps.
    function test_above_target_split_equals_single() public pure {
        FeeBandMathV2.Band[] memory b = _bands();
        uint256 reserve = 3_000_000e18;
        uint256 minU = 1_000_000e18;
        uint256 tgt = 2_000_000e18;
        uint256 g = 500_000e18;

        FeeBandMathV2.Result memory single = FeeBandMathV2.traverse(g, reserve, minU, tgt, b, 1_000);
        assertTrue(single.ok);
        assertEq(single.totalReserveDebitUsd, single.totalUserOutputUsd + single.totalProtocolFeeUsd);
        // All of G sits in band 0 at 5bps: fee = ceil(500_000e18 * 5 / 10_000) = 250e18 exactly.
        assertEq(single.totalFeeUsd, 250e18, "above-target single must be flat 5bps (all band 0)");

        // 2-split: each half against the live (debit-reduced) reserve.
        uint256 split2Fee = _sequentialSplitFee(g, 2, reserve, minU, tgt, b);
        // 10-split.
        uint256 split10Fee = _sequentialSplitFee(g, 10, reserve, minU, tgt, b);

        uint256 d2 = single.totalFeeUsd > split2Fee ? single.totalFeeUsd - split2Fee : split2Fee - single.totalFeeUsd;
        uint256 d10 =
            single.totalFeeUsd > split10Fee ? single.totalFeeUsd - split10Fee : split10Fee - single.totalFeeUsd;
        assertLe(d2, 8, _diffMsg("above-target 2-split", single.totalFeeUsd, split2Fee));
        assertLe(d10, 8, _diffMsg("above-target 10-split", single.totalFeeUsd, split10Fee));
    }

    // The credited excess must back exactly band 0 and no more: a gross that fits within
    // (excess + band-0 cap) stays flat-5bps; a gross beyond it crosses into band 1 (20bps),
    // making the fee strictly greater than the band-0-only fee.
    function test_above_target_capacity_credited() public pure {
        FeeBandMathV2.Band[] memory b = _bands();
        uint256 reserve = 3_000_000e18;
        uint256 minU = 1_000_000e18;
        uint256 tgt = 2_000_000e18;

        // G = 1.25M gross sits inside band 0 (max all-band-0 gross is ~1.2506M). Flat 5bps.
        uint256 gIn = 1_250_000e18;
        FeeBandMathV2.Result memory rIn = FeeBandMathV2.traverse(gIn, reserve, minU, tgt, b, 1_000);
        assertTrue(rIn.ok);
        uint256 band0OnlyFeeIn = (gIn * 5 + (BPS - 1)) / BPS; // 625e18
        assertEq(rIn.totalFeeUsd, band0OnlyFeeIn, "gross within excess+band0 cap must be flat 5bps");

        // G = 1.26M gross exceeds the band-0 capacity, spilling into band 1 (20bps): the fee
        // must strictly exceed the band-0-only fee for the same gross.
        uint256 gOut = 1_260_000e18;
        FeeBandMathV2.Result memory rOut = FeeBandMathV2.traverse(gOut, reserve, minU, tgt, b, 1_000);
        assertTrue(rOut.ok);
        uint256 band0OnlyFeeOut = (gOut * 5 + (BPS - 1)) / BPS; // 630e18
        assertGt(rOut.totalFeeUsd, band0OnlyFeeOut, "gross beyond band-0 cap must enter band 1 (fee > flat 5bps)");
    }

    // Sequential split: place `n` equal-ish slices of `g`, reducing the reserve by each
    // slice's reserve debit (the on-chain anti-split scenario), and sum the fees.
    function _sequentialSplitFee(
        uint256 g,
        uint256 n,
        uint256 reserve,
        uint256 minU,
        uint256 tgt,
        FeeBandMathV2.Band[] memory b
    ) internal pure returns (uint256 totalFee) {
        uint256 each = g / n;
        uint256 placed;
        for (uint256 k; k < n; ++k) {
            uint256 slice = (k == n - 1) ? g - placed : each;
            placed += slice;
            FeeBandMathV2.Result memory r = FeeBandMathV2.traverse(slice, reserve, minU, tgt, b, 1_000);
            require(r.ok, "split slice did not place");
            totalFee += r.totalFeeUsd;
            reserve -= r.totalReserveDebitUsd;
        }
    }

    function _diffMsg(string memory label, uint256 single, uint256 split) internal pure returns (string memory) {
        return string.concat(
            label, ": single=", vm.toString(single), " split=", vm.toString(split), " divergence exceeds 8 wei"
        );
    }
}
