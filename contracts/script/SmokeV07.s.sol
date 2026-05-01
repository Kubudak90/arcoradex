// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 }           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ArcFXGateway }   from "../src/ArcFXGateway.sol";
import { MintableERC20 }  from "../src/testnet/MintableERC20.sol";

/// @title SmokeV07
/// @notice Runs the 7 canonical pay flows against an already-deployed v0.7
/// stack on Arc testnet. The deployer wallet plays both merchant and
/// customer (single-wallet smoke). Asserts each invoice transitions to Paid
/// and the merchant's payoutToken balance increases.
/// @dev Required env: DEPLOYER_PRIVATE_KEY, GATEWAY_ADDR, plus 7 token
/// addresses (USDC_ADDR, USDT_ADDR, PYUSD_ADDR, DAI_ADDR, EURC_ADDR,
/// TRYC_ADDR, BRLC_ADDR).
contract SmokeV07 is Script {
    struct Flow {
        address payIn;
        address payoutToken;
        uint256 payInMintAmount;
        uint256 payoutAmount;
        bytes32 invoiceId;
    }

    function run() external {
        uint256 pk    = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address gwAdr = vm.envAddress("GATEWAY_ADDR");
        address actor = vm.addr(pk);

        ArcFXGateway gw = ArcFXGateway(gwAdr);

        address usdc  = vm.envAddress("USDC_ADDR");
        address usdt  = vm.envAddress("USDT_ADDR");
        address pyusd = vm.envAddress("PYUSD_ADDR");
        address dai   = vm.envAddress("DAI_ADDR");
        address eurc  = vm.envAddress("EURC_ADDR");
        address tryc  = vm.envAddress("TRYC_ADDR");
        address brlc  = vm.envAddress("BRLC_ADDR");

        Flow[7] memory flows = [
            // 1. Same-token: pay 100 USDC, get 99.9 USDC.
            Flow(usdc,  usdc, 110e6,        100e6,        bytes32("smoke-1-usdc-usdc")),
            // 2. USDC → EURC: pay enough USDC to receive 50 EURC ≈ $54.3 → ~55 USDC.
            Flow(usdc,  eurc, 60e6,         50e6,         bytes32("smoke-2-usdc-eurc")),
            // 3. EURC → USDC: pay enough EURC to receive 50 USDC ≈ $50 → ~46 EURC.
            Flow(eurc,  usdc, 50e6,         50e6,         bytes32("smoke-3-eurc-usdc")),
            // 4. USDT → USDC: ~1:1.
            Flow(usdt,  usdc, 110e6,        100e6,        bytes32("smoke-4-usdt-usdc")),
            // 5. PYUSD → DAI cross-decimal: ~1:1.
            Flow(pyusd, dai,  110e6,        100e18,       bytes32("smoke-5-pyusd-dai")),
            // 6. DAI → TRYC: $100 → ~3,448 TRYC at 0.0291.
            Flow(dai,   tryc, 110e18,       3_448e6,      bytes32("smoke-6-dai-tryc")),
            // 7. BRLC → EURC: 100 EURC ≈ $108.6 → ~550 BRLC at 0.198.
            Flow(brlc,  eurc, 600e6,        100e6,        bytes32("smoke-7-brlc-eurc"))
        ];

        vm.startBroadcast(pk);

        // One-time register if needed (first payout = USDC).
        (, , bool active) = gw.merchants(actor);
        if (!active) {
            gw.registerMerchant(actor, usdc);
        }

        for (uint256 i = 0; i < flows.length; i++) {
            _runFlow(gw, actor, flows[i]);
        }

        vm.stopBroadcast();

        for (uint256 i = 0; i < flows.length; i++) {
            bytes32 globalId = keccak256(abi.encode(actor, flows[i].invoiceId));
            (, , , , , ArcFXGateway.InvoiceStatus s, ) = gw.invoices(globalId);
            console2.log("Flow", i + 1, uint256(s) == 2 ? "PAID" : "FAILED");
            console2.logBytes32(globalId);
        }
    }

    function _runFlow(ArcFXGateway gw, address actor, Flow memory f) internal {
        (, address curPayout, ) = gw.merchants(actor);
        if (curPayout != f.payoutToken) {
            gw.updatePayoutToken(f.payoutToken);
        }

        MintableERC20(f.payIn).mint(actor, f.payInMintAmount);
        IERC20(f.payIn).approve(address(gw), f.payInMintAmount);

        gw.createInvoice(f.invoiceId, f.payIn, f.payoutAmount, uint64(block.timestamp + 1 hours));
        bytes32 globalId = keccak256(abi.encode(actor, f.invoiceId));
        gw.pay(globalId, f.payInMintAmount);
    }
}
