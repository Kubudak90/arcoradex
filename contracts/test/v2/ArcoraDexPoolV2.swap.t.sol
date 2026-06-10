// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";
import {IArcoraDexPoolV2} from "../../src/v2/interfaces/IArcoraDexPoolV2.sol";

contract ArcoraDexPoolV2SwapTest is V2Fixture {
    function setUp() public {
        _deployV2();
        // Seed each reserve to its TARGET (health 100%) so band-0 (0.05%) applies at the margin.
        _seed(usdc, makeAddr("seeder"), 2_000_000e6);
        _seed(eurc, makeAddr("seeder2"), 2_000_000e6);
    }

    function test_swap_healthiest_band_charges_5bps() public {
        _mint(usdc, alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        uint256 out = pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp + 1, alice);
        vm.stopPrank();
        // gross 1000 USD; eurc reserve 2M = target → still drops below target as we debit,
        // but a 1000-USD debit barely dents health, so the whole thing is band-0 (0.05%).
        // amountOut ≈ 1000e6 - ceil(1000e6*5/10000) = 1000e6 - 5e5 = 999_500000 (minus rounding).
        assertApproxEqAbs(out, 999_500000, 2, "healthiest-band 5bps swap output");
    }

    function test_swap_reverts_when_tokenOut_oracle_unsafe() public {
        adapter.setSafe(address(eurc), false);
        _mint(usdc, alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, address(eurc)));
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp + 1, alice);
        vm.stopPrank();
    }

    function test_quoteSwap_matches_execution() public {
        _mint(usdc, alice, 5_000e6);
        (uint256 q,,,) = pool.quoteSwapV2(address(usdc), address(eurc), 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 5_000e6);
        uint256 exec = pool.swap(address(usdc), address(eurc), 5_000e6, 0, block.timestamp + 1, alice);
        vm.stopPrank();
        assertEq(exec, q, "quote must equal execution");
    }
}
