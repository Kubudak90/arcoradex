// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployArcV2} from "../script/DeployArcV2.s.sol";
import {ArcoraDexRegistryV2} from "../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexPoolV2} from "../src/v2/ArcoraDexPoolV2.sol";
import {ArcoraDexLPV2} from "../src/v2/ArcoraDexLPV2.sol";
import {IArcoraDexRegistryV2} from "../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IArcoraDexPoolV2} from "../src/v2/interfaces/IArcoraDexPoolV2.sol";
import {IOracleAdapterV2} from "../src/v2/interfaces/IOracleAdapterV2.sol";
import {FeeBandMathV2} from "../src/v2/lib/FeeBandMathV2.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
import {MockOracleAdapterV2Settable} from "../src/v2/testnet/MockOracleAdapterV2Settable.sol";

/// @notice Revalidation + gap-test coupling for DeployArcV2. INHERITS the orchestrator
/// so the asserts call its OWN `_cfg()`, `_defaultBands()`, and the build/list/seed
/// decisions — a regression in the deploy fails CI. Mock adapters are settable, so the
/// full deploy shape + §7/§11/§8 drills run deterministically with no etched feeds.
contract DeployArcV2Test is Test, DeployArcV2 {
    // -- Config drift guard: _cfg() MUST equal the authoritative Arc table --
    function test_drift_cfg_matches_authoritative_table() public pure {
        TokenCfg[3] memory c = _cfg();
        assertEq(c[0].pegPrice1e18, 1e18, "USDC peg drift");
        assertEq(c[1].pegPrice1e18, 1e18, "USDT peg drift");
        assertEq(c[2].pegPrice1e18, 115e16, "EURC peg drift");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(uint256(c[i].decimals), 6, "decimals must be 6");
            assertTrue(c[i].targetReserveUsd > c[i].minReserveUsd, "target !> min");
            assertGt(c[i].depositCapUsd, 0, "cap must be set (rollout low cap)");
            assertLt(c[i].seedAmount, c[i].depositCapUsd, "seed must fit under cap");
        }
    }

    function test_defaultBands_match_section7_schedule() public pure {
        FeeBandMathV2.Band[] memory b = _defaultBands();
        assertEq(b.length, 4);
        assertEq(uint256(b[0].upperHealthBps), 10_000);
        assertEq(uint256(b[0].rateBps), 5);
        assertEq(uint256(b[3].rateBps), 300);
    }

    // -- Full deploy-shape revalidation (drives the orchestrator's REAL helpers) --
    function _deployForTest() internal returns (Deployed memory d) {
        TokenCfg[3] memory cfg = _cfg();
        address deployer = address(this);
        address keeper = makeAddr("keeper");

        d.govSafe = makeAddr("govSafe");
        d.timelock = payable(makeAddr("timelock"));
        d.pgSafe = makeAddr("pgSafe");
        d.freshGovernance = true;

        // Tokens.
        for (uint256 i = 0; i < 3; i++) {
            MintableERC20 t = new MintableERC20(cfg[i].name, cfg[i].symbol, cfg[i].decimals, deployer);
            t.mint(deployer, cfg[i].seedAmount * 2);
            d.token[i] = address(t);
        }

        // Adapters (writer=deployer to seed, then setWriter(keeper)) — mirrors _buildAdapters.
        for (uint256 i = 0; i < 3; i++) {
            MockOracleAdapterV2Settable a = new MockOracleAdapterV2Settable(deployer, deployer);
            a.setPrice(d.token[i], cfg[i].pegPrice1e18, true);
            a.setWriter(keeper);
            d.adapter[i] = address(a);
        }

        // Registry + list (drives the REAL _defaultBands listing decision).
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
        for (uint256 i = 0; i < 3; i++) {
            MintableERC20(d.token[i]).approve(address(d.pool), cfg[i].seedAmount);
            d.pool.deposit(d.token[i], cfg[i].seedAmount, 0, block.timestamp + 1 days);
        }

        // Handoffs (adapter writer set BACK to deployer so this test can drive drills;
        // in the real deploy the keeper EOA is the writer — the admin handoff is identical).
        for (uint256 i = 0; i < 3; i++) {
            MockOracleAdapterV2Settable(d.adapter[i]).setWriter(deployer); // test-only: regain push for drills
            MockOracleAdapterV2Settable(d.adapter[i]).transferOwnership(d.govSafe);
        }
        d.registry.transferOwnership(d.timelock);
        d.pool.transferOwnership(d.timelock);
    }

    function test_deploy_shape_invariants() public {
        Deployed memory d = _deployForTest();
        assertEq(d.registry.pool(), address(d.pool), "Registry.pool");
        assertEq(d.pool.pauseGuardian(), d.pgSafe, "pauseGuardian");
        assertEq(d.pool.pendingOwner(), d.timelock, "Pool pending owner");
        assertEq(d.registry.pendingOwner(), d.timelock, "Registry pending owner");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(MockOracleAdapterV2Settable(d.adapter[i]).pendingOwner(), d.govSafe, "adapter admin pending owner");
            assertTrue(d.registry.isActive(d.token[i]), "token active");
        }
        assertGt(d.pool.totalReservesUSD(), 0, "NAV seeded");
    }

    // -- §11 oracle-failure: flip an adapter unsafe -> swaps into it revert; proportional exit works --
    function test_drill_oracle_failure() public {
        Deployed memory d = _deployForTest();
        // EURC is token[2]; writer is the deployer (set in _deployForTest for drills).
        MockOracleAdapterV2Settable(d.adapter[2]).setSafe(d.token[2], false);
        (, bool safe) = MockOracleAdapterV2Settable(d.adapter[2]).peekPrice(d.token[2]);
        assertFalse(safe, "EURC must be unsafe after setSafe(false)");
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.OracleUnsafe.selector, d.token[2]));
        d.pool.quoteSwapV2(d.token[0], d.token[2], 1_000_000);
        // Proportional exit still works (no oracle needed). Warp past MIN_HOLD_SECONDS (1h).
        vm.warp(block.timestamp + 2 hours);
        d.pool.withdrawProportional(d.lp.balanceOf(address(this)) / 10, block.timestamp + 1);
    }

    // -- §7 reserve-floor: an over-max swap reverts ReserveFloorBreached; maxSwapOut gives the ceiling --
    // Arc note: USDC/USDT are seeded at EXACTLY their $1,000 minReserveUsd floor (seedAmount 1,000,
    // 6-dec), so their maxSwapOut is 0 (no floor-safe headroom). EURC (token[2]) is seeded 870 @ $1.15
    // = ~$1,000.50, marginally ABOVE its floor, so it is the only token with a non-zero floor-safe
    // ceiling — the meaningful target for this drill. (Base Sepolia seeds 5x the floor; Arc seeds 1x.)
    function test_drill_reserve_floor() public {
        Deployed memory d = _deployForTest();
        (uint256 maxNet,) = d.pool.maxSwapOut(d.token[2]); // EURC out (only token above its floor)
        assertGt(maxNet, 0, "a floor-safe max exists");
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPoolV2.ReserveFloorBreached.selector, d.token[2]));
        d.pool.quoteSwapV2(d.token[0], d.token[2], 1_000_000_000_000); // 1,000,000 USDC in
    }

    // -- §8.3 proportional exit while paused: PG Safe pauses; proportional still works --
    function test_drill_proportional_exit_while_paused() public {
        Deployed memory d = _deployForTest();
        vm.prank(d.pgSafe);
        d.pool.pause();
        assertTrue(d.pool.paused(), "paused");
        vm.warp(block.timestamp + 2 hours);
        d.pool.withdrawProportional(d.lp.balanceOf(address(this)) / 10, block.timestamp + 1);
    }

    // -- §6.2 pause authority: PG Safe pauses; PG Safe CANNOT unpause (owner-only) --
    function test_drill_pause_authority() public {
        Deployed memory d = _deployForTest();
        vm.prank(d.pgSafe);
        d.pool.pause();
        vm.prank(d.pgSafe);
        vm.expectRevert();
        d.pool.unpause();
    }
}
