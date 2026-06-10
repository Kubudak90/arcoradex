// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";

/// @notice Pins exact marginal-fee behaviour at each §7 band on the live Pool. Seeding
/// EURC to a chosen reserve sets its starting health; a small swap then samples the
/// marginal band rate. Default config: available = 1,000,000 USD; bands 0.05/0.20/0.75/3.00%.
contract ArcoraDexPoolV2BandsTest is V2Fixture {
    function setUp() public {
        _deployV2();
        _seed(usdc, makeAddr("seeder"), 5_000_000e6); // deep USDC input reservoir
    }

    function _seedEurcToHealth(uint256 healthBps) internal {
        // reserveUsd = min + available * healthBps / 10000 ; tokens (6dec) = reserveUsd / 1e12.
        uint256 reserveUsd = 1_000_000e18 + (1_000_000e18 * healthBps) / 10_000;
        uint256 tokens = reserveUsd / 1e12;
        _seed(eurc, makeAddr("eseeder"), tokens);
    }

    function _marginalFeeBps(uint256 healthBps) internal returns (uint256 feeBpsApprox) {
        _seedEurcToHealth(healthBps);
        uint256 amtIn = 100e6; // tiny → stays within the starting band
        _mint(usdc, alice, amtIn);
        vm.startPrank(alice);
        usdc.approve(address(pool), amtIn);
        uint256 out = pool.swap(address(usdc), address(eurc), amtIn, 0, block.timestamp + 1, alice);
        vm.stopPrank();
        // gross ≈ 100e6 ; fee ≈ gross - out ; feeBps = fee*10000/gross.
        uint256 fee = 100e6 - out;
        feeBpsApprox = (fee * 10_000) / 100e6;
    }

    function test_band0_5bps_at_90pct() public {
        assertApproxEqAbs(_marginalFeeBps(9_000), 5, 1, "band-0 0.05%");
    }

    function test_band1_20bps_at_60pct() public {
        assertApproxEqAbs(_marginalFeeBps(6_000), 20, 1, "band-1 0.20%");
    }

    function test_band2_75bps_at_40pct() public {
        assertApproxEqAbs(_marginalFeeBps(4_000), 75, 1, "band-2 0.75%");
    }

    function test_band3_300bps_at_10pct() public {
        assertApproxEqAbs(_marginalFeeBps(1_000), 300, 1, "band-3 3.00%");
    }
}
