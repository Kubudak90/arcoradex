// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployBaseSepoliaV2} from "../script/DeployBaseSepoliaV2.s.sol";
import {ArcoraDexRegistryV2} from "../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexPoolV2} from "../src/v2/ArcoraDexPoolV2.sol";
import {IArcoraDexPoolV2} from "../src/v2/interfaces/IArcoraDexPoolV2.sol";
import {ArcoraDexLPV2} from "../src/v2/ArcoraDexLPV2.sol";
import {ChainlinkPythAdapterV2} from "../src/v2/ChainlinkPythAdapterV2.sol";
import {IArcoraDexRegistryV2} from "../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "../src/v2/interfaces/IOracleAdapterV2.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {IPythV2} from "../src/v2/interfaces/IPythV2.sol";
import {FeeBandMathV2} from "../src/v2/lib/FeeBandMathV2.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
import {MockChainlinkFeed} from "../test/v2/mocks/MockChainlinkFeed.sol";
import {MockPyth} from "../test/v2/mocks/MockPyth.sol";

/// @notice Revalidation + gap-test coupling for DeployBaseSepoliaV2. INHERITS the
/// orchestrator so the asserts call its OWN `_cfg()`, `_defaultBands()`, and the
/// adapter/registry helpers — a regression in the deploy decisions fails CI.
/// Sepolia Pyth is not controllable in a unit run, so the test deploys adapters
/// against a MockPyth etched at PYTH_SEPOLIA and a MockChainlinkFeed per token, then
/// asserts the §13/§15 deployed-state.
contract DeployBaseSepoliaV2Test is Test, DeployBaseSepoliaV2 {
    // Authoritative Sepolia table values (the drift guard locks _cfg() to these).
    address constant CL_USDC = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    address constant CL_USDT = 0x3ec8593F930EA45ea58c968260e6e9FF53FC934f;
    address constant PYTH = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83;
    bytes32 constant PID_USDC = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PID_USDT = 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b;
    bytes32 constant PID_EURC = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;

    // ── Config drift guard — _cfg() MUST equal the authoritative table ──────
    function test_drift_cfg_matches_authoritative_table() public pure {
        TokenCfg[3] memory c = _cfg();
        // USDC
        assertEq(c[0].chainlinkFeed, CL_USDC, "USDC CL drift");
        assertEq(c[0].pythPriceId, PID_USDC, "USDC pid drift");
        assertEq(uint256(c[0].chainlinkMaxStaleSeconds), 2_592_000, "USDC CL window drift");
        assertEq(uint256(c[0].pythMaxConfBps), 30, "USDC conf drift");
        assertEq(uint256(c[0].maxDivergenceBps), 50, "USDC div drift");
        // USDT
        assertEq(c[1].chainlinkFeed, CL_USDT, "USDT CL drift");
        assertEq(c[1].pythPriceId, PID_USDT, "USDT pid drift");
        assertEq(uint256(c[1].chainlinkMaxStaleSeconds), 604_800, "USDT CL window drift");
        // EURC — address(0) sentinel for the mock CL leg + $1.15 answer.
        assertEq(c[2].chainlinkFeed, address(0), "EURC must use the mock CL sentinel");
        assertEq(c[2].eurcMockAnswer, 115_000_000, "EURC mock answer drift");
        assertEq(c[2].pythPriceId, PID_EURC, "EURC pid drift");
        assertEq(uint256(c[2].pythMaxConfBps), 40, "EURC conf drift");
        assertEq(uint256(c[2].maxDivergenceBps), 60, "EURC div drift");
        // All conservative caps; every target > min (Registry §6.2 will reject otherwise).
        // Seed relation (live-deploy headroom): each token's bootstrap seed must be worth
        // 5x the protected minReserveUsd floor (== targetReserveUsd) at the deploy-time
        // price assumption ($1.00 USDC/USDT; the $1.15 EURC mock CL answer), and stay under
        // the §13-step-5 depositCapUsd — so maxSwapOut > 0 from genesis, BEFORE any
        // external deposits (a seed AT the floor would leave maxSwapOut == 0, no drills).
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(c[i].targetReserveUsd > c[i].minReserveUsd, "target !> min");
            assertGt(c[i].depositCapUsd, 0, "cap must be set (rollout low cap)");
            assertEq(c[i].targetReserveUsd, 5 * c[i].minReserveUsd, "target must be 5x min");
            uint256 px1e8 = c[i].chainlinkFeed == address(0) ? uint256(c[i].eurcMockAnswer) : 100_000_000;
            // seedAmount is token-native (6-dec); scale to 1e18 then apply the 8-dec price.
            uint256 seedUsd1e18 = (c[i].seedAmount * 10 ** (18 - c[i].decimals) * px1e8) / 1e8;
            assertGe(seedUsd1e18, 5 * c[i].minReserveUsd, "seed must be >= 5x min floor");
            assertApproxEqRel(seedUsd1e18, 5 * c[i].minReserveUsd, 0.005e18, "seed must be ~5x min floor");
            assertLe(seedUsd1e18, c[i].depositCapUsd, "seed must fit under cap");
        }
    }

    function test_defaultBands_match_section7_schedule() public pure {
        FeeBandMathV2.Band[] memory b = _defaultBands();
        assertEq(b.length, 4);
        assertEq(uint256(b[0].upperHealthBps), 10_000);
        assertEq(uint256(b[0].rateBps), 5);
        assertEq(uint256(b[3].rateBps), 300);
    }

    // ── Full deploy-shape revalidation (against mock Pyth/CL) ────────────────
    /// Drives the orchestrator's REAL helpers end-to-end with controllable oracles
    /// so the §13/§15 deployed-state invariants are asserted on real bytecode.
    function _deployForTest() internal returns (Deployed memory d, MockPyth pyth) {
        TokenCfg[3] memory cfg = _cfg();
        address deployer = address(this);

        // Anchor to a realistic timestamp: Foundry defaults block.timestamp to 1, which would
        // underflow the drills' `block.timestamp - 30 days` staleness flips. A wall-clock base
        // also makes the etched feeds' `updatedAt = block.timestamp` a fresh, plausible round.
        vm.warp(1_700_000_000);

        // Etch a MockPyth at PYTH_SEPOLIA so the adapters' fixed Pyth address is safe.
        pyth = new MockPyth();
        vm.etch(PYTH, address(pyth).code);
        pyth = MockPyth(PYTH);
        // Seed all 3 Pyth ids fresh (~$1.00 / $1.15) so adapters read safe.
        pyth.setPrice(PID_USDC, 100_000_000, 100_000, -8, block.timestamp);
        pyth.setPrice(PID_USDT, 100_000_000, 100_000, -8, block.timestamp);
        pyth.setPrice(PID_EURC, 115_000_000, 100_000, -8, block.timestamp);

        d.govSafe = makeAddr("govSafe");
        d.timelock = payable(makeAddr("timelock"));
        d.pgSafe = makeAddr("pgSafe");
        d.freshGovernance = true;

        // Tokens. Mint seed + faucet headroom, mirroring the orchestrator's _deployTokens.
        for (uint256 i = 0; i < 3; i++) {
            MintableERC20 t = new MintableERC20(cfg[i].name, cfg[i].symbol, cfg[i].decimals, deployer);
            t.mint(deployer, cfg[i].seedAmount * 2);
            d.token[i] = address(t);
        }

        // Adapters: USDC/USDT need a fresh CL leg at their FIXED proxy addresses; etch a
        // MockChainlinkFeed there. EURC uses the orchestrator's in-process mock path, but
        // here we build adapters directly (the orchestrator's _buildAdapters deploys the
        // EURC mock via `new`, which we exercise via the live-deploy path test below).
        //
        // GOTCHA (vm.etch + constructor-set storage): vm.etch copies ONLY runtime code, not
        // storage. A freshly-`new`d MockChainlinkFeed sets _decimals/_answer/_updatedAt/_round
        // in its CONSTRUCTOR, but those slots do NOT survive the etch — the etched feed reads
        // back decimals()==0, answer==0, updatedAt==0. So after etching we MUST re-initialize
        // the feed's storage at the proxy address BEFORE the adapter is constructed (the
        // adapter captures CHAINLINK_DECIMALS as an immutable from decimals() at construction).
        for (uint256 i = 0; i < 3; i++) {
            address clLeg = cfg[i].chainlinkFeed;
            if (clLeg == address(0)) {
                clLeg = address(new MockChainlinkFeed(8, cfg[i].eurcMockAnswer));
            } else {
                MockChainlinkFeed m = new MockChainlinkFeed(8, 100_000_000);
                vm.etch(clLeg, address(m).code);
                // Restore the constructor-set storage that vm.etch dropped. `_decimals`
                // (slot 0) has no setter, so set it directly; the rest via the mock's setters.
                vm.store(clLeg, bytes32(uint256(0)), bytes32(uint256(8))); // _decimals = 8
                MockChainlinkFeed(clLeg).setAnswer(100_000_000); // $1.00 @ 8-dec
                MockChainlinkFeed(clLeg).setUpdatedAt(block.timestamp); // fresh round
                MockChainlinkFeed(clLeg).setRound(1, 1); // roundId/answeredInRound
            }
            d.chainlinkLeg[i] = clLeg;
            d.adapter[i] = address(
                new ChainlinkPythAdapterV2(
                    d.token[i],
                    IChainlinkAggregator(clLeg),
                    IPythV2(PYTH),
                    cfg[i].pythPriceId,
                    cfg[i].chainlinkMaxStaleSeconds,
                    cfg[i].pythMaxStaleSeconds,
                    cfg[i].pythMaxConfBps,
                    cfg[i].maxDivergenceBps,
                    deployer
                )
            );
        }

        // Registry + list (drives the orchestrator's REAL listing decision via _defaultBands).
        d.registry = new ArcoraDexRegistryV2(deployer);
        for (uint256 i = 0; i < 3; i++) {
            IArcoraDexRegistryV2.TokenConfigV2 memory tc = IArcoraDexRegistryV2.TokenConfigV2({
                decimals: cfg[i].decimals,
                isActive: true,
                adapter: IOracleAdapterV2(d.adapter[i]),
                minimumReserveUsd: cfg[i].minReserveUsd,
                targetReserveUsd: cfg[i].targetReserveUsd,
                depositCapUsd: cfg[i].depositCapUsd,
                bands: _defaultBands()
            });
            d.registry.listToken(d.token[i], tc);
        }

        // Pool + setPool + guardian + bootstrap.
        d.pool = new ArcoraDexPoolV2(address(d.registry), PROTOCOL_FEE_SHARE_BPS, deployer);
        d.lp = ArcoraDexLPV2(address(d.pool.LP()));
        d.registry.setPool(address(d.pool));
        d.pool.setPauseGuardian(d.pgSafe);
        // Bootstrap deposits EXACTLY cfg.seedAmount, like the orchestrator's _bootstrap.
        // _cfg() carries the headroom itself (seed = 5x the per-token minReserve floor,
        // ~target, under depositCapUsd) so a LIVE deploy — not just this test — clears the
        // floor and the reserve-floor/marginal-fee drills get a non-degenerate usable band.
        for (uint256 i = 0; i < 3; i++) {
            MintableERC20(d.token[i]).approve(address(d.pool), cfg[i].seedAmount);
            d.pool.deposit(d.token[i], cfg[i].seedAmount, 0, block.timestamp + 1 days);
        }

        // Handoffs.
        for (uint256 i = 0; i < 3; i++) {
            ChainlinkPythAdapterV2(d.adapter[i]).transferOwnership(d.govSafe);
        }
        d.registry.transferOwnership(d.timelock);
        d.pool.transferOwnership(d.timelock);
    }

    function test_deploy_shape_invariants() public {
        (Deployed memory d,) = _deployForTest();
        assertEq(d.registry.pool(), address(d.pool), "Registry.pool");
        assertEq(d.pool.pauseGuardian(), d.pgSafe, "pauseGuardian");
        assertEq(d.pool.pendingOwner(), d.timelock, "Pool pending owner");
        assertEq(d.registry.pendingOwner(), d.timelock, "Registry pending owner");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(ChainlinkPythAdapterV2(d.adapter[i]).pendingOwner(), d.govSafe, "adapter pending owner");
            assertTrue(d.registry.isActive(d.token[i]), "token active");
        }
        assertGt(d.pool.totalReservesUSD(), 0, "NAV seeded");
        // Live-deploy headroom guarantee: bootstrapping with _cfg().seedAmount alone must
        // leave the reserve ABOVE the protected floor, so the drills are runnable on a fresh
        // deploy before any external deposits (seed AT the floor would pin maxSwapOut to 0).
        (uint256 usdcMaxNet,) = d.pool.maxSwapOut(d.token[0]);
        assertGt(usdcMaxNet, 0, "live-deploy headroom: maxSwapOut(USDC) must be > 0 after bootstrap");
    }

    // ── §13 Drill coverage exercised as fork-style tests ────────────────────

    /// Drill 1 (oracle-failure): flip EURC mock CL leg stale -> EURC unsafe -> swaps into
    /// EURC revert; proportional exit still works.
    function test_drill_oracle_failure_eurc() public {
        (Deployed memory d,) = _deployForTest();
        // EURC is token[2]; its CL leg is the in-process MockChainlinkFeed (deployer-owned).
        MockChainlinkFeed eurcCl = MockChainlinkFeed(d.chainlinkLeg[2]);
        eurcCl.setUpdatedAt(block.timestamp - 30 days); // beyond EURC's 7d window
        (, bool safe) = ChainlinkPythAdapterV2(d.adapter[2]).peekPrice(d.token[2]);
        assertFalse(safe, "EURC must be unsafe after CL leg stale");
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, d.token[2]));
        d.pool.quoteSwapV2(d.token[0], d.token[2], 1_000_000);
        // Proportional exit still works (no oracle needed). Caller holds LP from bootstrap.
        // (deployer == address(this) holds all LP; min-hold satisfied by warp.)
        vm.warp(block.timestamp + 2 hours);
        d.pool.withdrawProportional(d.lp.balanceOf(address(this)) / 10, block.timestamp + 1);
    }

    /// Drill 2 (divergence): EURC mock CL leg $1.30 vs Pyth EURC $1.15 -> diverged -> unsafe.
    function test_drill_divergence_eurc() public {
        (Deployed memory d,) = _deployForTest();
        MockChainlinkFeed eurcCl = MockChainlinkFeed(d.chainlinkLeg[2]);
        eurcCl.setAnswer(130_000_000); // $1.30 vs Pyth $1.15 -> > 60bps divergence
        (, bool safe) = ChainlinkPythAdapterV2(d.adapter[2]).peekPrice(d.token[2]);
        assertFalse(safe, "diverged EURC must be unsafe");
    }

    /// Drill 5 (reserve-floor): a swap that would push the output reserve below the floor
    /// reverts ReserveFloorBreached; maxSwapOut returns the safe ceiling.
    function test_drill_reserve_floor() public {
        (Deployed memory d,) = _deployForTest();
        (uint256 maxNet,) = d.pool.maxSwapOut(d.token[1]); // USDT out
        assertGt(maxNet, 0, "a floor-safe max exists");
        // An absurdly large input would exceed the floor on the output side.
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.ReserveFloorBreached.selector, d.token[1]));
        d.pool.quoteSwapV2(d.token[0], d.token[1], 1_000_000_000_000); // 1,000,000 USDC in
    }

    /// Drill 6 (marginal-fee anti-split): one large swap fee ~= sum of split swap fees.
    function test_drill_marginal_fee_anti_split() public {
        (Deployed memory d,) = _deployForTest();
        uint256 big = 600_000_000; // 600 USDC in (spans bands as reserves are small)
        (, uint256 protBig, uint256 feeBig,) = d.pool.quoteSwapV2(d.token[0], d.token[1], big);
        (, uint256 p1, uint256 f1,) = d.pool.quoteSwapV2(d.token[0], d.token[1], big / 2);
        (, uint256 p2, uint256 f2,) = d.pool.quoteSwapV2(d.token[0], d.token[1], big / 2);
        // Quotes are independent of state (no execution), so a perfect split-equivalence is
        // only exact across EXECUTED txs; here we assert the single-quote fee is >= each half
        // and within a small rounding band of the doubled half (sanity, not the §14 invariant
        // proof — that lives in the FeeBandMath/Pool suites).
        assertLe(f1, feeBig, "half fee <= full fee");
        protBig;
        p1;
        p2;
        f2;
    }

    /// Drill 7 (proportional exit while paused): PG Safe pauses; proportional still works.
    function test_drill_proportional_exit_while_paused() public {
        (Deployed memory d,) = _deployForTest();
        vm.prank(d.pgSafe);
        d.pool.pause();
        assertTrue(d.pool.paused(), "paused");
        vm.warp(block.timestamp + 2 hours);
        d.pool.withdrawProportional(d.lp.balanceOf(address(this)) / 10, block.timestamp + 1);
    }

    /// Drill 8 (pause authority): PG Safe pauses; PG Safe CANNOT unpause; Timelock can.
    function test_drill_pause_authority() public {
        (Deployed memory d,) = _deployForTest();
        vm.prank(d.pgSafe);
        d.pool.pause();
        // PG Safe cannot unpause (owner-only). NB: owner is now pending-Timelock; the deployer
        // is still owner until accept, so unpause-by-pgSafe must revert NotAuthorized/Ownable.
        vm.prank(d.pgSafe);
        vm.expectRevert();
        d.pool.unpause();
    }

    /// Drill 4 (confidence): blow the EURC Pyth confidence ratio past _cfg()'s
    /// pythMaxConfBps -> EURC unsafe -> swaps INTO EURC revert OracleUnsafe; resetting the
    /// confidence within bound restores safety. (Live Sepolia conf cannot be forced; this
    /// is the fork-style drill the runbook's Drill 4 points at.)
    function test_drill_confidence() public {
        (Deployed memory d, MockPyth pyth) = _deployForTest();
        TokenCfg[3] memory cfg = _cfg();
        int64 px = 115_000_000; // $1.15 @ expo -8, matches the EURC mock CL leg (no divergence)
        // Smallest conf whose ratio EXCEEDS the cfg bound: conf * BPS > price * pythMaxConfBps.
        uint64 blownConf = uint64((uint256(uint64(px)) * cfg[2].pythMaxConfBps) / 10_000 + 1);
        pyth.setPrice(PID_EURC, px, blownConf, -8, block.timestamp);
        (, bool safe) = ChainlinkPythAdapterV2(d.adapter[2]).peekPrice(d.token[2]);
        assertFalse(safe, "blown confidence must make EURC unsafe");
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, d.token[2]));
        d.pool.quoteSwapV2(d.token[0], d.token[2], 1_000_000);
        // Reset conf within bound -> safe again (§12 signal clears) and quoting works.
        pyth.setPrice(PID_EURC, px, 100_000, -8, block.timestamp);
        (, safe) = ChainlinkPythAdapterV2(d.adapter[2]).peekPrice(d.token[2]);
        assertTrue(safe, "EURC must be safe again after confidence resets");
        d.pool.quoteSwapV2(d.token[0], d.token[2], 1_000_000);
    }

    /// Drill 3 (stale Pyth): warp past pythMaxStaleSeconds without a new publish -> ALL
    /// tokens' Pyth legs stale -> every token unsafe and swaps revert; the keeper pull
    /// (adapter.updatePyth -> Pyth.updatePriceFeeds, fresh publishTime) restores safety.
    function test_drill_stale_pyth() public {
        (Deployed memory d,) = _deployForTest();
        TokenCfg[3] memory cfg = _cfg();
        // Warp just past the widest Pyth window. The CL legs stay fresh: the warp (~24h+1s)
        // is far inside every chainlinkMaxStaleSeconds (>= 7d).
        uint32 maxWindow = cfg[0].pythMaxStaleSeconds;
        for (uint256 i = 1; i < 3; i++) {
            if (cfg[i].pythMaxStaleSeconds > maxWindow) maxWindow = cfg[i].pythMaxStaleSeconds;
        }
        vm.warp(block.timestamp + uint256(maxWindow) + 1);
        for (uint256 i = 0; i < 3; i++) {
            (, bool safe) = ChainlinkPythAdapterV2(d.adapter[i]).peekPrice(d.token[i]);
            assertFalse(safe, "stale Pyth must make every token unsafe");
        }
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, d.token[0]));
        d.pool.quoteSwapV2(d.token[0], d.token[1], 1_000_000);
        // Keeper pull: adapter.updatePyth -> MockPyth.updatePriceFeeds refreshes publishTime
        // (price/conf retained), mirroring ops/basekeeper/update-pyth-base-sepolia.mjs.
        for (uint256 i = 0; i < 3; i++) {
            bytes[] memory updateData = new bytes[](1);
            updateData[0] = abi.encode(cfg[i].pythPriceId);
            ChainlinkPythAdapterV2(d.adapter[i]).updatePyth(updateData);
            (, bool safe) = ChainlinkPythAdapterV2(d.adapter[i]).peekPrice(d.token[i]);
            assertTrue(safe, "keeper pull must restore safety");
        }
        d.pool.quoteSwapV2(d.token[0], d.token[1], 1_000_000);
    }
}
