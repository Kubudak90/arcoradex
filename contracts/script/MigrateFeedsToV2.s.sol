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

    // ── H-2: canonical ArcoraDEX token addresses (2026-05-06 deploy) ──
    // Used to resolve each token's on-chain feed band. Mirrors the addresses in
    // DeployOraclesP3.s.sol / P3BatchBuilder.sol.
    address constant USDC = 0x3BFa09fF6467639f0981948385bA1018Ac07d22C;
    address constant USDT = 0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B;
    address constant PYUSD = 0xfdB2c86d010698401f0b969348DC58b6659B96a3;
    address constant DAI = 0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE;
    address constant EURC = 0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD;
    address constant TRYC = 0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61;
    address constant BRLC = 0xa13c0935A98e2c175b31A4054f698819271a8FfC;

    /// @dev H-2: per-token on-chain sanity band for the PRIMARY MockChainlinkFeedV2,
    /// scaled to the feed's oracle decimals. Each band is a SUPERSET of the
    /// keeper's off-chain band in ops/keepalive/multi-feed-push.mjs so a
    /// legitimate in-band keeper push can never revert on-chain (on-chain band =
    /// backstop; keeper guards = primary). maxJumpBps >> keeper per-tick devBps
    /// (50/150) so legit single-tick pushes never trip; minUpdateSeconds = 0
    /// because the keeper runs every 30 min and a min-interval would risk
    /// blocking a legit re-push. Reverts on an unknown token rather than falling
    /// back to permissive bounds — a new token must get an explicit band here.
    function _bandFor(address token, uint8 dec)
        internal
        pure
        returns (int256 minAnswer, int256 maxAnswer, uint32 maxJumpBps, uint32 minUpdateSeconds)
    {
        int256 one = int256(10 ** uint256(dec)); // 1.0 at the feed's decimals
        minUpdateSeconds = 0;
        // USD-pegged: keeper [0.95,1.05] (USDC peg-locked at 1.00), devBps 50.
        if (token == USDC) {
            // USDC: on-chain [0.95, 1.05], jump 300 bps
            return (one * 95 / 100, one * 105 / 100, 300, 0);
        } else if (token == USDT || token == PYUSD || token == DAI) {
            // on-chain [0.90, 1.10], jump 300 bps
            return (one * 90 / 100, one * 110 / 100, 300, 0);
        } else if (token == EURC) {
            // keeper [1.02,1.20] devBps 150 -> on-chain [0.90, 1.40], jump 500 bps
            return (one * 90 / 100, one * 140 / 100, 500, 0);
        } else if (token == TRYC) {
            // keeper [0.020,0.040] devBps 150 -> on-chain [0.005, 0.15], jump 500 bps
            return (one * 5 / 1000, one * 15 / 100, 500, 0);
        } else if (token == BRLC) {
            // keeper [0.15,0.22] devBps 150 -> on-chain [0.05, 0.40], jump 500 bps
            return (one * 5 / 100, one * 40 / 100, 500, 0);
        }
        revert("MigrateFeedsToV2: no band configured for token (H-2)");
    }

    function _migrateOne(ArcoraDexRegistry reg, address token, address keeperEOA, address deployer) internal {
        IChainlinkAggregator oldOracle = reg.tokenInfo(token).usdOracle;
        (, int256 currentAnswer,,,) = oldOracle.latestRoundData();
        require(currentAnswer > 0, "old oracle answer is zero");
        uint8 oracleDec = oldOracle.decimals();

        // H-2 (audit 2026-05-31): finalize the per-token on-chain band (superset
        // of the keeper's off-chain band; see _bandFor). Defense-in-depth
        // backstop — the keeper's own guards remain primary.
        (int256 minAnswer, int256 maxAnswer, uint32 maxJumpBps, uint32 minUpdateSeconds) = _bandFor(token, oracleDec);
        MockChainlinkFeedV2 newFeed = new MockChainlinkFeedV2(
            oracleDec, currentAnswer, keeperEOA, deployer, minAnswer, maxAnswer, maxJumpBps, minUpdateSeconds
        );

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
