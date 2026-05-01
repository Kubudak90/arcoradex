// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 }           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { StablecoinRegistry }   from "../src/registry/StablecoinRegistry.sol";
import { StablePool }           from "../src/pool/StablePool.sol";
import { MintableERC20 }        from "../src/testnet/MintableERC20.sol";
import { MockChainlinkFeed }    from "../src/testnet/MockChainlinkFeed.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";

/// @title CompleteV07
/// @notice Resumes a partial DeployV07 broadcast against the already-live
/// registry/pool. Reuses TRYC token+feed addresses if already deployed
/// (TRYC_ADDR/TRYC_FEED env), otherwise deploys fresh. Always full flow
/// for BRLC.
/// @dev Required env: DEPLOYER_PRIVATE_KEY, REGISTRY_ADDR, POOL_ADDR.
/// Optional: TRYC_ADDR, TRYC_FEED.
contract CompleteV07 is Script {
    function run()
        external
        returns (
            address tryc,
            address trycFeed,
            address brlc,
            address brlcFeed
        )
    {
        uint256 pk      = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address regAddr = vm.envAddress("REGISTRY_ADDR");
        address poolAddr = vm.envAddress("POOL_ADDR");
        address owner   = vm.addr(pk);

        // Reuse TRYC if env-supplied (e.g. orphaned from a prior partial run).
        address trycExisting = vm.envOr("TRYC_ADDR", address(0));
        address trycFeedExisting = vm.envOr("TRYC_FEED", address(0));

        StablecoinRegistry reg = StablecoinRegistry(regAddr);
        StablePool pool        = StablePool(poolAddr);

        vm.startBroadcast(pk);

        // ── TRYC ──
        MintableERC20 trycT;
        MockChainlinkFeed trycF;
        if (trycExisting != address(0) && trycFeedExisting != address(0)) {
            trycT = MintableERC20(trycExisting);
            trycF = MockChainlinkFeed(trycFeedExisting);
        } else {
            trycT = new MintableERC20("Lira Coin", "TRYC", 6, owner);
            trycF = new MockChainlinkFeed(8, 0.0291e8);
        }
        if (!reg.isActive(address(trycT))) {
            reg.listToken(address(trycT), 6, IChainlinkAggregator(address(trycF)), 150);
        }
        if (pool.reserves(address(trycT)) == 0) {
            // Only top-up if a prior partial run didn't already mint enough.
            uint256 bal = trycT.balanceOf(owner);
            if (bal < 34_000_000e6) {
                trycT.mint(owner, 34_000_000e6 - bal);
            }
            IERC20(address(trycT)).approve(address(pool), 34_000_000e6);
            pool.deposit(address(trycT), 34_000_000e6);
        }

        // ── BRLC ──
        MintableERC20 brlcT = new MintableERC20("Real Coin", "BRLC", 6, owner);
        MockChainlinkFeed brlcF = new MockChainlinkFeed(8, 0.1980e8);
        reg.listToken(address(brlcT), 6, IChainlinkAggregator(address(brlcF)), 150);
        brlcT.mint(owner, 5_050_000e6);
        IERC20(address(brlcT)).approve(address(pool), 5_050_000e6);
        pool.deposit(address(brlcT), 5_050_000e6);

        vm.stopBroadcast();

        tryc = address(trycT);
        trycFeed = address(trycF);
        brlc = address(brlcT);
        brlcFeed = address(brlcF);
    }
}
