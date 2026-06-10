// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockOracleAdapterV2Settable} from "../../src/v2/testnet/MockOracleAdapterV2Settable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockOracleAdapterV2SettableTest is Test {
    MockOracleAdapterV2Settable internal adapter;
    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal token = makeAddr("token");

    function setUp() public {
        // owner=admin, writer=keeper
        adapter = new MockOracleAdapterV2Settable(admin, keeper);
    }

    function test_constructor_sets_owner_and_writer() public view {
        assertEq(adapter.owner(), admin, "owner");
        assertEq(adapter.writer(), keeper, "writer");
    }

    function test_constructor_rejects_zero_writer() public {
        vm.expectRevert(MockOracleAdapterV2Settable.ZeroAddress.selector);
        new MockOracleAdapterV2Settable(admin, address(0));
    }

    function test_writer_can_setPrice_and_peek_equals_read() public {
        vm.prank(keeper);
        adapter.setPrice(token, 1e18, true);
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertEq(p, 1e18, "peek price");
        assertTrue(safe, "peek safe");
        (uint256 pr, bool sr) = adapter.readPrice(token);
        assertEq(pr, p, "read==peek price");
        assertEq(sr, safe, "read==peek safe");
    }

    function test_nonwriter_cannot_setPrice() public {
        vm.prank(stranger);
        vm.expectRevert(MockOracleAdapterV2Settable.NotWriter.selector);
        adapter.setPrice(token, 1e18, true);
    }

    function test_writer_can_flip_safe_for_drills() public {
        vm.prank(keeper);
        adapter.setPrice(token, 115e16, true);
        vm.prank(keeper);
        adapter.setSafe(token, false);
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertEq(p, 115e16, "price retained when flipped unsafe");
        assertFalse(safe, "flipped unsafe");
    }

    function test_owner_can_rotate_writer() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(admin);
        adapter.setWriter(newKeeper);
        assertEq(adapter.writer(), newKeeper, "rotated writer");
        // old keeper is now rejected
        vm.prank(keeper);
        vm.expectRevert(MockOracleAdapterV2Settable.NotWriter.selector);
        adapter.setPrice(token, 1e18, true);
    }

    function test_nonowner_cannot_setWriter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.setWriter(stranger);
    }

    function test_unset_token_reads_zero_and_unsafe() public view {
        (uint256 p, bool safe) = adapter.peekPrice(token);
        assertEq(p, 0, "unset price 0");
        assertFalse(safe, "unset unsafe");
    }

    function test_ownership_is_two_step() public {
        address gov = makeAddr("gov");
        vm.prank(admin);
        adapter.transferOwnership(gov);
        assertEq(adapter.owner(), admin, "still admin until accept");
        assertEq(adapter.pendingOwner(), gov, "pending gov");
        vm.prank(gov);
        adapter.acceptOwnership();
        assertEq(adapter.owner(), gov, "gov now owner");
    }
}
