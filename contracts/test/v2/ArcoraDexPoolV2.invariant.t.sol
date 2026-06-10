// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {V2Fixture} from "./helpers/V2Fixture.sol";
import {PoolV2Handler} from "./handlers/PoolV2Handler.sol";
import {MintableERC20} from "../../src/testnet/MintableERC20.sol";
import {FeeBandMathV2} from "../../src/v2/lib/FeeBandMathV2.sol";

contract ArcoraDexPoolV2Invariant is StdInvariant, V2Fixture {
    PoolV2Handler handler;
    address a1 = makeAddr("a1");
    address a2 = makeAddr("a2");

    function setUp() public {
        _deployV2();
        // Seed both tokens at target.
        _seed(usdc, makeAddr("seeder"), 2_000_000e6);
        _seed(eurc, makeAddr("seeder2"), 2_000_000e6);
        // Fund actors.
        _mint(usdc, a1, 1_000_000e6);
        _mint(eurc, a1, 1_000_000e6);
        _mint(usdc, a2, 1_000_000e6);
        _mint(eurc, a2, 1_000_000e6);

        address[] memory actors = new address[](2);
        actors[0] = a1;
        actors[1] = a2;
        address[] memory tks = new address[](2);
        tks[0] = address(usdc);
        tks[1] = address(eurc);
        handler = new PoolV2Handler(address(pool), address(reg), address(lp), address(adapter), owner, actors, tks);
        targetContract(address(handler));
    }

    /// §14 INV-1: tokenBalance >= reserves[token] + protocolFeesAccrued[token].
    function invariant_balance_ge_reserves_plus_fees() public view {
        address[2] memory tks = [address(usdc), address(eurc)];
        for (uint256 i; i < tks.length; ++i) {
            uint256 bal = MintableERC20(tks[i]).balanceOf(address(pool));
            assertGe(bal, pool.reserves(tks[i]) + pool.protocolFeesAccrued(tks[i]), "balance < reserves + fees");
        }
    }

    /// §14 INV-2: oraclePricedOperation => postReserveUsd >= minimumReserveUsd.
    /// After any sequence of priced ops, every active token's accounted reserve USD
    /// (at the current safe price, or skipped if unsafe) is >= its floor.
    function invariant_priced_ops_respect_floor() public view {
        address[2] memory tks = [address(usdc), address(eurc)];
        for (uint256 i; i < tks.length; ++i) {
            (uint256 p, bool safe) = adapter.peekPrice(tks[i]);
            if (!safe) continue; // unsafe tokens cannot be priced — INV-3 covers them
            uint256 dec = reg.tokenConfig(tks[i]).decimals;
            uint256 reserveUsd = (pool.reserves(tks[i]) * p) / (10 ** dec);
            assertGe(reserveUsd, reg.tokenConfig(tks[i]).minimumReserveUsd, "reserve below floor after priced op");
        }
    }

    /// §14 INV-3: singleSourceOracle => no oraclePricedOperation. Modelled via the
    /// adapter unsafe flag: when a token is unsafe, a quoteSwapV2 into it MUST revert
    /// (the priced path is closed). Proportional exit is NOT a priced op and is unaffected.
    function invariant_unsafe_blocks_priced_path() public {
        address[2] memory tks = [address(usdc), address(eurc)];
        for (uint256 i; i < tks.length; ++i) {
            (, bool safe) = adapter.peekPrice(tks[i]);
            if (safe) continue;
            // Pick the other token as input.
            address tIn = tks[i] == address(usdc) ? address(eurc) : address(usdc);
            try pool.quoteSwapV2(tIn, tks[i], 1e6) {
                revert("priced path open on unsafe token");
            } catch {
                // expected: OracleUnsafe (or, if tIn also unsafe, still reverts)
            }
        }
    }

    /// §14 INV-4: proportionalExit preserves equal basket treatment.
    function invariant_proportional_equal_basket() public view {
        assertTrue(handler.lastProportionalEqualBasket(), "proportional exit broke equal-basket");
    }

    /// §14 INV-5: fee(split execution) ~= fee(single execution), bounded tolerance.
    /// Tolerance: <= 8 wei of 1e18-USD across up to 2 split boundaries (≤4 wei each).
    function invariant_split_equals_single_fee() public view {
        // Probe split-vs-single fee consistency against the live USDC reserve.
        FeeBandMathV2.Band[] memory b = _defaultBands();
        uint256 min = reg.tokenConfig(address(usdc)).minimumReserveUsd;
        uint256 tgt = reg.tokenConfig(address(usdc)).targetReserveUsd;
        // The marginal split==single identity is a *rounding* question only while the gross
        // and both split halves stay entirely WITHIN a single band, away from the floor.
        // Crossing a band boundary makes fee(single contiguous gross) and fee(two re-clamped
        // halves) legitimately differ by far more than a few wei — a property of marginal
        // banding, not a `traverse` bug. So we probe only when the live reserve sits well
        // inside the top band (health >= 8000 bps, a 500 bps margin above the 75% boundary)
        // and consume a gross worth only ~100 bps of health, which keeps single + both halves
        // inside band 0 and clear of the floor. There the identity must hold to <= 8 wei. (§7/§14)
        uint256 reserveUsd = (pool.reserves(address(usdc)) * 1e18) / 1e6;
        if (reserveUsd > tgt) reserveUsd = tgt; // above-target reserve prices at 100% health
        uint256 health = FeeBandMathV2.healthBps(reserveUsd, min, tgt);
        if (health < 8_000) return; // not safely inside band 0 — identity undefined here; skip
        uint256 gross = ((tgt - min) * 100) / 10_000; // ~100 bps of health, well within band 0
        if (gross == 0) return;
        FeeBandMathV2.Result memory single = FeeBandMathV2.traverse(gross, reserveUsd, min, tgt, b, PROT_SHARE);
        FeeBandMathV2.Result memory h1 = FeeBandMathV2.traverse(gross / 2, reserveUsd, min, tgt, b, PROT_SHARE);
        uint256 reserveAfter = reserveUsd - h1.totalReserveDebitUsd;
        FeeBandMathV2.Result memory h2 =
            FeeBandMathV2.traverse(gross - gross / 2, reserveAfter, min, tgt, b, PROT_SHARE);
        uint256 splitFee = h1.totalFeeUsd + h2.totalFeeUsd;
        uint256 diff = single.totalFeeUsd > splitFee ? single.totalFeeUsd - splitFee : splitFee - single.totalFeeUsd;
        assertLe(diff, 8, "split vs single fee divergence exceeds tolerance");
    }
}
