// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeedV2 }  from "../src/testnet/MockChainlinkFeedV2.sol";
import { OracleAggregator }     from "../src/oracle/OracleAggregator.sol";
import { CumulativeDeviationGuard } from "../src/oracle/CumulativeDeviationGuard.sol";

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
    address constant GOVERNANCE_SAFE        = 0x715f669D79Cc72d6685F8724c0B86f7B53d7e624;
    uint32  constant GUARD_WINDOW_SECONDS   = 86_400; // 24 h tumbling window (P3 spec Task C)

    struct TokenSpec {
        string  symbol;
        address token;
        address primaryFeed;
        int256  initialPrice;
        uint8   feedDecimals;
        uint16  divergenceBps;
        uint32  cumulativeBps; // for guard config
    }

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        require(deployer.balance >= 0.5 ether, "DeployOraclesP3: deployer balance < 0.5 ARC");

        TokenSpec[7] memory cfg;
        // Per-tier caps -- divergenceBps / cumulativeBps:
        //   USD-pegged (USDC/USDT/PYUSD/DAI): 50 / 200
        //   EUR (EURC):                       100 / 300
        //   soft-FX (TRYC/BRLC):              200 / 500
        cfg[0] = TokenSpec("USDC",  0x3BFa09fF6467639f0981948385bA1018Ac07d22C, 0x2E6B862E1Ac74328238494B22317262004534B39,  100_000_000, 8,  50, 200);
        cfg[1] = TokenSpec("USDT",  0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B, 0x741af784a1d4C69843A1764099433160088a1c70,  100_000_000, 8,  50, 200);
        cfg[2] = TokenSpec("PYUSD", 0xfdB2c86d010698401f0b969348DC58b6659B96a3, 0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896,  100_000_000, 8,  50, 200);
        cfg[3] = TokenSpec("DAI",   0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE, 0xAAC5a5855deF9414f7330f350c2E00119C2097c8,  100_000_000, 8,  50, 200);
        cfg[4] = TokenSpec("EURC",  0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD, 0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170,  108_000_000, 8, 100, 300);
        cfg[5] = TokenSpec("TRYC",  0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61, 0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C,    2_900_000, 8, 200, 500);
        cfg[6] = TokenSpec("BRLC",  0xa13c0935A98e2c175b31A4054f698819271a8FfC, 0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d,   20_000_000, 8, 200, 500);

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
            MockChainlinkFeedV2 secondary = new MockChainlinkFeedV2(
                cfg[i].feedDecimals,
                cfg[i].initialPrice,
                deployer,
                deployer
            );

            OracleAggregator agg = new OracleAggregator(
                IChainlinkAggregator(cfg[i].primaryFeed),
                IChainlinkAggregator(address(secondary)),
                cfg[i].divergenceBps,
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
        console2.log("Ownership of guard + 7 aggregators + 7 secondaries transferred (pending acceptance by Governance Safe).");
        console2.log("NOTE: secondary feed writer remains the deployer EOA; the Governance Safe must call setWriter on each secondary feed if a separate keeper is expected to push secondary prices.");

        vm.stopBroadcast();
    }
}
