// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ArcFXGateway } from "../../src/ArcFXGateway.sol";
import { MockERC20 } from "../helpers/MockERC20.sol";

contract GatewayHandler is Test {
    ArcFXGateway public immutable gw;
    MockERC20    public immutable usdc;
    MockERC20    public immutable eurc;
    address      public immutable merchant;
    address      public immutable customer;

    uint256 public totalAmountIn;
    uint256 public totalPayoutsOut;
    uint256 public totalFees;
    uint256 public callsAttempted;
    uint256 public callsSucceeded;
    uint256 public createFailures;
    uint256 public payFailures;

    constructor(
        ArcFXGateway _gw,
        MockERC20    _usdc,
        MockERC20    _eurc,
        address      _merchant,
        address      _customer
    ) {
        gw = _gw;
        usdc = _usdc;
        eurc = _eurc;
        merchant = _merchant;
        customer = _customer;
    }

    /// @notice Forge invariant runner calls this with random arguments.
    function createAndPay(uint96 amountOut, bytes32 salt) external {
        callsAttempted++;
        amountOut = uint96(bound(uint256(amountOut), 1_000_000, 1_000 * 1e6));
        bytes32 mid = keccak256(abi.encode(salt, amountOut));

        bytes32 g;
        vm.prank(merchant);
        try gw.createInvoice(mid, address(eurc), amountOut, uint64(block.timestamp + 1 hours)) returns (bytes32 globalId) {
            g = globalId;
        } catch {
            createFailures++;
            return;
        }

        uint256 merchantBefore = usdc.balanceOf(merchant);
        uint256 eurcBefore     = eurc.balanceOf(customer);
        uint256 feesBefore     = gw.protocolFeesAccrued(address(usdc));

        vm.prank(customer);
        try gw.pay(g, type(uint128).max) {
            uint256 paid     = usdc.balanceOf(merchant) - merchantBefore;
            uint256 spent    = eurcBefore - eurc.balanceOf(customer);
            uint256 feeAccr  = gw.protocolFeesAccrued(address(usdc)) - feesBefore;
            totalAmountIn   += spent;
            totalPayoutsOut += paid;
            totalFees       += feeAccr;
            callsSucceeded++;
        } catch {
            payFailures++;
        }
    }
}
