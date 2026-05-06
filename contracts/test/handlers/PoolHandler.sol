// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ArcoraDexPool }     from "../../src/ArcoraDexPool.sol";
import { ArcoraDexLP }       from "../../src/ArcoraDexLP.sol";
import { MintableERC20 }     from "../../src/testnet/MintableERC20.sol";

/// @notice Random-action driver for the invariant tests. Calls public Pool entry points
/// with bounded inputs, fronted by a small set of actors. Every action is wrapped in
/// `try` so the handler never reverts the invariant runner.
contract PoolHandler is Test {
    ArcoraDexPool public pool;
    ArcoraDexLP   public lp;
    address[]     public actors;
    address[]     public tokens;

    uint256 public depositCalls;
    uint256 public withdrawCalls;
    uint256 public swapCalls;

    constructor(address pool_, address lp_, address[] memory actors_, address[] memory tokens_) {
        pool   = ArcoraDexPool(pool_);
        lp     = ArcoraDexLP(lp_);
        actors = actors_;
        tokens = tokens_;
    }

    function deposit(uint256 actorSeed, uint256 tokenSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        address token = tokens[tokenSeed % tokens.length];
        uint8 dec = MintableERC20(token).decimals();
        uint256 amount = bound(amountSeed, 10 ** dec, 10_000 * 10 ** dec);
        // Skip if actor doesn't have enough balance — set up by the harness.
        if (MintableERC20(token).balanceOf(actor) < amount) return;

        vm.prank(actor);
        MintableERC20(token).approve(address(pool), amount);
        vm.prank(actor);
        try pool.deposit(token, amount, 0, block.timestamp + 1) { depositCalls++; } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 tokenSeed, uint256 lpSeed) external {
        address actor = actors[actorSeed % actors.length];
        address token = tokens[tokenSeed % tokens.length];
        uint256 bal   = lp.balanceOf(actor);
        if (bal == 0) return;
        uint256 lpAmt = bound(lpSeed, 1, bal);
        vm.prank(actor);
        try pool.withdraw(token, lpAmt, 0, block.timestamp + 1) { withdrawCalls++; } catch {}
    }

    function swap(uint256 actorSeed, uint256 inSeed, uint256 outSeed, uint256 amtSeed) external {
        address actor = actors[actorSeed % actors.length];
        address tIn   = tokens[inSeed % tokens.length];
        address tOut  = tokens[outSeed % tokens.length];
        if (tIn == tOut) return;

        uint8 dec = MintableERC20(tIn).decimals();
        uint256 amount = bound(amtSeed, 10 ** dec, 1_000 * 10 ** dec);
        if (MintableERC20(tIn).balanceOf(actor) < amount) return;

        vm.prank(actor);
        MintableERC20(tIn).approve(address(pool), amount);
        vm.prank(actor);
        try pool.swap(tIn, tOut, amount, 0, block.timestamp + 1, actor) { swapCalls++; } catch {}
    }
}
