// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {OracleAggregator} from "../src/oracle/OracleAggregator.sol";

/// @notice Deploys the Phase 3.5 oracle layer on Arc testnet: 7 new V2
/// OracleAggregator instances (one per stablecoin), each wired to an
/// existing primary feed (FEED_*) and an existing P3 secondary feed
/// (P3_SECONDARY_*). Aggregators are deployed with initialOwner set
/// directly to the Governance Safe — no two-step ownership transfer is
/// needed (simpler than P3 Phase A).
///
/// This script does NOT migrate Registry.setOracle — that is handled by
/// P3_5GovernanceActions.s.sol (schedules the Timelock batch) and then
/// ExecuteP3_5Batch.s.sol (executes it after 48h).
///
/// Log lines beginning with "P3_5_AGG_<SYMBOL>:" emit the deployed
/// aggregator addresses. The operator must capture these and export them
/// as P3_5_AGG_<SYMBOL> env vars before running P3_5GovernanceActions.
///
/// Required env: DEPLOYER_PRIVATE_KEY, FEED_USDC, FEED_USDT, FEED_PYUSD,
/// FEED_DAI, FEED_EURC, FEED_TRYC, FEED_BRLC, P3_SECONDARY_USDC,
/// P3_SECONDARY_USDT, P3_SECONDARY_PYUSD, P3_SECONDARY_DAI,
/// P3_SECONDARY_EURC, P3_SECONDARY_TRYC, P3_SECONDARY_BRLC.
contract DeployOraclesP3_5 is Script {
    address constant GOVERNANCE_SAFE = 0x715f669D79Cc72d6685F8724c0B86f7B53d7e624;

    // Per-tier divergence caps (matches P3 per-token mapping):
    //   USD-pegged (USDC/USDT/PYUSD/DAI): 50 bps
    //   EUR (EURC):                       100 bps
    //   soft-FX (TRYC/BRLC):              200 bps
    uint16 constant DIV_BPS_USD = 50;
    uint16 constant DIV_BPS_EUR = 100;
    uint16 constant DIV_BPS_FX = 200;
    uint32 constant MAX_STALE_SECONDS = 3600; // 1 hour

    struct TokenSpec {
        string symbol;
        uint16 divergenceBps;
    }

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        require(deployer.balance >= 0.1 ether, "DeployOraclesP3_5: deployer balance < 0.1 ARC");

        // Read primary feeds from env (FEED_* vars — same vars the keeper uses)
        address[7] memory primaryFeeds = [
            vm.envAddress("FEED_USDC"),
            vm.envAddress("FEED_USDT"),
            vm.envAddress("FEED_PYUSD"),
            vm.envAddress("FEED_DAI"),
            vm.envAddress("FEED_EURC"),
            vm.envAddress("FEED_TRYC"),
            vm.envAddress("FEED_BRLC")
        ];

        // Read secondary feeds from env (P3_SECONDARY_* vars)
        address[7] memory secondaryFeeds = [
            vm.envAddress("P3_SECONDARY_USDC"),
            vm.envAddress("P3_SECONDARY_USDT"),
            vm.envAddress("P3_SECONDARY_PYUSD"),
            vm.envAddress("P3_SECONDARY_DAI"),
            vm.envAddress("P3_SECONDARY_EURC"),
            vm.envAddress("P3_SECONDARY_TRYC"),
            vm.envAddress("P3_SECONDARY_BRLC")
        ];

        TokenSpec[7] memory specs = [
            TokenSpec("USDC", DIV_BPS_USD),
            TokenSpec("USDT", DIV_BPS_USD),
            TokenSpec("PYUSD", DIV_BPS_USD),
            TokenSpec("DAI", DIV_BPS_USD),
            TokenSpec("EURC", DIV_BPS_EUR),
            TokenSpec("TRYC", DIV_BPS_FX),
            TokenSpec("BRLC", DIV_BPS_FX)
        ];

        // Validate all inputs are non-zero before spending gas
        for (uint256 i = 0; i < 7; i++) {
            require(primaryFeeds[i] != address(0), "DeployOraclesP3_5: zero primary feed");
            require(secondaryFeeds[i] != address(0), "DeployOraclesP3_5: zero secondary feed");
        }

        vm.startBroadcast(deployerKey);

        console2.log("=== Deploying P3.5 oracle aggregator layer ===");
        console2.log("Deployer:", deployer);
        console2.log("Governance Safe (initial owner):", GOVERNANCE_SAFE);
        console2.log("MAX_STALE_SECONDS:", MAX_STALE_SECONDS);
        console2.log("");

        for (uint256 i = 0; i < 7; i++) {
            OracleAggregator agg = new OracleAggregator(
                IChainlinkAggregator(primaryFeeds[i]),
                IChainlinkAggregator(secondaryFeeds[i]),
                specs[i].divergenceBps,
                MAX_STALE_SECONDS,
                GOVERNANCE_SAFE // initialOwner — no two-step transfer needed
            );

            // ── N-6: post-deploy constructor verification ──────────────────────
            // Catches off-by-one arg errors (e.g. DIV_BPS_EUR passed where
            // DIV_BPS_USD was intended) that would otherwise surface only at
            // swap time, when they are expensive to discover.
            require(agg.owner() == GOVERNANCE_SAFE, "P3_5: wrong owner");
            require(agg.MAX_STALE_SECONDS() == MAX_STALE_SECONDS, "P3_5: wrong stale");
            require(agg.maxDivergenceBps() == specs[i].divergenceBps, "P3_5: wrong div bps");

            // Emit a parseable log line the operator captures for the next step
            console2.log(string.concat("P3_5_AGG_", specs[i].symbol, ":"), address(agg));
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("All 7 V2 OracleAggregator instances deployed with initialOwner = Governance Safe.");
        console2.log("Export the P3_5_AGG_* addresses above, then run P3_5GovernanceActions.s.sol");
        console2.log("to schedule the Timelock batch that migrates Registry.usdOracle pointers.");
    }
}
