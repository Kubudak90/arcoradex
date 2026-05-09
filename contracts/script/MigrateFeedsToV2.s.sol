// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 }   from "forge-std/Script.sol";
import { ArcoraDexRegistry }  from "../src/ArcoraDexRegistry.sol";
import { ArcoraDexPool }      from "../src/ArcoraDexPool.sol";
import { MockChainlinkFeedV2 } from "../src/testnet/MockChainlinkFeedV2.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";

/// @notice Deploys MockChainlinkFeedV2 instances for every active token in the
/// registry, copies the current oracle's latestAnswer as initialAnswer, sets
/// the writer to KEEPER_EOA + the owner to DEPLOYER (= broadcaster), then
/// re-points the registry via setOracle. Asserts NAV invariant pre/post.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY  — broadcasts (must be current registry/pool owner)
///   REGISTRY_ADDR         — ArcoraDexRegistry
///   POOL_ADDR             — ArcoraDexPool (for NAV invariant check)
///   KEEPER_EOA            — address (NOT key) of the new keeper EOA
contract MigrateFeedsToV2 is Script {
    function run() external {
        uint256 pk        = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address registry  = vm.envAddress("REGISTRY_ADDR");
        address poolAddr  = vm.envAddress("POOL_ADDR");
        address keeperEOA = vm.envAddress("KEEPER_EOA");
        address deployer  = vm.addr(pk);

        ArcoraDexRegistry reg = ArcoraDexRegistry(registry);
        ArcoraDexPool     pool = ArcoraDexPool(poolAddr);

        uint256 navBefore = pool.totalReservesUSD();
        console2.log("NAV before:", navBefore);

        uint256 n = reg.tokensLength();

        // Snapshot active token + current oracle list (read-only, no broadcast yet)
        address[] memory tokensActive = new address[](n);
        IChainlinkAggregator[] memory oraclesOld = new IChainlinkAggregator[](n);
        uint8[]   memory decsList   = new uint8[](n);
        uint256 activeCount = 0;
        for (uint256 i = 0; i < n; i++) {
            address t = reg.tokens(i);
            if (!reg.isActive(t)) continue;
            tokensActive[activeCount] = t;
            oraclesOld[activeCount]  = reg.tokenInfo(t).usdOracle;
            decsList[activeCount]    = reg.tokenInfo(t).decimals;
            activeCount++;
        }

        vm.startBroadcast(pk);

        for (uint256 i = 0; i < activeCount; i++) {
            address t = tokensActive[i];
            (, int256 currentAnswer, , , ) = oraclesOld[i].latestRoundData();
            uint8 oracleDec = oraclesOld[i].decimals();

            // initialAnswer at the same oracle decimals as v1 (8 here for MockChainlinkFeed)
            MockChainlinkFeedV2 newFeed = new MockChainlinkFeedV2(
                oracleDec,
                currentAnswer,
                keeperEOA,
                deployer
            );

            reg.setOracle(t, IChainlinkAggregator(address(newFeed)));

            console2.log("Migrated token:", t);
            console2.log("  old oracle:", address(oraclesOld[i]));
            console2.log("  new oracle:", address(newFeed));
            console2.log("  answer    :", uint256(currentAnswer));

            // Invariants per token
            require(MockChainlinkFeedV2(address(newFeed)).writer() == keeperEOA, "writer != keeper");
            require(MockChainlinkFeedV2(address(newFeed)).owner()  == deployer, "owner != deployer");
            require(address(reg.tokenInfo(t).usdOracle) == address(newFeed), "registry not updated");
        }

        vm.stopBroadcast();

        uint256 navAfter = pool.totalReservesUSD();
        console2.log("NAV after :", navAfter);

        // ±1 wei tolerance for rounding (should be exactly equal in practice — answers copied 1:1)
        uint256 navDiff = navAfter > navBefore ? navAfter - navBefore : navBefore - navAfter;
        require(navDiff <= 1, "NAV invariant broken");
    }
}
