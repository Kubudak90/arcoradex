// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { ArcoraDexRegistry }    from "../src/ArcoraDexRegistry.sol";
import { ArcoraDexPool }        from "../src/ArcoraDexPool.sol";
import { ArcoraDexLP }          from "../src/ArcoraDexLP.sol";
import { MintableERC20 }        from "../src/testnet/MintableERC20.sol";
import { MockChainlinkFeed }    from "../src/testnet/MockChainlinkFeed.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";

contract DeployArcoraDex is Script {
    struct StableConfig {
        string  name;
        string  symbol;
        uint8   decimals;
        int256  initialPrice1e8;   // 8-dec Chainlink scale, e.g. 1e8 = $1.00
        uint16  deviationBps;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        StableConfig[7] memory cfg = [
            StableConfig("USD Coin",          "USDC",  6,  int256(1e8),         50),
            StableConfig("Tether USD",        "USDT",  6,  int256(1e8),         50),
            StableConfig("PayPal USD",        "PYUSD", 6,  int256(1e8),         50),
            StableConfig("Dai",               "DAI",  18,  int256(1e8),         50),
            StableConfig("Euro Coin",         "EURC",  6,  int256(108e6),      150),
            StableConfig("Turkish Lira Coin", "TRYC",  6,  int256(2_900_000), 5000),
            StableConfig("Brazilian Real C",  "BRLC",  6,  int256(20_000_000),5000)
        ];

        vm.startBroadcast(deployerKey);

        ArcoraDexRegistry reg  = new ArcoraDexRegistry(deployer);
        ArcoraDexPool     pool = new ArcoraDexPool(address(reg), 30, 1000, deployer);
        ArcoraDexLP       lp   = ArcoraDexLP(address(pool.LP()));

        console2.log("Registry:", address(reg));
        console2.log("Pool:    ", address(pool));
        console2.log("LP:      ", address(lp));

        for (uint256 i = 0; i < cfg.length; i++) {
            MintableERC20     t = new MintableERC20(cfg[i].name, cfg[i].symbol, cfg[i].decimals, deployer);
            MockChainlinkFeed f = new MockChainlinkFeed(8, cfg[i].initialPrice1e8);
            reg.listToken(address(t), cfg[i].decimals, IChainlinkAggregator(address(f)), cfg[i].deviationBps);
            console2.log(cfg[i].symbol, address(t), address(f));

            // $10,000 seed per token: amount = $10_000 * 10^decimals / price
            uint256 priceE18 = uint256(cfg[i].initialPrice1e8) * 1e10;            // 1e8 -> 1e18 scale
            uint256 seedAmt  = (10_000e18 * (10 ** cfg[i].decimals)) / priceE18;  // amount in token native dec
            t.mint(deployer, seedAmt);
            t.approve(address(pool), seedAmt);
            pool.deposit(address(t), seedAmt, 0, block.timestamp + 1 days);
        }

        console2.log("LP supply after seeding:", lp.totalSupply());
        console2.log("NAV (USD 1e18):         ", pool.totalReservesUSD());

        vm.stopBroadcast();
    }
}
