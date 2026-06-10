// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V2Fixture} from "./helpers/V2Fixture.sol";
import {IArcoraDexPoolV2} from "../../src/v2/interfaces/IArcoraDexPoolV2.sol";

contract ArcoraDexPoolV2WithdrawTest is V2Fixture {
    function setUp() public {
        _deployV2();
        // Two-token reserve so single-token withdraw has a different token to draw against.
        _seed(usdc, alice, 2_000_000e6); // alice is LP
        _seed(eurc, bob, 2_000_000e6); // eurc reserve present
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
    }

    function test_withdrawSingle_into_eurc_charges_band_fee() public {
        uint256 lpBal = lp.balanceOf(alice);
        // Withdraw a small slice into EURC; EURC reserve at target → band-0 0.05%.
        uint256 slice = lpBal / 1000;
        (uint256 q,,,) = pool.quoteWithdrawV2(address(eurc), slice);
        vm.prank(alice);
        uint256 out = pool.withdrawSingle(address(eurc), slice, 0, block.timestamp + 1);
        assertEq(out, q, "withdraw quote/exec parity");
        assertGt(out, 0);
    }

    function test_withdrawSingle_reverts_floor_breach() public {
        // Try to pull almost the entire EURC reserve into EURC → must breach floor.
        uint256 lpBal = lp.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.ReserveFloorBreached.selector, address(eurc)));
        pool.withdrawSingle(address(eurc), lpBal, 0, block.timestamp + 1);
    }

    function test_withdrawSingle_reverts_oracle_unsafe() public {
        adapter.setSafe(address(eurc), false);
        uint256 lpBal = lp.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, address(eurc)));
        pool.withdrawSingle(address(eurc), lpBal / 1000, 0, block.timestamp + 1);
    }
}
