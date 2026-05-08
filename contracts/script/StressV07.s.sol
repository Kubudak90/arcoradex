// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 }           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ArcFXGateway }        from "../src/ArcFXGateway.sol";
import { StablePool }          from "../src/pool/StablePool.sol";
import { MintableERC20 }       from "../src/testnet/MintableERC20.sol";

/// @title StressV07
/// @notice Volume / stress harness against the live v0.7 stack.
/// Pre-mints + pre-approves a fat balance for every active stable, then
/// drives N pseudo-random cross-stable pay flows. Pay-in tokens, payout
/// tokens, and USD-equivalent amounts are all derived from a single
/// keccak chain seeded by env var SEED so re-runs are deterministic.
/// @dev Required env: DEPLOYER_PRIVATE_KEY, GATEWAY_ADDR, POOL_ADDR,
/// USDC_ADDR/USDT_ADDR/PYUSD_ADDR/DAI_ADDR/EURC_ADDR/TRYC_ADDR/BRLC_ADDR.
/// Optional: SEED (default block.timestamp), N_FLOWS (default 25),
/// MIN_USD_E2 / MAX_USD_E2 (default $10..$500, scaled 1e2).
contract StressV07 is Script {
    struct Tok {
        address addr;
        uint8   decimals;
        uint256 priceMicroUsd;     // USD price × 1e6 (e.g. USDC=1_000_000)
        string  symbol;
    }

    uint256 public createFails;
    uint256 public payFails;

    function run() external {
        uint256 pk    = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address gwAdr = vm.envAddress("GATEWAY_ADDR");
        address actor = vm.addr(pk);

        uint256 nFlows  = vm.envOr("N_FLOWS", uint256(25));
        uint256 minE2   = vm.envOr("MIN_USD_E2", uint256(1_000));
        uint256 maxE2   = vm.envOr("MAX_USD_E2", uint256(50_000));
        uint256 seed    = vm.envOr("SEED", block.timestamp);

        ArcFXGateway gw = ArcFXGateway(gwAdr);

        Tok[7] memory toks = [
            Tok(vm.envAddress("USDC_ADDR"),  6,  1_000_000, "USDC"),
            Tok(vm.envAddress("USDT_ADDR"),  6,  1_000_100, "USDT"),
            Tok(vm.envAddress("PYUSD_ADDR"), 6,  1_000_000, "PYUSD"),
            Tok(vm.envAddress("DAI_ADDR"),   18, 1_000_000, "DAI"),
            Tok(vm.envAddress("EURC_ADDR"),  6,  1_086_300, "EURC"),
            Tok(vm.envAddress("TRYC_ADDR"),  6,     29_100, "TRYC"),
            Tok(vm.envAddress("BRLC_ADDR"),  6,    198_000, "BRLC")
        ];

        vm.startBroadcast(pk);

        // Bulk pre-mint a generous payIn float for every token so the
        // pay loop only spends gas on registry-level merchant updates +
        // invoice + pay calls. 50K USD-equivalent per token.
        for (uint256 i = 0; i < 7; i++) {
            uint256 minted = (50_000 * 10 ** toks[i].decimals * 1_000_000) / toks[i].priceMicroUsd;
            MintableERC20(toks[i].addr).mint(actor, minted);
            IERC20(toks[i].addr).approve(address(gw), type(uint256).max);
        }

        // Make sure merchant is registered (any prior payout is fine).
        (, , bool active) = gw.merchants(actor);
        if (!active) gw.registerMerchant(actor, toks[0].addr);

        for (uint256 k = 0; k < nFlows; k++) {
            seed = uint256(keccak256(abi.encode(seed, k)));
            _runOne(gw, actor, toks, seed, k, minE2, maxE2);
        }

        vm.stopBroadcast();

        if (createFails != 0 || payFails != 0) {
            console2.log("stress failures: create=", createFails, " pay=", payFails);
            revert("StressV07: flow failures");
        }
    }

    function _runOne(
        ArcFXGateway gw,
        address actor,
        Tok[7] memory toks,
        uint256 seed,
        uint256 k,
        uint256 minE2,
        uint256 maxE2
    ) internal {
        uint256 inIdx  = seed % 7;
        uint256 outIdx = uint256(keccak256(abi.encode(seed, "out"))) % 6;
        if (outIdx >= inIdx) outIdx += 1;

        uint256 usdE2 = minE2 + (uint256(keccak256(abi.encode(seed, "amt"))) % (maxE2 - minE2 + 1));
        Tok memory outTok = toks[outIdx];
        uint256 amountOut = (usdE2 * (10 ** outTok.decimals) * 1e4) / outTok.priceMicroUsd;
        if (amountOut == 0) amountOut = 1;

        (, address curPayout, ) = gw.merchants(actor);
        if (curPayout != outTok.addr) {
            gw.updatePayoutToken(outTok.addr);
        }

        bytes32 mInvId = keccak256(abi.encode("stress", seed, k));
        try gw.createInvoice(mInvId, toks[inIdx].addr, amountOut, uint64(block.timestamp + 1 hours)) returns (bytes32) {
            bytes32 globalId = keccak256(abi.encode(actor, mInvId));
            try gw.pay(globalId, type(uint256).max) {
                console2.log("ok", k, inIdx * 10 + outIdx);
            } catch {
                console2.log("PAY-FAIL", k, inIdx * 10 + outIdx);
                payFails++;
            }
        } catch {
            console2.log("CREATE-FAIL", k, inIdx * 10 + outIdx);
            createFails++;
        }
    }
}
