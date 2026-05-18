// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { MockChainlinkFeedV2 } from "../src/testnet/MockChainlinkFeedV2.sol";
import { SafeSigHelpers } from "../test/governance/SafeSigHelpers.sol";

/// @notice Migrates the `writer` role of the 7 P3 secondary MockChainlinkFeedV2
/// feeds from the deployer EOA to the keeper EOA, so the keeper can push prices
/// to the secondary feeds (enabling healthy two-source aggregation).
///
/// The Governance Safe owns the secondary feeds; `setWriter` is `onlyOwner`, so
/// each call is a Safe transaction executed via SafeSigHelpers.
///
/// Required env: DEPLOYER_PRIVATE_KEY (relays the Safe txs, pays gas),
/// KEEPER_ADDRESS (the new writer), P3_SECONDARY_<SYM> x7 (sourced from
/// the DeployOraclesP3.s.sol broadcast output — same vars used by P3 governance scripts).
contract MigrateSecondaryWriters is Script {
    using SafeSigHelpers for Safe;

    string constant MNEMONIC =
        "test test test test test test test test test test test junk";
    Safe constant GOV_SAFE = Safe(payable(0x715f669D79Cc72d6685F8724c0B86f7B53d7e624));

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        require(keeper != address(0), "KEEPER_ADDRESS is zero");

        address[7] memory secondaries = [
            vm.envAddress("P3_SECONDARY_USDC"),
            vm.envAddress("P3_SECONDARY_USDT"),
            vm.envAddress("P3_SECONDARY_PYUSD"),
            vm.envAddress("P3_SECONDARY_DAI"),
            vm.envAddress("P3_SECONDARY_EURC"),
            vm.envAddress("P3_SECONDARY_TRYC"),
            vm.envAddress("P3_SECONDARY_BRLC")
        ];

        uint256[] memory keys3 = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            keys3[i] = vm.deriveKey(MNEMONIC, uint32(i));
        }

        vm.startBroadcast(deployerKey);

        for (uint256 i = 0; i < 7; i++) {
            address feed = secondaries[i];
            require(feed != address(0), "secondary feed address is zero");

            if (MockChainlinkFeedV2(feed).writer() == keeper) {
                console2.log("skip (writer already keeper):", feed);
                continue;
            }

            require(
                GOV_SAFE.execCall(
                    feed,
                    abi.encodeCall(MockChainlinkFeedV2.setWriter, (keeper)),
                    keys3
                ),
                "setWriter Safe exec failed"
            );
            require(MockChainlinkFeedV2(feed).writer() == keeper, "writer not migrated");
            console2.log("setWriter -> keeper:", feed);
        }

        vm.stopBroadcast();
        console2.log("Secondary-feed writer migration complete (keeper):", keeper);
    }
}
