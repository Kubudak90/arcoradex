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
}
