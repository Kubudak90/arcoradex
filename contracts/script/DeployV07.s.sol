// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 }           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { StablecoinRegistry }   from "../src/registry/StablecoinRegistry.sol";
import { StablePool }           from "../src/pool/StablePool.sol";
import { ArcFXGateway }         from "../src/ArcFXGateway.sol";
import { MintableERC20 }        from "../src/testnet/MintableERC20.sol";
import { MockChainlinkFeed }    from "../src/testnet/MockChainlinkFeed.sol";
import { IStablePool }          from "../src/pool/IStablePool.sol";
import { IStablecoinRegistry }  from "../src/registry/IStablecoinRegistry.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";

/// @title DeployV07
/// @notice One-shot deploy of the v0.7 stack: registry, pool, gateway, plus
/// 7 mintable mock stablecoins and 7 mock Chainlink-shaped feeds. Lists every
/// token in the registry and seeds each pool reserve with ~$1M of depth.
/// @dev Required env: DEPLOYER_PRIVATE_KEY, TREASURY_OWNER, PROTOCOL_FEE_BPS,
/// SWAP_FEE_BPS. Asserts `vm.addr(DEPLOYER_PRIVATE_KEY) == TREASURY_OWNER`
/// so the listing + seeding broadcast is signed by the registry/pool owner.
contract DeployV07 is Script {
    struct TokenSpec {
        string  name;
        string  symbol;
        uint8   decimals;
        int256  initialPrice1e8;   // Chainlink-shaped, 8 decimals
        uint16  deviationBps;
        uint256 seedAmount;        // pool reserve to seed (token units)
    }

    function run()
        external
        returns (
            StablecoinRegistry reg,
            StablePool pool,
            ArcFXGateway gw,
            address[7] memory tokens,
            address[7] memory feeds
        )
    {
        uint256 pk      = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner   = vm.envAddress("TREASURY_OWNER");
        uint256 feeBps  = vm.envUint("PROTOCOL_FEE_BPS");
        uint256 swapFee = vm.envUint("SWAP_FEE_BPS");

        require(vm.addr(pk) == owner, "DeployV07: deployer must equal TREASURY_OWNER");
        require(swapFee <= type(uint16).max, "DeployV07: SWAP_FEE_BPS overflows uint16");
        require(feeBps <= 100, "DeployV07: PROTOCOL_FEE_BPS too high");

        TokenSpec[7] memory specs = [
            TokenSpec("USD Coin",       "USDC",  6,  1.0000e8, 50,       1_000_000e6),
            TokenSpec("Tether USD",     "USDT",  6,  1.0001e8, 50,       1_000_000e6),
            TokenSpec("PayPal USD",     "PYUSD", 6,  1.0000e8, 50,       1_000_000e6),
            TokenSpec("Dai Stablecoin", "DAI",   18, 1.0000e8, 50,       1_000_000e18),
            TokenSpec("Euro Coin",      "EURC",  6,  1.0863e8, 150,        920_000e6),
            TokenSpec("Lira Coin",      "TRYC",  6,  0.0291e8, 150,     34_000_000e6),
            TokenSpec("Real Coin",      "BRLC",  6,  0.1980e8, 150,      5_050_000e6)
        ];

        vm.startBroadcast(pk);

        reg  = new StablecoinRegistry(owner);
        pool = new StablePool(address(reg), uint16(swapFee), owner);
        gw   = new ArcFXGateway(
            IStablePool(address(pool)),
            IStablecoinRegistry(address(reg)),
            feeBps,
            owner
        );

        for (uint256 i = 0; i < 7; i++) {
            TokenSpec memory s = specs[i];
            MintableERC20 t = new MintableERC20(s.name, s.symbol, s.decimals, owner);
            MockChainlinkFeed f = new MockChainlinkFeed(8, s.initialPrice1e8);
            tokens[i] = address(t);
            feeds[i]  = address(f);

            reg.listToken(tokens[i], s.decimals, IChainlinkAggregator(feeds[i]), s.deviationBps);
            t.mint(owner, s.seedAmount);
            IERC20(tokens[i]).approve(address(pool), s.seedAmount);
            pool.deposit(tokens[i], s.seedAmount);
        }

        vm.stopBroadcast();

        console2.log("Registry:", address(reg));
        console2.log("Pool:    ", address(pool));
        console2.log("Gateway: ", address(gw));
        for (uint256 i = 0; i < 7; i++) {
            console2.log(string.concat("Token[", vm.toString(i), "] ", specs[i].symbol, ":"), tokens[i]);
            console2.log(string.concat("Feed [", vm.toString(i), "] ", specs[i].symbol, ":"), feeds[i]);
        }
    }
}
