// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";

/// @notice For each active token in the registry, transfer MintableERC20
/// ownership from the deployer to FAUCET_EOA. After this runs, the deployer
/// can no longer mint; the faucet EOA is the sole minter.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY  — broadcasts (must be current token owner)
///   REGISTRY_ADDR         — ArcoraDexRegistry (token list source)
///   FAUCET_EOA            — address of the new faucet EOA
contract TransferTokenOwnershipToFaucet is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address registry = vm.envAddress("REGISTRY_ADDR");
        address faucetEOA = vm.envAddress("FAUCET_EOA");
        address deployer = vm.addr(pk);

        ArcoraDexRegistry reg = ArcoraDexRegistry(registry);
        uint256 n = reg.tokensLength();

        vm.startBroadcast(pk);

        for (uint256 i = 0; i < n; i++) {
            address t = reg.tokens(i);
            if (!reg.isActive(t)) continue;

            MintableERC20 token = MintableERC20(t);
            require(token.owner() == deployer, "not current owner of token");

            token.transferOwnership(faucetEOA);
            require(token.owner() == faucetEOA, "transferOwnership did not land");

            console2.log("Token ownership transferred:", t);
            console2.log("  from:", deployer);
            console2.log("  to  :", faucetEOA);
        }

        vm.stopBroadcast();
    }
}
