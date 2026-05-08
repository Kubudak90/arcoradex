// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ArcFXGateway }         from "../src/ArcFXGateway.sol";
import { StablecoinRegistry }   from "../src/registry/StablecoinRegistry.sol";
import { StablePool }           from "../src/pool/StablePool.sol";
import { IStablePool }          from "../src/pool/IStablePool.sol";
import { IStablecoinRegistry }  from "../src/registry/IStablecoinRegistry.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeed }    from "../src/testnet/MockChainlinkFeed.sol";
import { MockERC20 }            from "./helpers/MockERC20.sol";

contract ArcFXGatewayTest is Test {
    StablecoinRegistry  reg;
    StablePool          pool;
    MockERC20           usdc;
    MockERC20           eurc;
    MockERC20           usdt;
    MockERC20           pyusd;
    MockERC20           dai;
    MockERC20           tryc;
    MockERC20           brlc;
    MockChainlinkFeed   usdcFeed;
    MockChainlinkFeed   eurcFeed;
    MockChainlinkFeed   usdtFeed;
    MockChainlinkFeed   pyusdFeed;
    MockChainlinkFeed   daiFeed;
    MockChainlinkFeed   trycFeed;
    MockChainlinkFeed   brlcFeed;
    ArcFXGateway        gw;

    address merchant = makeAddr("merchant");
    address customer = makeAddr("customer");

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        usdc     = new MockERC20("USDC", "USDC", 6);
        eurc     = new MockERC20("EURC", "EURC", 6);
        usdcFeed = new MockChainlinkFeed(8, 1.0000e8);
        eurcFeed = new MockChainlinkFeed(8, 1.0863e8);

        reg  = new StablecoinRegistry(address(this));
        pool = new StablePool(address(reg), 5, address(this));

        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        reg.listToken(address(eurc), 6, IChainlinkAggregator(address(eurcFeed)), 150);

        // Seed pool with 1M of each.
        usdc.mint(address(this), 1_000_000e6);
        eurc.mint(address(this), 1_000_000e6);
        IERC20(address(usdc)).approve(address(pool), 1_000_000e6);
        IERC20(address(eurc)).approve(address(pool), 1_000_000e6);
        pool.deposit(address(usdc), 1_000_000e6);
        pool.deposit(address(eurc), 1_000_000e6);

        // ── v0.7 cross-stable expansion: USDT, PYUSD, DAI, TRYC, BRLC ──
        usdt      = new MockERC20("USDT",  "USDT",  6);
        pyusd     = new MockERC20("PYUSD", "PYUSD", 6);
        dai       = new MockERC20("DAI",   "DAI",   18);
        tryc      = new MockERC20("TRYC",  "TRYC",  6);
        brlc      = new MockERC20("BRLC",  "BRLC",  6);
        usdtFeed  = new MockChainlinkFeed(8, 1.0001e8);
        pyusdFeed = new MockChainlinkFeed(8, 1.0000e8);
        daiFeed   = new MockChainlinkFeed(8, 1.0000e8);
        trycFeed  = new MockChainlinkFeed(8, 0.0291e8);
        brlcFeed  = new MockChainlinkFeed(8, 0.1980e8);

        reg.listToken(address(usdt),  6,  IChainlinkAggregator(address(usdtFeed)),  50);
        reg.listToken(address(pyusd), 6,  IChainlinkAggregator(address(pyusdFeed)), 50);
        reg.listToken(address(dai),   18, IChainlinkAggregator(address(daiFeed)),   50);
        reg.listToken(address(tryc),  6,  IChainlinkAggregator(address(trycFeed)),  150);
        reg.listToken(address(brlc),  6,  IChainlinkAggregator(address(brlcFeed)),  150);

        // Seed reserves sized so each pocket has roughly $1M USD-equivalent
        // depth. TRYC at 0.0291 USD ⇒ ~34M TRYC; BRLC at 0.198 ⇒ ~5M BRLC.
        _seed(address(usdt),  1_000_000e6);
        _seed(address(pyusd), 1_000_000e6);
        _seed(address(dai),   1_000_000e18);
        _seed(address(tryc),  34_000_000e6);
        _seed(address(brlc),  5_000_000e6);

        gw = new ArcFXGateway(
            IStablePool(address(pool)),
            IStablecoinRegistry(address(reg)),
            10,
            address(this)
        );
    }

    // ── Merchant registration ──────────────────────────────────────────

    function test_RegisterMerchant_Success() public {
        vm.prank(merchant);
        gw.registerMerchant(merchant, address(usdc));
        (address payoutAddr, address payoutTok, bool active) = gw.merchants(merchant);
        assertEq(payoutAddr, merchant);
        assertEq(payoutTok, address(usdc));
        assertTrue(active);
    }

    function test_Constructor_RevertsAboveProtocolFeeCap() public {
        vm.expectRevert(abi.encodeWithSelector(ArcFXGateway.InvalidProtocolFeeBps.selector, 101));
        new ArcFXGateway(
            IStablePool(address(pool)),
            IStablecoinRegistry(address(reg)),
            101,
            address(this)
        );
    }

    function test_Constructor_AllowsProtocolFeeAtCap() public {
        ArcFXGateway capped = new ArcFXGateway(
            IStablePool(address(pool)),
            IStablecoinRegistry(address(reg)),
            100,
            address(this)
        );

        assertEq(capped.PROTOCOL_FEE_BPS(), 100);
        assertEq(capped.MAX_PROTOCOL_FEE_BPS(), 100);
    }

    function test_RegisterMerchant_SeparatePayoutAddress() public {
        address payoutWallet = makeAddr("payout");
        vm.prank(merchant);
        gw.registerMerchant(payoutWallet, address(usdc));
        (address payoutAddr, , ) = gw.merchants(merchant);
        assertEq(payoutAddr, payoutWallet);
    }

    function test_RegisterMerchant_RevertsOnDoubleRegistration() public {
        vm.prank(merchant);
        gw.registerMerchant(merchant, address(usdc));
        vm.prank(merchant);
        vm.expectRevert(ArcFXGateway.MerchantAlreadyRegistered.selector);
        gw.registerMerchant(merchant, address(eurc));
    }

    function test_RegisterMerchant_RevertsOnUnsupportedToken() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        vm.prank(merchant);
        vm.expectRevert(ArcFXGateway.InvalidPayoutToken.selector);
        gw.registerMerchant(merchant, address(other));
    }

    function test_RegisterMerchant_RevertsOnZeroPayoutAddress() public {
        vm.prank(merchant);
        vm.expectRevert(ArcFXGateway.InvalidPayoutAddress.selector);
        gw.registerMerchant(address(0), address(usdc));
    }

    function test_RegisterMerchant_EmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(gw));
        emit ArcFXGateway.MerchantRegistered(merchant, merchant, address(usdc));
        vm.prank(merchant);
        gw.registerMerchant(merchant, address(usdc));
    }

    // ── Merchant updates ───────────────────────────────────────────────

    function _registerMerchant() internal {
        vm.prank(merchant);
        gw.registerMerchant(merchant, address(usdc));
    }

    function test_UpdatePayoutAddress_Success() public {
        _registerMerchant();
        address newWallet = makeAddr("new-payout");
        vm.expectEmit(true, false, false, true, address(gw));
        emit ArcFXGateway.MerchantPayoutAddressUpdated(merchant, merchant, newWallet);
        vm.prank(merchant);
        gw.updatePayoutAddress(newWallet);
        (address payoutAddr, , ) = gw.merchants(merchant);
        assertEq(payoutAddr, newWallet);
    }

    function test_UpdatePayoutAddress_RevertsForUnregistered() public {
        vm.prank(merchant);
        vm.expectRevert(ArcFXGateway.NotMerchant.selector);
        gw.updatePayoutAddress(makeAddr("x"));
    }

    function test_UpdatePayoutAddress_RevertsOnZero() public {
        _registerMerchant();
        vm.prank(merchant);
        vm.expectRevert(ArcFXGateway.InvalidPayoutAddress.selector);
        gw.updatePayoutAddress(address(0));
    }

    function test_UpdatePayoutToken_Success() public {
        _registerMerchant();
        vm.expectEmit(true, false, false, true, address(gw));
        emit ArcFXGateway.MerchantPayoutTokenUpdated(merchant, address(usdc), address(eurc));
        vm.prank(merchant);
        gw.updatePayoutToken(address(eurc));
        (, address payoutTok, ) = gw.merchants(merchant);
        assertEq(payoutTok, address(eurc));
    }

    function test_UpdatePayoutToken_RevertsOnUnsupported() public {
        _registerMerchant();
        MockERC20 other = new MockERC20("X", "X", 18);
        vm.prank(merchant);
        vm.expectRevert(ArcFXGateway.InvalidPayoutToken.selector);
        gw.updatePayoutToken(address(other));
    }

    function test_DeactivateMerchant_Success() public {
        _registerMerchant();
        vm.expectEmit(true, false, false, true, address(gw));
        emit ArcFXGateway.MerchantDeactivated(merchant);
        vm.prank(merchant);
        gw.deactivateMerchant();
        (, , bool active) = gw.merchants(merchant);
        assertFalse(active);
    }

    function test_DeactivateMerchant_BlocksNewInvoices() public {
        _registerMerchant();
        vm.prank(merchant);
        gw.deactivateMerchant();
        vm.prank(merchant);
        vm.expectRevert(ArcFXGateway.MerchantInactive.selector);
        gw.createInvoice(bytes32("inv-1"), address(eurc), 1, uint64(block.timestamp + 1 hours));
    }

    // ── Invoice creation ───────────────────────────────────────────────

    function test_CreateInvoice_Success() public {
        _registerMerchant();
        bytes32 mid = bytes32("inv-1");
        vm.prank(merchant);
        bytes32 globalId = gw.createInvoice(mid, address(eurc), 49_990_000, uint64(block.timestamp + 30 minutes));

        bytes32 expected = keccak256(abi.encode(merchant, mid));
        assertEq(globalId, expected);

        (address m, address payIn, address payoutTok, uint256 amt, uint64 exp, ArcFXGateway.InvoiceStatus s, ) =
            gw.invoices(globalId);
        assertEq(m, merchant);
        assertEq(payIn, address(eurc));
        assertEq(payoutTok, address(usdc));
        assertEq(amt, 49_990_000);
        assertEq(exp, uint64(block.timestamp + 30 minutes));
        assertEq(uint8(s), uint8(ArcFXGateway.InvoiceStatus.Created));
    }

    function test_CreateInvoice_RevertsIfNotMerchant() public {
        vm.prank(merchant);
        vm.expectRevert(ArcFXGateway.MerchantInactive.selector);
        gw.createInvoice(bytes32("inv-2"), address(eurc), 1, uint64(block.timestamp + 1 hours));
    }

    function test_CreateInvoice_RevertsOnDuplicateId() public {
        _registerMerchant();
        bytes32 mid = bytes32("inv-3");
        vm.startPrank(merchant);
        bytes32 globalId = gw.createInvoice(mid, address(eurc), 100, uint64(block.timestamp + 1 hours));
        vm.expectRevert(abi.encodeWithSelector(ArcFXGateway.InvoiceAlreadyExists.selector, globalId));
        gw.createInvoice(mid, address(eurc), 100, uint64(block.timestamp + 1 hours));
        vm.stopPrank();
    }

    /// @notice Different merchants using the same merchantInvoiceId must not collide.
    function test_CreateInvoice_NamespaceIsolation() public {
        _registerMerchant();

        address merchant2 = makeAddr("merchant2");
        vm.prank(merchant2);
        gw.registerMerchant(merchant2, address(usdc));

        bytes32 sharedMid = bytes32("ORDER-1");

        vm.prank(merchant);
        bytes32 g1 = gw.createInvoice(sharedMid, address(eurc), 100, uint64(block.timestamp + 1 hours));

        vm.prank(merchant2);
        bytes32 g2 = gw.createInvoice(sharedMid, address(eurc), 200, uint64(block.timestamp + 1 hours));

        assertTrue(g1 != g2);

        (address m1, , , uint256 a1, , , ) = gw.invoices(g1);
        (address m2, , , uint256 a2, , , ) = gw.invoices(g2);
        assertEq(m1, merchant);
        assertEq(m2, merchant2);
        assertEq(a1, 100);
        assertEq(a2, 200);
    }

    function test_CreateInvoice_SameTokenAllowed() public {
        _registerMerchant(); // payout USDC
        // Same-token invoice (payIn USDC, payout USDC) is now valid.
        vm.prank(merchant);
        bytes32 globalId = gw.createInvoice(bytes32("same"), address(usdc), 100, uint64(block.timestamp + 1 hours));
        (, address payIn, address payoutTok, , , , ) = gw.invoices(globalId);
        assertEq(payIn, address(usdc));
        assertEq(payoutTok, address(usdc));
    }

    function test_CreateInvoice_RevertsOnUnknownPayIn() public {
        _registerMerchant();
        MockERC20 unknown = new MockERC20("Z", "Z", 6);
        vm.prank(merchant);
        vm.expectRevert(ArcFXGateway.UnsupportedPair.selector);
        gw.createInvoice(bytes32("unk"), address(unknown), 100, uint64(block.timestamp + 1 hours));
    }

    function test_CreateInvoice_LocksPayoutTokenAtCreation() public {
        _registerMerchant(); // USDC
        vm.prank(merchant);
        bytes32 globalId = gw.createInvoice(bytes32("lock"), address(eurc), 1_000_000, uint64(block.timestamp + 1 hours));

        // Merchant flips payout token after invoice exists.
        vm.prank(merchant);
        gw.updatePayoutToken(address(eurc));

        // Invoice still locked to USDC.
        (, , address payoutTok, , , , ) = gw.invoices(globalId);
        assertEq(payoutTok, address(usdc));
    }

    function test_CreateInvoice_EmitsEvent() public {
        _registerMerchant();
        bytes32 mid = bytes32("inv-5");
        bytes32 expectedGlobal = keccak256(abi.encode(merchant, mid));
        vm.expectEmit(true, true, true, true, address(gw));
        emit ArcFXGateway.InvoiceCreated(
            expectedGlobal, merchant, mid, address(eurc), address(usdc), 50_000_000, uint64(block.timestamp + 1 hours)
        );
        vm.prank(merchant);
        gw.createInvoice(mid, address(eurc), 50_000_000, uint64(block.timestamp + 1 hours));
    }

    // ── pay() ──────────────────────────────────────────────────────────

    /// @dev Pool is seeded in setUp; this just funds the customer with EURC and approves the gateway.
    function _fundPoolAndCustomer() internal {
        eurc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        eurc.approve(address(gw), type(uint256).max);
    }

    function test_Pay_HappyPath() public {
        _registerMerchant();
        _fundPoolAndCustomer();

        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("happy"), address(eurc), 49_990_000, uint64(block.timestamp + 1 hours));

        uint256 merchantBefore = usdc.balanceOf(merchant);
        vm.prank(customer);
        gw.pay(g, 60_000_000);

        (, , , , , ArcFXGateway.InvoiceStatus s, address paidBy) = gw.invoices(g);
        assertEq(uint8(s), uint8(ArcFXGateway.InvoiceStatus.Paid));
        assertEq(paidBy, customer);

        // received >= amountOut; gateway fee is taken from `received`, not amountOut.
        // Read the actual stored payment to verify the math.
        (uint256 storedPayout, uint256 storedFee) = gw.payments(g);
        uint256 received = storedPayout + storedFee;
        assertGe(received, 49_990_000, "received must cover amountOut");
        assertEq(storedFee, (received * 10) / 10_000, "fee = received * 10 bps");
        assertEq(storedPayout, received - storedFee);
        assertEq(usdc.balanceOf(merchant) - merchantBefore, storedPayout);
        assertEq(gw.protocolFeesAccrued(address(usdc)), storedFee);
    }

    /// @notice Same-token payments take the no-swap branch: customer pays exactly amountOut.
    function test_Pay_SameTokenDirect() public {
        _registerMerchant(); // payout USDC
        usdc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        usdc.approve(address(gw), type(uint256).max);

        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("direct"), address(usdc), 50_000_000, uint64(block.timestamp + 1 hours));

        uint256 merchantBefore = usdc.balanceOf(merchant);
        uint256 customerBefore = usdc.balanceOf(customer);

        vm.prank(customer);
        gw.pay(g, 50_000_000);

        uint256 fee = (50_000_000 * 10) / 10_000;
        assertEq(customerBefore - usdc.balanceOf(customer), 50_000_000, "customer pays exact amount");
        assertEq(usdc.balanceOf(merchant) - merchantBefore, 50_000_000 - fee, "merchant gets net");
        assertEq(gw.protocolFeesAccrued(address(usdc)), fee);
    }

    function test_Pay_SameTokenDirect_EmitsEqualGrossAndAmountIn() public {
        _registerMerchant();
        usdc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        usdc.approve(address(gw), type(uint256).max);

        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("e"), address(usdc), 100_000_000, uint64(block.timestamp + 1 hours));

        uint256 fee    = (100_000_000 * 10) / 10_000;
        uint256 payout = 100_000_000 - fee;
        vm.expectEmit(true, true, false, true, address(gw));
        emit ArcFXGateway.InvoicePaid(g, customer, 100_000_000, 100_000_000, payout, fee);
        vm.prank(customer);
        gw.pay(g, 100_000_000);
    }

    function test_Pay_RevertsOnExpired() public {
        _registerMerchant(); _fundPoolAndCustomer();
        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("exp"), address(eurc), 1_000_000, uint64(block.timestamp + 60));
        vm.warp(block.timestamp + 120);
        vm.prank(customer);
        vm.expectRevert(abi.encodeWithSelector(ArcFXGateway.InvoiceExpired.selector, g));
        gw.pay(g, 2_000_000);
    }

    function test_Pay_RevertsOnReplay() public {
        _registerMerchant(); _fundPoolAndCustomer();
        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("rep"), address(eurc), 1_000_000, uint64(block.timestamp + 1 hours));
        vm.prank(customer); gw.pay(g, 2_000_000);
        vm.prank(customer);
        vm.expectRevert(abi.encodeWithSelector(ArcFXGateway.InvoiceAlreadyPaid.selector, g));
        gw.pay(g, 2_000_000);
    }

    function test_Pay_RevertsOnNotFound() public {
        vm.prank(customer);
        vm.expectRevert(abi.encodeWithSelector(ArcFXGateway.InvoiceNotFound.selector, bytes32(0)));
        gw.pay(bytes32(0), 1);
    }

    function test_Pay_RevertsOnSlippageTooTight() public {
        _registerMerchant(); _fundPoolAndCustomer();
        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("slip"), address(eurc), 1_000_000, uint64(block.timestamp + 1 hours));
        vm.prank(customer);
        vm.expectRevert();
        gw.pay(g, 500_000);
    }

    /// @notice Oracle deviation guard now lives in StablePool (per-token PriceGuard).
    /// We prime lastAcceptedPrice with one successful swap, then push EURC's oracle
    /// outside its 150bps deviation cap and verify the next pay() reverts.
    function test_Pay_RevertsOnOracleDeviation() public {
        _registerMerchant(); _fundPoolAndCustomer();

        // Prime: one successful pay so StablePool records lastAcceptedPrice for both legs.
        vm.prank(merchant);
        bytes32 prime = gw.createInvoice(bytes32("prime"), address(eurc), 1_000_000, uint64(block.timestamp + 1 hours));
        vm.prank(customer);
        gw.pay(prime, 2_000_000);

        // Now push EURC oracle wildly out of band (1.0863 -> 0.5000, ~54% drop, ≫ 150bps).
        eurcFeed.setAnswer(0.5e8);

        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("dev"), address(eurc), 1_000_000, uint64(block.timestamp + 1 hours));
        eurc.mint(customer, 100_000 * 1e6);
        vm.prank(customer);
        vm.expectRevert();
        gw.pay(g, type(uint128).max);
    }

    /// @notice Pay routes to the merchant's CURRENT payoutAddress, even if changed after invoice creation.
    function test_Pay_UsesCurrentPayoutAddress() public {
        _registerMerchant(); _fundPoolAndCustomer();
        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("addr"), address(eurc), 1_000_000, uint64(block.timestamp + 1 hours));

        address newWallet = makeAddr("rotated");
        vm.prank(merchant);
        gw.updatePayoutAddress(newWallet);

        vm.prank(customer);
        gw.pay(g, 2_000_000);

        assertGt(usdc.balanceOf(newWallet), 0, "new wallet got payout");
        assertEq(usdc.balanceOf(merchant), 0, "old wallet got nothing");
    }

    /// @notice Pay uses the payoutToken LOCKED at invoice creation, ignoring later updates.
    function test_Pay_UsesLockedPayoutToken() public {
        _registerMerchant(); // USDC
        _fundPoolAndCustomer();

        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("tok"), address(eurc), 1_000_000, uint64(block.timestamp + 1 hours));

        // Flip payout token after invoice exists.
        vm.prank(merchant);
        gw.updatePayoutToken(address(eurc));

        uint256 merchantUsdcBefore = usdc.balanceOf(merchant);
        uint256 merchantEurcBefore = eurc.balanceOf(merchant);

        vm.prank(customer);
        gw.pay(g, 2_000_000);

        // Invoice locked to USDC, so merchant receives USDC, not EURC.
        assertGt(usdc.balanceOf(merchant) - merchantUsdcBefore, 0, "merchant got USDC");
        assertEq(eurc.balanceOf(merchant), merchantEurcBefore, "merchant got no EURC");
    }

    function test_Pay_USDCInEURCOut() public {
        vm.prank(merchant);
        gw.registerMerchant(merchant, address(eurc));

        // Pool already seeded in setUp; just fund the customer in USDC.
        usdc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        usdc.approve(address(gw), type(uint256).max);

        // amountOut sized to avoid the iterator's plateau (fee-rounding can cause
        // duplicate quote outputs that consume an extra iterator step).
        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("usdc-in"), address(usdc), 23_456_789, uint64(block.timestamp + 1 hours));

        uint256 merchantBefore = eurc.balanceOf(merchant);
        vm.prank(customer);
        gw.pay(g, 60_000_000);

        (, , , , , ArcFXGateway.InvoiceStatus s, ) = gw.invoices(g);
        assertEq(uint8(s), uint8(ArcFXGateway.InvoiceStatus.Paid));
        assertGt(eurc.balanceOf(merchant) - merchantBefore, 0);
    }

    // ── withdrawFees ───────────────────────────────────────────────────

    function test_WithdrawFees_OwnerOnly() public {
        _registerMerchant(); _fundPoolAndCustomer();
        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("f"), address(eurc), 1_000_000, uint64(block.timestamp + 1 hours));
        vm.prank(customer); gw.pay(g, 2_000_000);

        uint256 accrued = gw.protocolFeesAccrued(address(usdc));
        assertGt(accrued, 0);

        address treasury = makeAddr("treasury");
        gw.withdrawFees(address(usdc), treasury);
        assertEq(usdc.balanceOf(treasury), accrued);
        assertEq(gw.protocolFeesAccrued(address(usdc)), 0);
    }

    function test_WithdrawFees_RevertsForNonOwner() public {
        vm.prank(customer);
        vm.expectRevert();
        gw.withdrawFees(address(usdc), customer);
    }

    // ── delegate authorization ─────────────────────────────────────────

    function test_AuthorizeDelegate_Success() public {
        _registerMerchant();
        address delegate = makeAddr("delegate");
        vm.expectEmit(true, true, false, true, address(gw));
        emit ArcFXGateway.DelegateAuthorized(merchant, delegate, type(uint64).max);
        vm.prank(merchant);
        gw.authorizeDelegate(delegate, type(uint64).max);
        assertEq(gw.delegateAuthorizations(merchant, delegate), type(uint64).max);
    }

    function test_AuthorizeDelegate_RevertsForNonMerchant() public {
        address delegate = makeAddr("delegate");
        vm.prank(merchant);
        vm.expectRevert(ArcFXGateway.NotMerchant.selector);
        gw.authorizeDelegate(delegate, type(uint64).max);
    }

    function test_RevokeDelegate_Success() public {
        _registerMerchant();
        address delegate = makeAddr("delegate");
        vm.startPrank(merchant);
        gw.authorizeDelegate(delegate, type(uint64).max);
        gw.revokeDelegate(delegate);
        vm.stopPrank();
        assertEq(gw.delegateAuthorizations(merchant, delegate), 0);
    }

    function test_CreateInvoiceFor_Success() public {
        _registerMerchant();
        address delegate = makeAddr("delegate");
        vm.prank(merchant);
        gw.authorizeDelegate(delegate, type(uint64).max);

        bytes32 mid = bytes32("auth-1");
        vm.prank(delegate);
        bytes32 g = gw.createInvoiceFor(merchant, mid, address(eurc), 49_990_000, uint64(block.timestamp + 30 minutes));

        (address m, address payIn, , uint256 amt, , ArcFXGateway.InvoiceStatus s, ) = gw.invoices(g);
        assertEq(m, merchant);
        assertEq(payIn, address(eurc));
        assertEq(amt, 49_990_000);
        assertEq(uint8(s), uint8(ArcFXGateway.InvoiceStatus.Created));
    }

    function test_CreateInvoiceFor_RevertsIfNotAuthorized() public {
        _registerMerchant();
        address delegate = makeAddr("delegate");
        vm.prank(delegate);
        vm.expectRevert(ArcFXGateway.DelegateNotAuthorized.selector);
        gw.createInvoiceFor(merchant, bytes32("a"), address(eurc), 1, uint64(block.timestamp + 1 hours));
    }

    function test_CreateInvoiceFor_RevertsIfDelegateExpired() public {
        _registerMerchant();
        address delegate = makeAddr("delegate");
        vm.prank(merchant);
        gw.authorizeDelegate(delegate, uint64(block.timestamp + 1 minutes));

        vm.warp(block.timestamp + 5 minutes);
        vm.prank(delegate);
        vm.expectRevert(ArcFXGateway.DelegateNotAuthorized.selector);
        gw.createInvoiceFor(merchant, bytes32("a"), address(eurc), 1, uint64(block.timestamp + 1 hours));
    }

    // ── refundInvoice() ────────────────────────────────────────────────

    function test_Refund_HappyPath_SameToken() public {
        _registerMerchant(); // payout USDC
        usdc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        usdc.approve(address(gw), type(uint256).max);

        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("rf-st"), address(usdc), 50_000_000, uint64(block.timestamp + 1 hours));

        vm.prank(customer);
        gw.pay(g, 50_000_000);

        uint256 fee    = (50_000_000 * 10) / 10_000;
        uint256 payout = 50_000_000 - fee;

        // Merchant approves the gateway to pull `payout` for the refund.
        vm.prank(merchant);
        usdc.approve(address(gw), payout);

        uint256 customerBefore = usdc.balanceOf(customer);
        uint256 merchantBefore = usdc.balanceOf(merchant);
        uint256 accruedBefore  = gw.protocolFeesAccrued(address(usdc));

        vm.expectEmit(true, true, true, true, address(gw));
        emit ArcFXGateway.InvoiceRefunded(g, customer, address(usdc), payout, fee);
        vm.prank(merchant);
        gw.refundInvoice(g);

        // Status flipped to Refunded.
        (, , , , , ArcFXGateway.InvoiceStatus s, ) = gw.invoices(g);
        assertEq(uint8(s), uint8(ArcFXGateway.InvoiceStatus.Refunded));

        // Customer received the full payout amount back in payoutToken.
        assertEq(usdc.balanceOf(customer) - customerBefore, payout, "customer refunded payout");
        // Merchant pays out `payout`, gets back `fee` from accrued. Net change: -payout + fee = -(payout - fee).
        assertEq(int256(usdc.balanceOf(merchant)) - int256(merchantBefore), -int256(payout) + int256(fee), "merchant net change");
        // Protocol fee bucket drained.
        assertEq(gw.protocolFeesAccrued(address(usdc)), accruedBefore - fee, "fee removed from accrued");
        // payments mapping cleared.
        (uint256 mp, uint256 f) = gw.payments(g);
        assertEq(mp, 0); assertEq(f, 0);
    }

    function test_Refund_HappyPath_SwapBranch() public {
        _registerMerchant(); _fundPoolAndCustomer();

        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("rf-sw"), address(eurc), 49_990_000, uint64(block.timestamp + 1 hours));

        vm.prank(customer);
        gw.pay(g, 60_000_000);

        // Lookup the actual amounts the gateway recorded.
        (uint256 storedPayout, uint256 storedFee) = gw.payments(g);
        assertGt(storedPayout, 0);
        assertGt(storedFee, 0);

        vm.prank(merchant);
        usdc.approve(address(gw), storedPayout);

        uint256 customerUsdcBefore = usdc.balanceOf(customer);
        vm.prank(merchant);
        gw.refundInvoice(g);

        (, , , , , ArcFXGateway.InvoiceStatus s, ) = gw.invoices(g);
        assertEq(uint8(s), uint8(ArcFXGateway.InvoiceStatus.Refunded));
        // Refund delivered in payoutToken (USDC), not the original payIn (EURC).
        assertEq(usdc.balanceOf(customer) - customerUsdcBefore, storedPayout);
    }

    function test_Refund_OwnerCanCall() public {
        _registerMerchant();
        usdc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        usdc.approve(address(gw), type(uint256).max);

        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("rf-own"), address(usdc), 10_000_000, uint64(block.timestamp + 1 hours));
        vm.prank(customer);
        gw.pay(g, 10_000_000);

        (uint256 storedPayout, ) = gw.payments(g);
        vm.prank(merchant);
        usdc.approve(address(gw), storedPayout);

        // Owner is `address(this)` (set in setUp); owner triggers refund on merchant's behalf.
        gw.refundInvoice(g);
        (, , , , , ArcFXGateway.InvoiceStatus s, ) = gw.invoices(g);
        assertEq(uint8(s), uint8(ArcFXGateway.InvoiceStatus.Refunded));
    }

    function test_Refund_RevertsIfNotMerchant() public {
        _registerMerchant();
        usdc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        usdc.approve(address(gw), type(uint256).max);
        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("rf-bad"), address(usdc), 10_000_000, uint64(block.timestamp + 1 hours));
        vm.prank(customer);
        gw.pay(g, 10_000_000);

        address stranger = makeAddr("stranger");
        vm.expectRevert(ArcFXGateway.NotMerchant.selector);
        vm.prank(stranger);
        gw.refundInvoice(g);
    }

    function test_Refund_RevertsIfNotPaid() public {
        _registerMerchant();

        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("rf-cr"), address(usdc), 10_000_000, uint64(block.timestamp + 1 hours));

        vm.expectRevert(abi.encodeWithSelector(ArcFXGateway.InvoiceNotRefundable.selector, g));
        vm.prank(merchant);
        gw.refundInvoice(g);
    }

    function test_Refund_RevertsOnDoubleRefund() public {
        _registerMerchant();
        usdc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        usdc.approve(address(gw), type(uint256).max);
        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("rf-dbl"), address(usdc), 10_000_000, uint64(block.timestamp + 1 hours));
        vm.prank(customer);
        gw.pay(g, 10_000_000);

        (uint256 storedPayout, ) = gw.payments(g);
        vm.prank(merchant);
        usdc.approve(address(gw), storedPayout);
        vm.prank(merchant);
        gw.refundInvoice(g);

        vm.expectRevert(abi.encodeWithSelector(ArcFXGateway.InvoiceNotRefundable.selector, g));
        vm.prank(merchant);
        gw.refundInvoice(g);
    }

    function test_Refund_RevertsIfFeesAlreadyWithdrawn() public {
        _registerMerchant();
        usdc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        usdc.approve(address(gw), type(uint256).max);
        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("rf-w"), address(usdc), 10_000_000, uint64(block.timestamp + 1 hours));
        vm.prank(customer);
        gw.pay(g, 10_000_000);

        // Owner pulls all accrued fees out before the merchant tries to refund.
        gw.withdrawFees(address(usdc), address(this));
        assertEq(gw.protocolFeesAccrued(address(usdc)), 0);

        (uint256 storedPayout, uint256 storedFee) = gw.payments(g);
        vm.prank(merchant);
        usdc.approve(address(gw), storedPayout);

        vm.expectRevert(abi.encodeWithSelector(ArcFXGateway.InsufficientFeesForRefund.selector, storedFee, 0));
        vm.prank(merchant);
        gw.refundInvoice(g);
    }

    function test_Refund_RevertsWithoutMerchantApproval() public {
        _registerMerchant();
        usdc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        usdc.approve(address(gw), type(uint256).max);
        vm.prank(merchant);
        bytes32 g = gw.createInvoice(bytes32("rf-app"), address(usdc), 10_000_000, uint64(block.timestamp + 1 hours));
        vm.prank(customer);
        gw.pay(g, 10_000_000);

        // Merchant deliberately did NOT approve the gateway. SafeERC20 reverts on the transferFrom.
        vm.expectRevert();
        vm.prank(merchant);
        gw.refundInvoice(g);
    }

    /// @notice Regression: when a pool's quote falls 1 wei short of the gateway's
    /// linear inverse extrapolation, `_estimateAmountIn` walks forward 1 wei at a
    /// time so pay() still clears. Uses a tiny IStablePool stub that implements
    /// just `quote` + `swap` and returns `linear - 1` for non-probe inputs.
    function test_Pay_RecoversFromOneWeiPoolShortfall() public {
        // Build a stub pool that returns a clean probe rate but is 1 wei short
        // for any non-probe quote. EURC->USDC rate ≈ 1.085_866 USDC per EURC.
        ShortByOneStablePool shortPool = new ShortByOneStablePool(
            usdc, eurc, 1_085_866
        );

        // New gateway pointing at the stub. Same registry; the gateway only needs
        // `tokenInfo` for decimals + `isActive` for token validation.
        gw = new ArcFXGateway(
            IStablePool(address(shortPool)),
            IStablecoinRegistry(address(reg)),
            10,
            address(this)
        );

        // Fund the stub's USDC reserve so its swap can pay out.
        usdc.mint(address(shortPool), 10_000 * 1e6);
        eurc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        eurc.approve(address(gw), type(uint256).max);

        _registerMerchant();

        vm.prank(merchant);
        bytes32 g = gw.createInvoice(
            bytes32("shortfall"), address(eurc), 1_000_000, uint64(block.timestamp + 1 hours)
        );

        // Without the iterator this reverts because the stub returns 1 wei less
        // than `amountOut` for the linear-inverse input.
        vm.prank(customer);
        gw.pay(g, 2_000_000);

        (, , , , , ArcFXGateway.InvoiceStatus s, address paidBy) = gw.invoices(g);
        assertEq(uint8(s), uint8(ArcFXGateway.InvoiceStatus.Paid));
        assertEq(paidBy, customer);
    }

    // ── v0.7 cross-stable end-to-end pay flows ─────────────────────────

    /// @dev Mints, approves, and deposits `amount` of `token` from the test
    /// contract into the pool. Used by setUp to seed initial reserves.
    function _seed(address token, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(address(pool), amount);
        pool.deposit(token, amount);
    }

    /// @dev Drives a full pay flow: ensures the merchant is registered with
    /// `payoutToken`, mints generously to the customer, creates an invoice
    /// for `amountOut`, and pays it. Returns the global invoice id.
    function _payFlow(address payIn, address payoutToken, uint256 amountOut)
        internal
        returns (bytes32 globalId)
    {
        // Register or re-target the merchant's payout token.
        (, address curPayoutToken, bool active) = gw.merchants(merchant);
        if (!active) {
            vm.prank(merchant);
            gw.registerMerchant(merchant, payoutToken);
        } else if (curPayoutToken != payoutToken) {
            vm.prank(merchant);
            gw.updatePayoutToken(payoutToken);
        }

        bytes32 mInvId = keccak256(abi.encodePacked("inv-", payIn, payoutToken, block.timestamp));
        vm.prank(merchant);
        globalId = gw.createInvoice(mInvId, payIn, amountOut, uint64(block.timestamp + 1 hours));

        // Mint enough payIn for any reasonable quote and approve the gateway.
        MockERC20(payIn).mint(customer, 10_000_000 * 10 ** MockERC20(payIn).decimals());
        vm.startPrank(customer);
        IERC20(payIn).approve(address(gw), type(uint256).max);
        gw.pay(globalId, type(uint256).max);
        vm.stopPrank();
    }

    function test_Pay_USDTtoUSDC_NewPath() public {
        bytes32 id = _payFlow(address(usdt), address(usdc), 100e6);
        (, , , , , ArcFXGateway.InvoiceStatus status, ) = gw.invoices(id);
        assertEq(uint256(status), uint256(ArcFXGateway.InvoiceStatus.Paid));
        // 100 USDC requested, 10bps gateway fee ⇒ ~99.9 USDC to merchant.
        assertGt(usdc.balanceOf(merchant), 99e6);
    }

    function test_Pay_PYUSDtoDAI_CrossDecimal() public {
        bytes32 id = _payFlow(address(pyusd), address(dai), 100e18);
        (, , , , , ArcFXGateway.InvoiceStatus status, ) = gw.invoices(id);
        assertEq(uint256(status), uint256(ArcFXGateway.InvoiceStatus.Paid));
        // PYUSD 6dec → DAI 18dec, both ~$1: ~99.9 DAI after 10bps fee.
        assertGt(dai.balanceOf(merchant), 99e18);
    }

    function test_Pay_DAItoTRYC_CrossDecimalAndFX() public {
        // Payout ~3,448 TRYC ≈ $100 USD at 0.0291 USD/TRY.
        bytes32 id = _payFlow(address(dai), address(tryc), 3_448e6);
        (, , , , , ArcFXGateway.InvoiceStatus status, ) = gw.invoices(id);
        assertEq(uint256(status), uint256(ArcFXGateway.InvoiceStatus.Paid));
        assertGe(tryc.balanceOf(merchant), 3_400e6);
    }

    function test_Pay_BRLCtoEURC_BothFX() public {
        // Payout 100 EURC (~$108.6 USD) ⇒ ~548 BRLC pulled (108.6 / 0.198).
        bytes32 id = _payFlow(address(brlc), address(eurc), 100e6);
        (, , , , , ArcFXGateway.InvoiceStatus status, ) = gw.invoices(id);
        assertEq(uint256(status), uint256(ArcFXGateway.InvoiceStatus.Paid));
        assertGe(eurc.balanceOf(merchant), 99e6);
    }

    function test_Pay_USDCtoUSDC_SameToken_Unchanged() public {
        bytes32 id = _payFlow(address(usdc), address(usdc), 100e6);
        (, , , , , ArcFXGateway.InvoiceStatus status, ) = gw.invoices(id);
        assertEq(uint256(status), uint256(ArcFXGateway.InvoiceStatus.Paid));
        // Same-token: no pool fee, only gateway 10bps ⇒ exactly 99.9 USDC.
        assertEq(usdc.balanceOf(merchant), 99_900_000);
    }
}

