// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { StablecoinRegistry } from "../src/registry/StablecoinRegistry.sol";
import { StablePool }         from "../src/pool/StablePool.sol";
import { IStablePool }        from "../src/pool/IStablePool.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeed }    from "../src/testnet/MockChainlinkFeed.sol";
import { MockERC20 }            from "./helpers/MockERC20.sol";

contract StablePoolTest is Test {
    StablecoinRegistry  reg;
    StablePool          pool;
    MockERC20           usdc;
    MockERC20           eurc;
    MockERC20           dai;       // 18 decimals
    MockChainlinkFeed   usdcFeed;
    MockChainlinkFeed   eurcFeed;
    MockChainlinkFeed   daiFeed;

    address owner    = makeAddr("owner");
    address customer = makeAddr("customer");

    uint16 constant DEFAULT_FEE_BPS = 5;
    uint16 constant TIGHT_DEV_BPS   = 50;
    uint16 constant FX_DEV_BPS      = 150;

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        reg = new StablecoinRegistry(owner);
        pool = new StablePool(address(reg), DEFAULT_FEE_BPS, owner);

        usdc     = new MockERC20("USDC", "USDC", 6);
        eurc     = new MockERC20("EURC", "EURC", 6);
        dai      = new MockERC20("DAI",  "DAI",  18);
        usdcFeed = new MockChainlinkFeed(8, 1.0000e8);
        eurcFeed = new MockChainlinkFeed(8, 1.0863e8);
        daiFeed  = new MockChainlinkFeed(8, 1.0000e8);

        vm.startPrank(owner);
        reg.listToken(address(usdc), 6,  IChainlinkAggregator(address(usdcFeed)), TIGHT_DEV_BPS);
        reg.listToken(address(eurc), 6,  IChainlinkAggregator(address(eurcFeed)), FX_DEV_BPS);
        reg.listToken(address(dai),  18, IChainlinkAggregator(address(daiFeed)),  TIGHT_DEV_BPS);
        vm.stopPrank();
    }

    function _seed(address token, uint256 amount) internal {
        MockERC20(token).mint(owner, amount);
        vm.startPrank(owner);
        IERC20(token).approve(address(pool), amount);
        pool.deposit(token, amount);
        vm.stopPrank();
    }

    // ── deposit / withdraw ───────────────────────────────────────────

    function test_Deposit_PullsTokens_AndUpdatesReserve() public {
        usdc.mint(owner, 1_000e6);
        vm.startPrank(owner);
        usdc.approve(address(pool), 1_000e6);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IStablePool.LiquidityDeposited(address(usdc), 1_000e6, 1_000e6);
        pool.deposit(address(usdc), 1_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(pool)), 1_000e6);
        assertEq(pool.reserves(address(usdc)), 1_000e6);
    }

    function test_Deposit_RevertsIfNotOwner() public {
        usdc.mint(customer, 1_000e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(); // OZ Ownable
        pool.deposit(address(usdc), 1_000e6);
        vm.stopPrank();
    }

    function test_Deposit_RevertsOnInactiveToken() public {
        MockERC20 other = new MockERC20("X", "X", 6);
        other.mint(owner, 1_000e6);
        vm.startPrank(owner);
        other.approve(address(pool), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IStablePool.TokenNotActive.selector, address(other)));
        pool.deposit(address(other), 1_000e6);
        vm.stopPrank();
    }

    function test_Withdraw_TransfersOut_AndUpdatesReserve() public {
        _seed(address(usdc), 1_000e6);
        vm.expectEmit(true, false, false, true, address(pool));
        emit IStablePool.LiquidityWithdrawn(address(usdc), 400e6, 600e6);
        vm.prank(owner);
        pool.withdraw(address(usdc), 400e6, owner);
        assertEq(pool.reserves(address(usdc)), 600e6);
        assertEq(usdc.balanceOf(owner), 400e6);
    }

    function test_Withdraw_RevertsOnInsufficientReserve() public {
        _seed(address(usdc), 100e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablePool.InsufficientLiquidity.selector, address(usdc), 200e6, 100e6));
        pool.withdraw(address(usdc), 200e6, owner);
    }

    // ── pause / unpause ──────────────────────────────────────────────

    function test_Pause_BlocksDeposit_AllowsWithdraw() public {
        _seed(address(usdc), 1_000e6);
        vm.prank(owner);
        pool.pause();

        usdc.mint(owner, 100e6);
        vm.startPrank(owner);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(IStablePool.PoolPaused.selector);
        pool.deposit(address(usdc), 100e6);

        // withdraw still works (unwinding path)
        pool.withdraw(address(usdc), 200e6, owner);
        vm.stopPrank();
        assertEq(pool.reserves(address(usdc)), 800e6);
    }

    function test_Pause_RevertsIfNotOwner() public {
        vm.prank(customer);
        vm.expectRevert();
        pool.pause();
    }

    function test_Unpause_RestoresDeposits() public {
        vm.prank(owner);
        pool.pause();
        vm.prank(owner);
        pool.unpause();
        usdc.mint(owner, 100e6);
        vm.startPrank(owner);
        usdc.approve(address(pool), 100e6);
        pool.deposit(address(usdc), 100e6);
        vm.stopPrank();
        assertEq(pool.reserves(address(usdc)), 100e6);
    }

    // ── fee setter ────────────────────────────────────────────────────

    function test_SetSwapFee_Success() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit IStablePool.SwapFeeUpdated(DEFAULT_FEE_BPS, 30);
        vm.prank(owner);
        pool.setSwapFeeBps(30);
        assertEq(pool.swapFeeBps(), 30);
    }

    function test_SetSwapFee_RevertsAbove50() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablePool.InvalidFeeBps.selector, 51));
        pool.setSwapFeeBps(51);
    }

    // ── quote ─────────────────────────────────────────────────────────

    function test_Quote_USDCtoEURC_AppliesFee() public view {
        // 1.0 USDC -> ? EURC. usdcUsd=1.0000, eurcUsd=1.0863, fee=5bps.
        uint256 q = pool.quote(address(usdc), address(eurc), 1_000_000);
        // gross = 1e6 * 1.0000 / 1.0863 = 920_555 (truncated), then * 9995/10000 = 920_094
        assertApproxEqAbs(q, 920_094, 2);
    }

    function test_Quote_EURCtoUSDC_AppliesFee() public view {
        // 1.0 EURC -> ? USDC. gross = 1e6 * 1.0863 / 1.0000 = 1_086_300
        // net = 1_086_300 * 9_995 / 10_000 = 1_085_756
        uint256 q = pool.quote(address(eurc), address(usdc), 1_000_000);
        assertApproxEqAbs(q, 1_085_756, 2);
    }

    function test_Quote_USDCtoDAI_CrossDecimal_6to18() public view {
        // 1.0 USDC (6dec) -> ? DAI (18dec). Both peg=1.
        // amountOutGross = 1e6 * 1.0e8 / 1.0e8 * 10^(18-6) = 1e18
        // net = 1e18 * 9_995/10_000 = 9.995e17
        uint256 q = pool.quote(address(usdc), address(dai), 1_000_000);
        assertEq(q, 999_500_000_000_000_000); // 0.9995 DAI
    }

    function test_Quote_DAItoUSDC_CrossDecimal_18to6() public view {
        // 1.0 DAI (18dec) -> ? USDC (6dec). Both peg=1.
        // gross = 1e18 * 1e8 / 1e8 / 10^12 = 1e6
        // net   = 1e6 * 9_995/10_000 = 999_500
        uint256 q = pool.quote(address(dai), address(usdc), 1e18);
        assertEq(q, 999_500);
    }

    function test_Quote_RevertsOnInactiveToken() public {
        vm.prank(owner);
        reg.deactivateToken(address(eurc));
        vm.expectRevert(abi.encodeWithSelector(IStablePool.TokenNotActive.selector, address(eurc)));
        pool.quote(address(usdc), address(eurc), 1e6);
    }

    function test_Quote_RevertsOnSameToken() public {
        vm.expectRevert(abi.encodeWithSelector(IStablePool.SameToken.selector, address(usdc)));
        pool.quote(address(usdc), address(usdc), 1e6);
    }

    function test_Quote_RevertsOnZeroAmount() public {
        vm.expectRevert(IStablePool.ZeroAmount.selector);
        pool.quote(address(usdc), address(eurc), 0);
    }

    // ── swap ──────────────────────────────────────────────────────────

    function test_Swap_USDCtoEURC_TransfersAndAccountsCorrectly() public {
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);

        usdc.mint(customer, 1_000e6);
        uint256 expected = pool.quote(address(usdc), address(eurc), 1_000e6);

        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);
        uint256 received = pool.swap(address(usdc), address(eurc), 1_000e6, expected, block.timestamp, customer);
        vm.stopPrank();

        assertEq(received, expected);
        assertEq(eurc.balanceOf(customer), expected);
        assertEq(pool.reserves(address(usdc)), 100_000e6 + 1_000e6);
        // Reserve out is reduced by GROSS (fee retained as protocolFeesAccrued)
        assertEq(eurc.balanceOf(address(pool)), 100_000e6 - expected);

        // Fee accrued in tokenOut units
        assertGt(pool.protocolFeesAccrued(address(eurc)), 0);
    }

    function test_Swap_RevertsOnInsufficientLiquidity() public {
        _seed(address(usdc), 100_000e6);
        // No EURC reserve — swap should revert
        usdc.mint(customer, 1_000e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(); // bound by available reserves[eurc] = 0
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);
        vm.stopPrank();
    }

    function test_Swap_RevertsOnSlippage() public {
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);

        usdc.mint(customer, 1_000e6);
        uint256 quote_ = pool.quote(address(usdc), address(eurc), 1_000e6);

        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IStablePool.InsufficientOutput.selector, quote_, quote_ + 1));
        pool.swap(address(usdc), address(eurc), 1_000e6, quote_ + 1, block.timestamp, customer);
        vm.stopPrank();
    }

    function test_Swap_RevertsOnExpiredDeadline() public {
        _seed(address(usdc), 100e6);
        _seed(address(eurc), 100e6);

        usdc.mint(customer, 10e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 10e6);
        vm.expectRevert(IStablePool.DeadlinePassed.selector);
        pool.swap(address(usdc), address(eurc), 10e6, 0, block.timestamp - 1, customer);
        vm.stopPrank();
    }

    function test_Swap_RevertsWhenPaused() public {
        _seed(address(usdc), 100e6);
        _seed(address(eurc), 100e6);
        vm.prank(owner);
        pool.pause();

        usdc.mint(customer, 10e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 10e6);
        vm.expectRevert(IStablePool.PoolPaused.selector);
        pool.swap(address(usdc), address(eurc), 10e6, 0, block.timestamp, customer);
        vm.stopPrank();
    }

    function test_Swap_TransfersToCustomRecipient() public {
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);

        address merchant = makeAddr("merchant");
        usdc.mint(customer, 1_000e6);
        uint256 expected = pool.quote(address(usdc), address(eurc), 1_000e6);

        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);
        uint256 received = pool.swap(address(usdc), address(eurc), 1_000e6, expected, block.timestamp, merchant);
        vm.stopPrank();

        assertEq(received, expected);
        assertEq(eurc.balanceOf(merchant), expected);
        assertEq(eurc.balanceOf(customer), 0);
    }

    // ── PriceGuard ────────────────────────────────────────────────────

    function test_PriceGuard_FirstSwapPrimesAccepted_NoRevert() public {
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);
        usdc.mint(customer, 1_000e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);
        // First-ever swap on this token primes lastAcceptedPrice; cannot revert on deviation.
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);
        vm.stopPrank();

        assertEq(pool.lastAcceptedPrice(address(usdc)), 1e18);     // 1.0000 USD scaled to 1e18
        assertApproxEqRel(pool.lastAcceptedPrice(address(eurc)), 1.0863e18, 1e15);
    }

    function test_PriceGuard_RevertsOnLargeDeviation_USDC() public {
        // First, prime: usdc=1.0000.
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);
        usdc.mint(customer, 2_000e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 2_000e6);
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);
        vm.stopPrank();

        // Now USDC oracle prints $0.95 — 5% off, way over 50bps.
        usdcFeed.setAnswer(0.95e8);

        vm.startPrank(customer);
        vm.expectRevert(abi.encodeWithSelector(
            IStablePool.PriceDeviation.selector, address(usdc), 0.95e18, 1e18, TIGHT_DEV_BPS
        ));
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);
        vm.stopPrank();
    }

    function test_PriceGuard_AllowsSmallMove_WithinBand() public {
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);
        usdc.mint(customer, 2_000e6);
        vm.prank(customer);
        usdc.approve(address(pool), 2_000e6);
        vm.prank(customer);
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);

        // Bump USDC by 30 bps — within 50bps cap. Owner-only setter; default test sender is owner of feed.
        usdcFeed.setAnswer(1.0030e8);

        vm.prank(customer);
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);

        assertEq(pool.lastAcceptedPrice(address(usdc)), 1.003e18);
    }

    function test_PriceGuard_FXTokenUsesItsBand() public {
        // EURC is configured with FX_DEV_BPS=150. A 1% move is allowed.
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);
        eurc.mint(customer, 2_000e6);
        vm.prank(customer);
        eurc.approve(address(pool), 2_000e6);
        vm.prank(customer);
        pool.swap(address(eurc), address(usdc), 1_000e6, 0, block.timestamp, customer);

        // Move EURC by 1%: 1.0863 -> 1.0972.
        eurcFeed.setAnswer(1.0972e8);

        vm.prank(customer);
        pool.swap(address(eurc), address(usdc), 1_000e6, 0, block.timestamp, customer);
    }
}
