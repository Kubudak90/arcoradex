// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { ArcoraDexPool } from "../src/ArcoraDexPool.sol";
import { ArcoraDexLP }   from "../src/ArcoraDexLP.sol";
import { MintableERC20 } from "../src/testnet/MintableERC20.sol";

/// @notice Post-deploy smoke run. Reads addresses from env:
///   POOL_ADDRESS, USDC, USDT, PYUSD, DAI, EURC, TRYC, BRLC
contract SmokeArcoraDex is Script {
    function run() external {
        uint256 actorKey = vm.envUint("PRIVATE_KEY");
        ArcoraDexPool pool = ArcoraDexPool(vm.envAddress("POOL_ADDRESS"));
        address[7] memory toks = [
            vm.envAddress("USDC"),
            vm.envAddress("USDT"),
            vm.envAddress("PYUSD"),
            vm.envAddress("DAI"),
            vm.envAddress("EURC"),
            vm.envAddress("TRYC"),
            vm.envAddress("BRLC")
        ];
        ArcoraDexLP lp = ArcoraDexLP(address(pool.LP()));

        vm.startBroadcast(actorKey);

        // Mint extra of every token to the actor for swap inputs.
        // Deployer (the actor) is the token owner from the deploy script, so direct mint works.
        for (uint256 i = 0; i < toks.length; i++) {
            uint8 d = MintableERC20(toks[i]).decimals();
            MintableERC20(toks[i]).mint(vm.addr(actorKey), 1_000 * 10 ** d);
            MintableERC20(toks[i]).approve(address(pool), type(uint256).max);
        }

        // Flow 1: deposit 1000 USDC
        pool.deposit(toks[0], 1_000 * 10 ** 6, 0, block.timestamp + 1 days);
        console2.log("after deposit USDC, NAV:", pool.totalReservesUSD());

        // Flow 2: deposit 1000 EURC
        pool.deposit(toks[4], 1_000 * 10 ** 6, 0, block.timestamp + 1 days);
        console2.log("after deposit EURC, NAV:", pool.totalReservesUSD());

        // Flow 3: swap 100 USDC -> EURC
        uint256 out35 = pool.swap(toks[0], toks[4], 100 * 10 ** 6, 0, block.timestamp + 1 days, vm.addr(actorKey));
        console2.log("USDC->EURC out:", out35);

        // Flow 4: swap 100 EURC -> TRYC (cross-FX)
        uint256 out45 = pool.swap(toks[4], toks[5], 100 * 10 ** 6, 0, block.timestamp + 1 days, vm.addr(actorKey));
        console2.log("EURC->TRYC out:", out45);

        // Flow 5: swap 100 PYUSD -> DAI (6 -> 18 decimals)
        uint256 out55 = pool.swap(toks[2], toks[3], 100 * 10 ** 6, 0, block.timestamp + 1 days, vm.addr(actorKey));
        console2.log("PYUSD->DAI out:", out55);

        // Flow 6: withdraw 500 LP as USDC
        uint256 lpBal = lp.balanceOf(vm.addr(actorKey));
        uint256 burn  = lpBal > 500e18 ? 500e18 : lpBal / 2;
        uint256 wOut  = pool.withdraw(toks[0], burn, 0, block.timestamp + 1 days);
        console2.log("withdraw->USDC out:", wOut);

        // Flow 7: withdraw 500 LP as BRLC
        lpBal = lp.balanceOf(vm.addr(actorKey));
        burn  = lpBal > 500e18 ? 500e18 : lpBal / 2;
        uint256 wOutBRLC = pool.withdraw(toks[6], burn, 0, block.timestamp + 1 days);
        console2.log("withdraw->BRLC out:", wOutBRLC);

        vm.stopBroadcast();
    }
}
