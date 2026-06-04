// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {MockChainlinkFeedV2} from "../src/testnet/MockChainlinkFeedV2.sol";
import {OracleAggregator} from "../src/oracle/OracleAggregator.sol";
import {CumulativeDeviationGuard} from "../src/oracle/CumulativeDeviationGuard.sol";

/// @notice Deploys the Phase 3 oracle layer on Arc testnet: 7 secondary
/// MockChainlinkFeedV2 feeds, 7 OracleAggregator instances (one per stablecoin,
/// primary = the existing 2026-05-10 feed, secondary = the newly-deployed feed),
/// and 1 CumulativeDeviationGuard configured for all 7 stables.
///
/// All 15 owned contracts have their ownership transferred (Ownable2Step
/// pending-accept) to the Governance Safe. The script does NOT migrate
/// Registry.setOracle — that is a separate Timelock-routed governance proposal.
///
/// Required env: DEPLOYER_PRIVATE_KEY (broadcasts), ARC_TESTNET_RPC.
contract DeployOraclesP3 is Script {
    address constant GOVERNANCE_SAFE = 0x715f669D79Cc72d6685F8724c0B86f7B53d7e624;
    uint32 constant GUARD_WINDOW_SECONDS = 86_400; // 24 h tumbling window (P3 spec Task C)

    struct TokenSpec {
        string symbol;
        address token;
        address primaryFeed;
        int256 initialPrice;
        uint8 feedDecimals;
        uint16 divergenceBps;
        uint32 cumulativeBps; // for guard config
        // ── H-2: on-chain sanity band for the secondary MockChainlinkFeedV2 ──
        // All four are at the feed's oracle decimals (8). The band is a strict
        // SUPERSET of the keeper's off-chain band in ops/keepalive/multi-feed-push.mjs
        // so a legitimate in-band keeper push can never revert on-chain; the
        // on-chain band is the BACKSTOP, the keeper guards are primary.
        int256 minAnswer; // hard sanity floor (1e8), < keeper band.min
        int256 maxAnswer; // hard sanity ceiling (1e8), > keeper band.max
        uint32 maxJumpBps; // > keeper per-tick maxDevBps so legit ticks never trip
        uint32 minUpdateSeconds; // 0: keeper runs every 30 min; a min-interval risks blocking a legit re-push
    }

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        require(deployer.balance >= 0.5 ether, "DeployOraclesP3: deployer balance < 0.5 ARC");

        TokenSpec[7] memory cfg;
        // Per-tier caps -- divergenceBps / cumulativeBps:
        //   USD-pegged (USDC/USDT/PYUSD/DAI): 50 / 200
        //   EUR (EURC):                       100 / 300
        //   soft-FX (TRYC/BRLC):              200 / 500
        //
        // H-2 on-chain feed bands (last 4 args, all 1e8) are SUPERSETS of the
        // keeper's off-chain bands in ops/keepalive/multi-feed-push.mjs:
        //   USDC  keeper [1.00,1.00] devBps 50  -> on-chain [0.95,1.05] jump 300
        //   USDT  keeper [0.95,1.05] devBps 50  -> on-chain [0.90,1.10] jump 300
        //   PYUSD keeper [0.95,1.05] devBps 50  -> on-chain [0.90,1.10] jump 300
        //   DAI   keeper [0.95,1.05] devBps 50  -> on-chain [0.90,1.10] jump 300
        //   EURC  keeper [1.00,1.30] devBps 150 -> on-chain [0.90,1.40] jump 500
        //   TRYC  keeper [0.01,0.10] devBps 150 -> on-chain [0.005,0.15] jump 500
        //   BRLC  keeper [0.10,0.30] devBps 150 -> on-chain [0.05,0.40] jump 500
        // maxJumpBps >> keeper per-tick devBps so legit ticks never trip;
        // minUpdateSeconds = 0 (keeper runs every 30 min; a min-interval risks
        // blocking a legit re-push). On-chain band = backstop; keeper = primary.
        cfg[0] = TokenSpec(
            "USDC",
            0x3BFa09fF6467639f0981948385bA1018Ac07d22C,
            0x2E6B862E1Ac74328238494B22317262004534B39,
            100_000_000,
            8,
            50,
            200,
            95_000_000, // 0.95
            105_000_000, // 1.05
            300,
            0
        );
        cfg[1] = TokenSpec(
            "USDT",
            0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B,
            0x741af784a1d4C69843A1764099433160088a1c70,
            100_000_000,
            8,
            50,
            200,
            90_000_000, // 0.90
            110_000_000, // 1.10
            300,
            0
        );
        cfg[2] = TokenSpec(
            "PYUSD",
            0xfdB2c86d010698401f0b969348DC58b6659B96a3,
            0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896,
            100_000_000,
            8,
            50,
            200,
            90_000_000, // 0.90
            110_000_000, // 1.10
            300,
            0
        );
        cfg[3] = TokenSpec(
            "DAI",
            0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE,
            0xAAC5a5855deF9414f7330f350c2E00119C2097c8,
            100_000_000,
            8,
            50,
            200,
            90_000_000, // 0.90
            110_000_000, // 1.10
            300,
            0
        );
        cfg[4] = TokenSpec(
            "EURC",
            0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD,
            0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170,
            108_000_000,
            8,
            100,
            300,
            90_000_000, // 0.90
            140_000_000, // 1.40
            500,
            0
        );
        cfg[5] = TokenSpec(
            "TRYC",
            0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61,
            0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C,
            2_900_000,
            8,
            200,
            500,
            500_000, // 0.005
            15_000_000, // 0.15
            500,
            0
        );
        cfg[6] = TokenSpec(
            "BRLC",
            0xa13c0935A98e2c175b31A4054f698819271a8FfC,
            0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d,
            20_000_000,
            8,
            200,
            500,
            5_000_000, // 0.05
            40_000_000, // 0.40
            500,
            0
        );

        vm.startBroadcast(deployerKey);

        console2.log("=== Deploying P3 oracle layer ===");
        console2.log("Deployer:", deployer);
        console2.log("Governance Safe:", GOVERNANCE_SAFE);
        console2.log("");

        // 1. Deploy CumulativeDeviationGuard (initial owner = deployer, transferred below)
        CumulativeDeviationGuard guard = new CumulativeDeviationGuard(deployer);
        console2.log("Guard:", address(guard));

        // 2. Per-token: deploy secondary feed, deploy aggregator, configure guard
        for (uint256 i = 0; i < cfg.length; i++) {
            // H-2 (audit 2026-05-31): finalize the per-token on-chain band. The
            // band is a SUPERSET of the keeper's off-chain band (see cfg above /
            // ops/keepalive/multi-feed-push.mjs) so a legitimate in-band keeper
            // push can never revert on-chain; this is the defense-in-depth
            // BACKSTOP, the keeper's own guards remain primary. minUpdateSeconds=0
            // because the keeper runs every 30 min and a min-interval would risk
            // blocking a legit re-push. Initial writer = deployer; migrated to a
            // SEPARATE secondary keeper later via MigrateSecondaryWriters.s.sol.
            MockChainlinkFeedV2 secondary = new MockChainlinkFeedV2(
                cfg[i].feedDecimals,
                cfg[i].initialPrice,
                deployer,
                deployer,
                cfg[i].minAnswer,
                cfg[i].maxAnswer,
                cfg[i].maxJumpBps,
                cfg[i].minUpdateSeconds
            );

            OracleAggregator agg = new OracleAggregator(
                IChainlinkAggregator(cfg[i].primaryFeed),
                IChainlinkAggregator(address(secondary)),
                cfg[i].divergenceBps,
                3600, // MAX_STALE_SECONDS: 1h for USD-pegged stables (Phase D4 may tune per-tier)
                deployer
            );

            // setConfig is onlyOwner; deployer is still owner here (transfer happens after loop)
            guard.setConfig(cfg[i].token, cfg[i].cumulativeBps, GUARD_WINDOW_SECONDS);

            console2.log(string.concat("  ", cfg[i].symbol, " secondary:"), address(secondary));
            console2.log(string.concat("  ", cfg[i].symbol, " aggregator:"), address(agg));

            // Transfer aggregator ownership to Governance Safe (Ownable2Step pending-accept)
            agg.transferOwnership(GOVERNANCE_SAFE);
            // Transfer secondary feed ownership to Governance Safe (Ownable2Step pending-accept)
            secondary.transferOwnership(GOVERNANCE_SAFE);
        }

        // 3. Transfer guard ownership to Governance Safe (Ownable2Step pending-accept)
        //    setConfig calls above are complete; deployer is still owner until this line
        guard.transferOwnership(GOVERNANCE_SAFE);

        console2.log("");
        console2.log(
            "Ownership of guard + 7 aggregators + 7 secondaries transferred (pending acceptance by Governance Safe)."
        );
        console2.log(
            "NOTE (H-2): secondary feed writer remains the deployer EOA. Run MigrateSecondaryWriters.s.sol so the Governance Safe sets each secondary feed's writer to a SEPARATE KEEPER_SECONDARY key (must differ from the primary keeper); distinct writers keep the two-source divergence check meaningful."
        );

        vm.stopBroadcast();
    }
}