/// @dev Minimal IStablePool stub used only by the shortfall regression test
/// in `ArcFXGatewayTest`. Mirrors the linearity of `ShortByOnePool`: the probe
/// quote (1 token unit) returns the configured rate, but every non-probe quote
/// returns `linear - 1` to force `_estimateAmountIn`'s 1-wei walker.
contract ShortByOneStablePool is IStablePool {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    IERC20 public immutable EURC;
    uint256 public probeRateNum1to0_perMicro; // EURC->USDC rate, scaled per 1e6 of EURC

    constructor(IERC20 usdc_, IERC20 eurc_, uint256 probeRateNum) {
        USDC = usdc_;
        EURC = eurc_;
        probeRateNum1to0_perMicro = probeRateNum;
    }

    function _quoteEurcToUsdc(uint256 amountIn) internal view returns (uint256) {
        if (amountIn == 1e6) return probeRateNum1to0_perMicro;
        uint256 linear = (amountIn * probeRateNum1to0_perMicro) / 1e6;
        return linear == 0 ? 0 : linear - 1;
    }

    function _quoteUsdcToEurc(uint256 amountIn) internal view returns (uint256) {
        if (amountIn == 1e6) return (1e6 * 1e6) / probeRateNum1to0_perMicro;
        uint256 linear = (amountIn * 1e6) / probeRateNum1to0_perMicro;
        return linear == 0 ? 0 : linear - 1;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (uint256)
    {
        if (tokenIn == address(EURC) && tokenOut == address(USDC)) return _quoteEurcToUsdc(amountIn);
        if (tokenIn == address(USDC) && tokenOut == address(EURC)) return _quoteUsdcToEurc(amountIn);
        revert SameToken(tokenIn);
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 /*deadline*/,
        address recipient
    ) external returns (uint256 amountOut) {
        if (tokenIn == address(EURC) && tokenOut == address(USDC)) {
            amountOut = _quoteEurcToUsdc(amountIn);
        } else if (tokenIn == address(USDC) && tokenOut == address(EURC)) {
            amountOut = _quoteUsdcToEurc(amountIn);
        } else {
            revert SameToken(tokenIn);
        }
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
    }

    // Unused getters — return zero/false to satisfy the IStablePool surface.
    function reserves(address) external pure returns (uint256) { return 0; }
    function protocolFeesAccrued(address) external pure returns (uint256) { return 0; }
    function swapFeeBps() external pure returns (uint16) { return 0; }
    function paused() external pure returns (bool) { return false; }
    function deposit(address, uint256) external {}
    function withdraw(address, uint256, address) external {}
    function withdrawProtocolFees(address, uint256, address) external {}
    function syncAcceptedPrice(address) external pure returns (uint256) { return 0; }
    function setSwapFeeBps(uint16) external {}
    function pause() external {}
    function unpause() external {}
}
