// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexLP} from "../src/ArcoraDexLP.sol";
import {IArcoraDexLP} from "../src/interfaces/IArcoraDexLP.sol";

/// @dev Minimal stub that satisfies the notifyLPTransfer callback so LP unit
/// tests don't need a full pool deployment. It records the last call for
/// assertion purposes but otherwise does nothing.
contract MockMinter {
    address public lastFrom;
    address public lastTo;

    // Expose mint/burn so the test can drive them without prank overhead.
    function mint(ArcoraDexLP lp, address to, uint256 amount) external {
        lp.mint(to, amount);
    }

    function burn(ArcoraDexLP lp, address from, uint256 amount) external {
        lp.burn(from, amount);
    }

    function notifyLPTransfer(address from, address to) external {
        lastFrom = from;
        lastTo = to;
    }
}

contract ArcoraDexLPTest is Test {
    MockMinter minterContract;
    ArcoraDexLP lp;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        minterContract = new MockMinter();
        lp = new ArcoraDexLP(address(minterContract));
    }

    function test_metadata() public view {
        assertEq(lp.name(), "Arcora DEX LP");
        assertEq(lp.symbol(), "ADEX-LP");
        assertEq(lp.decimals(), 18);
        assertEq(lp.MINTER(), address(minterContract));
        assertEq(lp.totalSupply(), 0);
    }

    function test_constructor_revertsZeroMinter() public {
        vm.expectRevert(IArcoraDexLP.ZeroAddress.selector);
        new ArcoraDexLP(address(0));
    }

    function test_mint_byMinter() public {
        vm.prank(address(minterContract));
        lp.mint(alice, 100e18);
        assertEq(lp.balanceOf(alice), 100e18);
        assertEq(lp.totalSupply(), 100e18);
    }

    function test_mint_revertsNotMinter() public {
        vm.prank(alice);
        vm.expectRevert(IArcoraDexLP.NotMinter.selector);
        lp.mint(alice, 100e18);
    }

    function test_burn_byMinter() public {
        vm.startPrank(address(minterContract));
        lp.mint(alice, 100e18);
        lp.burn(alice, 40e18);
        vm.stopPrank();
        assertEq(lp.balanceOf(alice), 60e18);
        assertEq(lp.totalSupply(), 60e18);
    }

    function test_burn_revertsNotMinter() public {
        vm.prank(address(minterContract));
        lp.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(IArcoraDexLP.NotMinter.selector);
        lp.burn(alice, 40e18);
    }

    function test_transfer_invokes_hook() public {
        // Exercises the MockMinter stub, which has no hold gate, so this documents
        // hook dispatch on transfer rather than an ungated transfer (real LP
        // transfers are sender-gated by notifyLPTransfer).
        vm.prank(address(minterContract));
        lp.mint(alice, 100e18);

        vm.prank(alice);
        lp.transfer(bob, 30e18);
        assertEq(lp.balanceOf(alice), 70e18);
        assertEq(lp.balanceOf(bob), 30e18);
    }

    /// @notice Verifies the _update hook invokes notifyLPTransfer on the minter
    /// for non-zero wallet-to-wallet transfers, but NOT for mints, burns, or
    /// zero-value transfers. H-1 (audit 2026-05-31) added the `value > 0` guard:
    /// a zero-value transfer must not reach the hook, otherwise it could be
    /// weaponised to grief a victim's min-hold lock without moving any claim.
    function test_transfer_hook_calls_notifyLPTransfer() public {
        vm.prank(address(minterContract));
        lp.mint(alice, 100e18);

        // Mint (from==0) must NOT call notifyLPTransfer — lastFrom/To stay zero.
        assertEq(minterContract.lastFrom(), address(0));
        assertEq(minterContract.lastTo(), address(0));

        // Zero-value transfer (H-1 guard) must NOT call notifyLPTransfer.
        vm.prank(alice);
        lp.transfer(bob, 0);
        assertEq(minterContract.lastFrom(), address(0), "zero-value transfer must not reach the hook");
        assertEq(minterContract.lastTo(), address(0), "zero-value transfer must not reach the hook");

        // Normal (value > 0) transfer must invoke notifyLPTransfer.
        vm.prank(alice);
        lp.transfer(bob, 50e18);
        assertEq(minterContract.lastFrom(), alice);
        assertEq(minterContract.lastTo(), bob);

        // Burn (to==0) must NOT update lastFrom/To (the hook skips burns).
        vm.prank(address(minterContract));
        lp.burn(bob, 50e18);
        // lastFrom/To remain as set by the transfer above.
        assertEq(minterContract.lastFrom(), alice);
        assertEq(minterContract.lastTo(), bob);
    }
}
