// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { StablecoinRegistry } from "../src/registry/StablecoinRegistry.sol";
import { IStablecoinRegistry } from "../src/registry/IStablecoinRegistry.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeed } from "../src/testnet/MockChainlinkFeed.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

contract StablecoinRegistryTest is Test {
    StablecoinRegistry  reg;
    MockERC20           usdc;
    MockChainlinkFeed   usdcFeed;
    address             owner = makeAddr("owner");
    address             newOwner = makeAddr("newOwner");
    address             stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_700_000_000);
        reg = new StablecoinRegistry(owner);
        usdc = new MockERC20("USDC", "USDC", 6);
        usdcFeed = new MockChainlinkFeed(8, 1.0000e8);
    }

    function test_ListToken_Success() public {
        vm.expectEmit(true, false, false, true, address(reg));
        emit IStablecoinRegistry.TokenListed(address(usdc), 6, address(usdcFeed), 50);
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);

        IStablecoinRegistry.TokenInfo memory info = reg.tokenInfo(address(usdc));
        assertEq(info.decimals, 6);
        assertTrue(info.isActive);
        assertEq(address(info.usdOracle), address(usdcFeed));
        assertEq(info.maxOracleDeviationBps, 50);
        assertEq(reg.tokens(0), address(usdc));
        assertEq(reg.tokensLength(), 1);
        assertTrue(reg.isActive(address(usdc)));
    }

    function test_ListToken_RevertsIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
    }

    function test_ListToken_RevertsOnDuplicate() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.TokenAlreadyListed.selector, address(usdc)));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
    }

    function test_ListToken_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IStablecoinRegistry.ZeroAddress.selector);
        reg.listToken(address(0), 6, IChainlinkAggregator(address(usdcFeed)), 50);
    }

    function test_ListToken_RevertsOnInvalidDecimals() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.InvalidDecimals.selector, 0));
        reg.listToken(address(usdc), 0, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.InvalidDecimals.selector, 30));
        reg.listToken(address(usdc), 30, IChainlinkAggregator(address(usdcFeed)), 50);
    }

    function test_ListToken_RevertsOnTokenDecimalMismatch() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.TokenDecimalMismatch.selector, address(usdc), 18, 6));
        reg.listToken(address(usdc), 18, IChainlinkAggregator(address(usdcFeed)), 50);
    }

    function test_ListToken_RevertsOnInvalidDeviation() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.InvalidDeviation.selector, 0));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.InvalidDeviation.selector, 10_001));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 10_001);
    }

    function test_Ownable2Step_AcceptHandshake() public {
        vm.prank(owner);
        reg.transferOwnership(newOwner);
        // Pending — owner unchanged until accept
        assertEq(reg.owner(), owner);
        assertEq(reg.pendingOwner(), newOwner);
        // newOwner accepts
        vm.prank(newOwner);
        reg.acceptOwnership();
        assertEq(reg.owner(), newOwner);
        assertEq(reg.pendingOwner(), address(0));
    }

    function test_Deactivate_Reactivate_Flow() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);

        vm.expectEmit(true, false, false, true, address(reg));
        emit IStablecoinRegistry.TokenDeactivated(address(usdc));
        vm.prank(owner);
        reg.deactivateToken(address(usdc));
        assertFalse(reg.isActive(address(usdc)));

        vm.expectEmit(true, false, false, true, address(reg));
        emit IStablecoinRegistry.TokenReactivated(address(usdc));
        vm.prank(owner);
        reg.reactivateToken(address(usdc));
        assertTrue(reg.isActive(address(usdc)));
    }

    function test_Deactivate_RevertsOnUnknownToken() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.TokenNotListed.selector, address(usdc)));
        reg.deactivateToken(address(usdc));
    }

    function test_SetOracle_Success() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);

        MockChainlinkFeed newFeed = new MockChainlinkFeed(8, 1.0001e8);
        vm.expectEmit(true, false, false, true, address(reg));
        emit IStablecoinRegistry.OracleUpdated(address(usdc), address(usdcFeed), address(newFeed));
        vm.prank(owner);
        reg.setOracle(address(usdc), IChainlinkAggregator(address(newFeed)));

        assertEq(address(reg.tokenInfo(address(usdc)).usdOracle), address(newFeed));
    }

    function test_SetOracle_RevertsOnZero() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.prank(owner);
        vm.expectRevert(IStablecoinRegistry.ZeroAddress.selector);
        reg.setOracle(address(usdc), IChainlinkAggregator(address(0)));
    }

    function test_SetDeviation_Success() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.expectEmit(true, false, false, true, address(reg));
        emit IStablecoinRegistry.DeviationUpdated(address(usdc), 50, 150);
        vm.prank(owner);
        reg.setDeviation(address(usdc), 150);
        assertEq(reg.tokenInfo(address(usdc)).maxOracleDeviationBps, 150);
    }

    function test_SetDeviation_RevertsOnInvalid() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.InvalidDeviation.selector, 0));
        reg.setDeviation(address(usdc), 0);
    }

    function test_TokensArray_OrderPreserved() public {
        MockERC20 eurc = new MockERC20("EURC", "EURC", 6);
        MockChainlinkFeed eurFeed = new MockChainlinkFeed(8, 1.0863e8);

        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.prank(owner);
        reg.listToken(address(eurc), 6, IChainlinkAggregator(address(eurFeed)), 150);

        assertEq(reg.tokensLength(), 2);
        assertEq(reg.tokens(0), address(usdc));
        assertEq(reg.tokens(1), address(eurc));
    }
}
