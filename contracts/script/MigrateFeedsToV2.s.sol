// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {ArcoraDexPool} from "../src/ArcoraDexPool.sol";
import {MockChainlinkFeedV2} from "../src/testnet/MockChainlinkFeedV2.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";

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
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeperEOA = vm.envAddress("KEEPER_EOA");
        require(keeperEOA != address(0), "keeper EOA is zero");
        address deployer = vm.addr(pk);

        ArcoraDexRegistry reg = ArcoraDexRegistry(vm.envAddress("REGISTRY_ADDR"));
        ArcoraDexPool pool = ArcoraDexPool(vm.envAddress("POOL_ADDR"));

        uint256 navBefore = pool.totalReservesUSD();
        console2.log("NAV before:", navBefore);

        vm.startBroadcast(pk);
        uint256 n = reg.tokensLength();
        for (uint256 i = 0; i < n; i++) {
            address t = reg.tokens(i);
            if (!reg.isActive(t)) continue;
            _migrateOne(reg, t, keeperEOA, deployer);
        }
        vm.stopBroadcast();

        uint256 navAfter = pool.totalReservesUSD();
        console2.log("NAV after :", navAfter);
        uint256 navDiff = navAfter > navBefore ? navAfter - navBefore : navBefore - navAfter;
        require(navDiff <= 1, "NAV invariant broken");
    }

    function _migrateOne(ArcoraDexRegistry reg, address token, address keeperEOA, address deployer) internal {
        IChainlinkAggregator oldOracle = reg.tokenInfo(token).usdOracle;
        (, int256 currentAnswer,,,) = oldOracle.latestRoundData();
        require(currentAnswer > 0, "old oracle answer is zero");
        uint8 oracleDec = oldOracle.decimals();

        MockChainlinkFeedV2 newFeed = new MockChainlinkFeedV2(oracleDec, currentAnswer, keeperEOA, deployer);

        reg.setOracle(token, IChainlinkAggregator(address(newFeed)));

        console2.log("Migrated token:", token);
        console2.log("  old oracle:", address(oldOracle));
        console2.log("  new oracle:", address(newFeed));
        console2.log("  answer    :", uint256(currentAnswer));
        console2.log("  writer    :", keeperEOA);

        require(newFeed.writer() == keeperEOA, "writer != keeper");
        require(newFeed.owner() == deployer, "owner != deployer");
        require(address(reg.tokenInfo(token).usdOracle) == address(newFeed), "registry not updated");
    }
}
