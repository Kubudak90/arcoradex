// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";

/// @title DeployTokensFresh — fresh testnet stablecoin deploy (Branch C redeploy)
/// @notice Deploys 7 FRESH `MintableERC20` testnet stablecoins on Arc testnet
/// (chainId 5042002) and mints each token's bootstrap `targetSeed` to the
/// deployer. Needed because the OLD tokens' mint authority is lost, so the
/// public-testnet (re)deploy orchestrator (`DeployPublicTestnet.s.sol`) can no
/// longer seed liquidity from them. The deployer is set as the initial token
/// owner so it can mint the bootstrap seed in the same broadcast.
///
/// CAPTURE: each fresh address is emitted as a `TOKEN_<SYM>= <addr>` line so the
/// operator can export them into env. `DeployPublicTestnet` then reads those
/// `TOKEN_<SYM>` keys via `resolvedTokens()` to point the redeploy at the fresh
/// tokens, leaving the audited per-token economic config (decimals, oracle bands,
/// seeds, divergence caps) intact.
///
/// The token name/symbol/decimals MIRROR the originals (see DeployArcoraDex.s.sol)
/// so the fresh tokens are drop-in equivalents. The `targetSeed` per token is the
/// token-native bootstrap amount used by `DeployPublicTestnet._bootstrap`.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY — broadcasts; becomes the initial owner of each token
///                          (so it can mint the bootstrap seed)
contract DeployTokensFresh is Script {
    struct TokenSpec {
        string name;
        string symbol;
        uint8 decimals;
        uint256 targetSeed; // token-native bootstrap amount minted to the deployer
    }

    /// @dev The 7 fresh tokens, in `DeployPublicTestnet._cfg()` order
    /// [USDC, USDT, PYUSD, DAI, EURC, TRYC, BRLC]. Names/symbols/decimals mirror
    /// DeployArcoraDex.s.sol; seeds match `DeployPublicTestnet._cfg().targetSeed`.
    function _specs() internal pure returns (TokenSpec[7] memory s) {
        s[0] = TokenSpec("USD Coin", "USDC", 6, 100_000_000); // 100 USDC
        s[1] = TokenSpec("Tether USD", "USDT", 6, 100_000_000); // 100 USDT
        s[2] = TokenSpec("PayPal USD", "PYUSD", 6, 100_000_000); // 100 PYUSD
        s[3] = TokenSpec("Dai", "DAI", 18, 100 ether); // 100 DAI
        s[4] = TokenSpec("Euro Coin", "EURC", 6, 86_000_000); // 86 EURC
        s[5] = TokenSpec("Turkish Lira Coin", "TRYC", 6, 1_800_000_000); // 1800 TRYC
        s[6] = TokenSpec("Brazilian Real C", "BRLC", 6, 516_000_000); // 516 BRLC
    }

    function run() external {
        require(block.chainid == 5042002, "DeployTokensFresh: Arc testnet (fork) only");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        TokenSpec[7] memory specs = _specs();

        console2.log("=== ArcoraDEX fresh testnet token deploy (Branch C) ===");
        console2.log("Deployer (initial owner + mint recipient):", deployer);
        console2.log("");

        vm.startBroadcast(deployerKey);

        console2.log("=== FRESH TOKEN ADDRESSES (export as env for DeployPublicTestnet) ===");
        for (uint256 i = 0; i < 7; i++) {
            MintableERC20 token = new MintableERC20(specs[i].name, specs[i].symbol, specs[i].decimals, deployer);
            // Mint the bootstrap seed to the deployer so DeployPublicTestnet can
            // approve + deposit it during _bootstrap. Deployer is the owner.
            token.mint(deployer, specs[i].targetSeed);
            require(token.balanceOf(deployer) == specs[i].targetSeed, "fresh token: mint amount mismatch");
            console2.log(string.concat("TOKEN_", specs[i].symbol, "= "), address(token));
            console2.log(string.concat("  minted ", specs[i].symbol, " seed:"), specs[i].targetSeed);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("NEXT: export the TOKEN_<SYM> lines above into env, then run");
        console2.log("  DeployPublicTestnet.s.sol (it reads them via resolvedTokens()).");
    }
}
