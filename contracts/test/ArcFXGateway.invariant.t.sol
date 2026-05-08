// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ArcFXGateway }         from "../src/ArcFXGateway.sol";
import { StablecoinRegistry }   from "../src/registry/StablecoinRegistry.sol";
import { StablePool }           from "../src/pool/StablePool.sol";
import { IStablePool }          from "../src/pool/IStablePool.sol";
import { IStablecoinRegistry }  from "../src/registry/IStablecoinRegistry.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeed }    from "../src/testnet/MockChainlinkFeed.sol";
import { MockERC20 }            from "./helpers/MockERC20.sol";
import { GatewayHandler }       from "./handlers/GatewayHandler.sol";

/// @notice Invariant suite — standalone setup, does not inherit unit tests.
contract ArcFXGatewayInvariantTest is Test {
    StablecoinRegistry  reg;
    StablePool          pool;
    MockERC20           usdc;
    MockERC20           eurc;
    MockChainlinkFeed   usdcFeed;
    MockChainlinkFeed   eurcFeed;
    ArcFXGateway        gw;

    address merchant = makeAddr("merchant");
    address customer = makeAddr("customer");

    GatewayHandler handler;

    function setUp() public {
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

        gw = new ArcFXGateway(
            IStablePool(address(pool)),
            IStablecoinRegistry(address(reg)),
            10,
            address(this)
        );

        // Register merchant (USDC payout, payoutAddress = merchant for simplicity).
        vm.prank(merchant);
        gw.registerMerchant(merchant, address(usdc));

        // Fund customer.
        eurc.mint(customer, 1_000 * 1e6);
        vm.prank(customer);
        eurc.approve(address(gw), type(uint256).max);

        // Top up customer further for the invariant runner to use.
        eurc.mint(customer, 1_000_000 * 1e6);

        handler = new GatewayHandler(gw, usdc, eurc, merchant, customer);

        // Limit the invariant fuzzer to handler functions only.
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.createAndPay.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @notice Gateway should hold only its accrued fees, never any other tokens.
    function invariant_NoStuckFunds() public view {
        assertEq(usdc.balanceOf(address(gw)), gw.protocolFeesAccrued(address(usdc)));
        assertEq(eurc.balanceOf(address(gw)), gw.protocolFeesAccrued(address(eurc)));
    }

    /// @notice Sum of merchant balance + accrued fees equals total payouts tracked by handler.
    function invariant_PayoutPlusFeeEqualsTotalOut() public view {
        uint256 merchantRecvNow = usdc.balanceOf(merchant);
        uint256 feesHeld        = gw.protocolFeesAccrued(address(usdc));
        // handler.totalPayoutsOut tracks net-of-fee received by merchant;
        // handler.totalFees tracks fee portion.  Together they equal total USDC moved.
        assertEq(merchantRecvNow + feesHeld, handler.totalPayoutsOut() + handler.totalFees());
    }

    function invariant_PayFlowLiveness() public view {
        if (handler.callsAttempted() == 0) return;
        assertGt(handler.callsSucceeded(), 0);
        assertEq(handler.payFailures(), 0);
    }
}
