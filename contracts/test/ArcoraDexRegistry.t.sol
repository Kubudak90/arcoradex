// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {IArcoraDexRegistry} from "../src/interfaces/IArcoraDexRegistry.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
import {MockChainlinkFeed} from "../src/testnet/MockChainlinkFeed.sol";

contract ArcoraDexRegistryTest is Test {
    ArcoraDexRegistry reg;
    MintableERC20 usdc;
    MockChainlinkFeed feed;
    address owner = makeAddr("owner");
    address newOwner = makeAddr("newOwner");
    address attacker = makeAddr("attacker");

    function setUp() public {
        reg = new ArcoraDexRegistry(owner);
        usdc = new MintableERC20("USD Coin", "USDC", 6, owner);
        feed = new MockChainlinkFeed(8, int256(1e8)); // 8 dec, $1.00
    }

    // ── listToken ───────────────────────────────────────────────────
    function test_listToken_succeeds() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);

        IArcoraDexRegistry.TokenInfo memory info = reg.tokenInfo(address(usdc));
        assertEq(info.decimals, 6);
        assertTrue(info.isActive);
        assertEq(address(info.usdOracle), address(feed));
        assertEq(info.maxOracleDeviationBps, 50);
        assertEq(reg.tokens(0), address(usdc));
        assertEq(reg.tokensLength(), 1);
        assertTrue(reg.isActive(address(usdc)));
    }

    function test_listToken_revertsZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(IArcoraDexRegistry.ZeroAddress.selector);
        reg.listToken(address(0), 6, IChainlinkAggregator(address(feed)), 50, 3600);
    }

    function test_listToken_revertsZeroOracle() public {
        vm.prank(owner);
        vm.expectRevert(IArcoraDexRegistry.ZeroAddress.selector);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(0)), 50, 3600);
    }

    function test_listToken_revertsBadDecimals() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.InvalidDecimals.selector, uint8(0)));
        reg.listToken(address(usdc), 0, IChainlinkAggregator(address(feed)), 50, 3600);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.InvalidDecimals.selector, uint8(19)));
        reg.listToken(address(usdc), 19, IChainlinkAggregator(address(feed)), 50, 3600);
    }

    function test_listToken_revertsDecimalMismatch() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.TokenDecimalMismatch.selector, address(usdc), 18, 6));
        reg.listToken(address(usdc), 18, IChainlinkAggregator(address(feed)), 50, 3600);
    }

    function test_listToken_revertsBadDeviation() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.InvalidDeviation.selector, uint16(0)));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 0, 3600);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.InvalidDeviation.selector, uint16(10_001)));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 10_001, 3600);
    }

    function test_listToken_revertsAlreadyListed() public {
        vm.startPrank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.TokenAlreadyListed.selector, address(usdc)));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 100, 3600);
        vm.stopPrank();
    }

    function test_listToken_revertsNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(); // OZ Ownable revert
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);
    }

    // ── setOracle ──────────────────────────────────────────────────
    function test_setOracle_updates() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);

        MockChainlinkFeed feed2 = new MockChainlinkFeed(8, int256(1e8));
        vm.prank(owner);
        reg.setOracle(address(usdc), IChainlinkAggregator(address(feed2)));

        assertEq(address(reg.tokenInfo(address(usdc)).usdOracle), address(feed2));
    }

    function test_setOracle_revertsNotListed() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.TokenNotListed.selector, address(usdc)));
        reg.setOracle(address(usdc), IChainlinkAggregator(address(feed)));
    }

    // ── I-7: setOracle defense-in-depth decimals guard ─────────────────
    /// @dev The Pool reads `oracle.decimals()` at runtime to scale answers to
    /// 1e18. A feed reporting > 18 decimals is out of the supported domain and
    /// would mis-scale prices, so `setOracle` rejects it up front. Repointing the
    /// feed is an instant operation (the next priced op reads the new feed), so
    /// this guard is the last line of defense against a misconfigured repoint.
    function test_i7_setOracle_rejectsOver18Decimals() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);

        // A feed that reports 19 decimals — out of the supported [1, 18] domain.
        MockChainlinkFeed badFeed = new MockChainlinkFeed(19, int256(1e8));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.OracleDecimalsTooHigh.selector, uint8(19)));
        reg.setOracle(address(usdc), IChainlinkAggregator(address(badFeed)));

        // The original feed is unchanged after the rejected repoint.
        assertEq(address(reg.tokenInfo(address(usdc)).usdOracle), address(feed));
    }

    /// @dev Boundary: a feed reporting exactly 18 decimals is accepted.
    function test_i7_setOracle_accepts18Decimals() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);

        MockChainlinkFeed feed18 = new MockChainlinkFeed(18, int256(1e18));
        vm.prank(owner);
        reg.setOracle(address(usdc), IChainlinkAggregator(address(feed18)));

        assertEq(address(reg.tokenInfo(address(usdc)).usdOracle), address(feed18));
    }

    // ── setDeviation ───────────────────────────────────────────────
    function test_setDeviation_updates() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);

        vm.prank(owner);
        reg.setDeviation(address(usdc), 200);
        assertEq(reg.tokenInfo(address(usdc)).maxOracleDeviationBps, 200);
    }

    // ── deactivate / reactivate ────────────────────────────────────
    function test_deactivate_then_reactivate() public {
        vm.startPrank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);
        reg.deactivateToken(address(usdc));
        assertFalse(reg.isActive(address(usdc)));
        reg.reactivateToken(address(usdc));
        assertTrue(reg.isActive(address(usdc)));
        vm.stopPrank();
    }

    function test_deactivate_revertsNotListed() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.TokenNotListed.selector, address(usdc)));
        reg.deactivateToken(address(usdc));
    }

    // ── I-1: deactivate reserve-guard ───────────────────────────────
    /// @dev Back-compat: on a bare registry with no `setPool`, deactivate must
    /// still work even if some (unknown) pool holds reserves — the guard is keyed
    /// on the registry's own `pool` reference, which is unset here.
    function test_i1_deactivate_allowedWhenPoolUnset() public {
        vm.startPrank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);
        assertEq(reg.pool(), address(0), "pool must be unset in the bare fixture");
        reg.deactivateToken(address(usdc));
        vm.stopPrank();
        assertFalse(reg.isActive(address(usdc)));
    }

    // ── ownership transfer (Ownable2Step) ──────────────────────────
    function test_ownership_transfer_two_step() public {
        vm.prank(owner);
        reg.transferOwnership(newOwner);
        // pendingOwner is set; owner is unchanged until acceptOwnership
        assertEq(reg.pendingOwner(), newOwner);
        assertEq(reg.owner(), owner);

        vm.prank(newOwner);
        reg.acceptOwnership();
        assertEq(reg.owner(), newOwner);
    }

    // ── InvalidStaleSeconds ────────────────────────────────────────
    function test_RevertsOnInvalidStaleSeconds_zero() public {
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.InvalidStaleSeconds.selector, uint32(0)));
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 0);
    }

    function test_RevertsOnInvalidStaleSeconds_tooLow() public {
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.InvalidStaleSeconds.selector, uint32(59)));
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 59);
    }

    function test_RevertsOnInvalidStaleSeconds_tooHigh() public {
        uint32 tooHigh = uint32(7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.InvalidStaleSeconds.selector, tooHigh));
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, tooHigh);
    }

    function test_SetMaxStaleSeconds_updatesAndEmits() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);
        vm.expectEmit(true, false, false, true);
        emit IArcoraDexRegistry.MaxStaleSecondsUpdated(address(usdc), 3600, 7200);
        vm.prank(owner);
        reg.setMaxStaleSeconds(address(usdc), 7200);
        assertEq(reg.tokenInfo(address(usdc)).maxStaleSeconds, 7200);
    }

    // ── L-9: MAX_TOKENS cap + removeToken (bound NAV loop) ─────────────
    /// @dev Lists `MAX_TOKENS` distinct 6-decimal tokens, each with its own $1.00
    /// feed, then asserts the next listToken reverts MaxTokensReached.
    function test_l9_listToken_revertsAtMaxTokens() public {
        uint256 cap = reg.MAX_TOKENS();
        vm.startPrank(owner);
        for (uint256 i = 0; i < cap; i++) {
            MintableERC20 tok = new MintableERC20("Tok", "TOK", 6, owner);
            MockChainlinkFeed f = new MockChainlinkFeed(8, int256(1e8));
            reg.listToken(address(tok), 6, IChainlinkAggregator(address(f)), 50, 3600);
        }
        assertEq(reg.tokensLength(), cap);

        // The (cap + 1)-th listing must revert.
        MintableERC20 overflowTok = new MintableERC20("Over", "OVR", 6, owner);
        MockChainlinkFeed overflowFeed = new MockChainlinkFeed(8, int256(1e8));
        vm.expectRevert(IArcoraDexRegistry.MaxTokensReached.selector);
        reg.listToken(address(overflowTok), 6, IChainlinkAggregator(address(overflowFeed)), 50, 3600);
        vm.stopPrank();
    }

    function test_l9_removeToken_dropsFromList() public {
        // List a second token so removal of the first is observable as a swap-pop.
        MintableERC20 dai = new MintableERC20("Dai", "DAI", 18, owner);
        MockChainlinkFeed fDai = new MockChainlinkFeed(8, int256(1e8));

        vm.startPrank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);
        reg.listToken(address(dai), 18, IChainlinkAggregator(address(fDai)), 50, 3600);
        assertEq(reg.tokensLength(), 2);

        // Must be deactivated before removal (I-1 guards that reserves are drained).
        reg.deactivateToken(address(usdc));
        reg.removeToken(address(usdc));
        vm.stopPrank();

        // List shrank and usdc is gone; dai survived (moved into the freed slot).
        assertEq(reg.tokensLength(), 1);
        assertEq(reg.tokens(0), address(dai));

        // _info cleared: oracle reset to zero, so it reads as not-listed.
        IArcoraDexRegistry.TokenInfo memory info = reg.tokenInfo(address(usdc));
        assertEq(address(info.usdOracle), address(0));
        assertEq(info.decimals, 0);
        assertFalse(info.isActive);
        assertFalse(reg.isActive(address(usdc)));
    }

    function test_l9_removeToken_revertsIfActive() public {
        vm.startPrank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(feed)), 50, 3600);
        // Token is active → removal must revert.
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistry.TokenStillActive.selector, address(usdc)));
        reg.removeToken(address(usdc));
        vm.stopPrank();
    }
}
