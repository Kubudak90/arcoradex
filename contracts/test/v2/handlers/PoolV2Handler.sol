// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexPoolV2} from "../../../src/v2/ArcoraDexPoolV2.sol";
import {ArcoraDexRegistryV2} from "../../../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexLPV2} from "../../../src/v2/ArcoraDexLPV2.sol";
import {MockOracleAdapterV2} from "../mocks/MockOracleAdapterV2.sol";
import {MintableERC20} from "../../../src/testnet/MintableERC20.sol";

contract PoolV2Handler is Test {
    ArcoraDexPoolV2 public pool;
    ArcoraDexRegistryV2 public reg;
    ArcoraDexLPV2 public lp;
    MockOracleAdapterV2 public adapter;
    address public owner;
    address[] public actors;
    address[] public toks;

    // Ghost: whether any token is currently in a single-source/unsafe state. When true,
    // no oracle-priced op may succeed (invariant 3). We model "single source" exactly as
    // the adapter reporting unsafe.
    mapping(address token => bool) public unsafe;
    // Ghost: snapshot of pre/post equal-basket check for proportional exits.
    bool public lastProportionalEqualBasket = true;

    constructor(
        address pool_,
        address reg_,
        address lp_,
        address adapter_,
        address owner_,
        address[] memory actors_,
        address[] memory toks_
    ) {
        pool = ArcoraDexPoolV2(pool_);
        reg = ArcoraDexRegistryV2(reg_);
        lp = ArcoraDexLPV2(lp_);
        adapter = MockOracleAdapterV2(adapter_);
        owner = owner_;
        actors = actors_;
        toks = toks_;
    }

    function deposit(uint256 aSeed, uint256 tSeed, uint256 amtSeed) external {
        address actor = actors[aSeed % actors.length];
        address t = toks[tSeed % toks.length];
        uint256 amt = bound(amtSeed, 1e6, 50_000e6);
        if (MintableERC20(t).balanceOf(actor) < amt) return;
        vm.prank(actor);
        MintableERC20(t).approve(address(pool), amt);
        vm.prank(actor);
        try pool.deposit(t, amt, 0, block.timestamp + 1) {} catch {}
    }

    function swap(uint256 aSeed, uint256 inSeed, uint256 outSeed, uint256 amtSeed) external {
        address actor = actors[aSeed % actors.length];
        address tIn = toks[inSeed % toks.length];
        address tOut = toks[outSeed % toks.length];
        if (tIn == tOut) return;
        uint256 amt = bound(amtSeed, 1e6, 20_000e6);
        if (MintableERC20(tIn).balanceOf(actor) < amt) return;
        vm.prank(actor);
        MintableERC20(tIn).approve(address(pool), amt);
        vm.prank(actor);
        try pool.swap(tIn, tOut, amt, 0, block.timestamp + 1, actor) {} catch {}
    }

    function withdrawSingle(uint256 aSeed, uint256 tSeed, uint256 lpSeed) external {
        address actor = actors[aSeed % actors.length];
        address t = toks[tSeed % toks.length];
        uint256 bal = lp.balanceOf(actor);
        if (bal == 0) return;
        uint256 amt = bound(lpSeed, 1, bal);
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
        vm.prank(actor);
        try pool.withdrawSingle(t, amt, 0, block.timestamp + 1) {} catch {}
    }

    function withdrawProportional(uint256 aSeed, uint256 lpSeed) external {
        address actor = actors[aSeed % actors.length];
        uint256 bal = lp.balanceOf(actor);
        if (bal == 0) return;
        uint256 amt = bound(lpSeed, 1, bal);
        uint256 supply = lp.totalSupply();
        // Capture pre-state reserve ratios for the equal-basket check.
        uint256 n = reg.tokensLength();
        uint256[] memory preRes = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            preRes[i] = pool.reserves(reg.tokens(i));
        }
        vm.warp(block.timestamp + pool.MIN_HOLD_SECONDS() + 1);
        vm.prank(actor);
        try pool.withdrawProportional(amt, block.timestamp + 1) {
            // Equal basket: each token debited by exactly floor(amt*preRes/supply).
            for (uint256 i; i < n; ++i) {
                uint256 expDebit = (amt * preRes[i]) / supply;
                uint256 postRes = pool.reserves(reg.tokens(i));
                if (preRes[i] - postRes != expDebit) lastProportionalEqualBasket = false;
            }
        } catch {}
    }

    function setUnsafe(uint256 tSeed, bool flag) external {
        address t = toks[tSeed % toks.length];
        adapter.setSafe(t, !flag); // flag==true => unsafe
        unsafe[t] = flag;
    }

    function pauseToggle() external {
        if (pool.paused()) {
            vm.prank(owner);
            try pool.unpause() {} catch {}
        } else {
            vm.prank(owner);
            try pool.pause() {} catch {}
            vm.prank(owner);
            try pool.unpause() {} catch {}
        }
    }

    function anyUnsafe() external view returns (bool) {
        for (uint256 i; i < toks.length; ++i) {
            if (unsafe[toks[i]]) return true;
        }
        return false;
    }
}
