// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPublicTestnet} from "../script/DeployPublicTestnet.s.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {OracleAggregator} from "../src/oracle/OracleAggregator.sol";
import {MockChainlinkFeedV2} from "../src/testnet/MockChainlinkFeedV2.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";

/// @notice Couples the two CORRECTNESS gaps + the config fidelity of
/// `DeployPublicTestnet.s.sol` to the orchestrator's REAL code.
///
/// CRITICAL DESIGN: this contract INHERITS `DeployPublicTestnet`, so the asserts
/// below call the orchestrator's OWN `_cfg()`, `_aggWiring(...)`, and
/// `_repointTarget(...)` / `_repointRegistry(...)` — the exact functions `run()`
/// uses. A regression in the orchestrator's wiring decisions or config therefore
/// fails these tests in CI (unlike the prior version, which re-implemented the
/// wiring in `setUp()` and so guarded the PATTERN, not the CODE).
///
/// Verified mutation-coverage (see PR description):
///   - PRIMARY wired to an old/unbounded feed instead of boundedPrimary[i]
///     -> test_gap5_aggWiring_primary_is_bounded_feed FAILS
///   - _repointRegistry targets a hardcoded live Registry instead of the fresh one
///     -> test_gap2_repointRegistry_targets_fresh_registry FAILS
///   - any _cfg() band / deviation / divergence drift from the audited legacy values
///     -> test_drift_cfg_matches_audited_legacy_values FAILS
///
/// GAP #5 — the aggregator the Registry resolves to MUST read the BOUNDED primary
/// feed (H-2 bounds in the live price path), NOT an unbounded feed.
/// GAP #2 — the FRESHLY-deployed Registry is the one re-pointed to the P3.5
/// aggregators; an unrelated (pre-existing/live) Registry is left untouched.
contract DeployPublicTestnetGapsTest is Test, DeployPublicTestnet {
    address constant GOV_SAFE = 0x715f669D79Cc72d6685F8724c0B86f7B53d7e624;

    address keeperPrimary = makeAddr("keeperPrimary");
    address keeperSecondary = makeAddr("keeperSecondary");

    // ── Audited LEGACY values, hardcoded from the deployed-on-chain scripts. ──
    // The drift guard asserts the orchestrator's `_cfg()` equals these token-by-token.
    // A future edit that diverges `_cfg()` from the on-chain params fails CI.
    //
    // Per token (index matches `_cfg()` order: USDC,USDT,PYUSD,DAI,EURC,TRYC,BRLC):
    //   token decimals                         <- DeployArcoraDexV3._list
    //   registry deviationBps / maxStaleSeconds <- DeployArcoraDexV3._list
    //   aggregator divergenceBps               <- DeployOraclesP3 / DeployOraclesP3_5
    //   guard cumulativeBps                    <- DeployOraclesP3
    //   band minAnswer / maxAnswer / maxJumpBps <- MigrateFeedsToV2._bandFor (8-dec)
    //   targetSeed                             <- DeployArcoraDexV3 SEED_*
    struct Legacy {
        address token;
        uint8 tokenDecimals;
        uint16 registryDeviationBps;
        uint32 registryMaxStaleSeconds;
        uint16 aggDivergenceBps;
        uint32 guardCumulativeBps;
        int256 minAnswer;
        int256 maxAnswer;
        uint32 maxJumpBps;
        uint256 targetSeed;
    }

    function _legacy() internal pure returns (Legacy[7] memory L) {
        // USDC — DeployArcoraDexV3: dev 50 / stale 3600; DeployOraclesP3: div 50 / cum 200;
        // MigrateFeedsToV2._bandFor(USDC): [0.95,1.05] jump 300; SEED_USDC = 100e6.
        L[0] = Legacy(0x3BFa09fF6467639f0981948385bA1018Ac07d22C, 6, 50, 3600, 50, 200, 95_000_000, 105_000_000, 300, 100_000_000);
        // USDT — dev 50/3600; div 50/cum 200; _bandFor: [0.90,1.10] jump 300; SEED 100e6.
        L[1] = Legacy(0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B, 6, 50, 3600, 50, 200, 90_000_000, 110_000_000, 300, 100_000_000);
        // PYUSD — dev 50/3600; div 50/cum 200; _bandFor: [0.90,1.10] jump 300; SEED 100e6.
        L[2] = Legacy(0xfdB2c86d010698401f0b969348DC58b6659B96a3, 6, 50, 3600, 50, 200, 90_000_000, 110_000_000, 300, 100_000_000);
        // DAI — dev 50/3600; div 50/cum 200; _bandFor: [0.90,1.10] jump 300; SEED_DAI = 100e18.
        L[3] = Legacy(0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE, 18, 50, 3600, 50, 200, 90_000_000, 110_000_000, 300, 100 ether);
        // EURC — DeployArcoraDexV3: dev 150 / stale 14400; DeployOraclesP3: div 100 / cum 300;
        // _bandFor(EURC): [0.90,1.40] jump 500; SEED_EURC = 86e6.
        L[4] = Legacy(0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD, 6, 150, 14_400, 100, 300, 90_000_000, 140_000_000, 500, 86_000_000);
        // TRYC — dev 200 / stale 86400; div 200 / cum 500; _bandFor(TRYC): [0.005,0.15] jump 500;
        // SEED_TRYC = 1_800_000_000.
        L[5] = Legacy(0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61, 6, 200, 86_400, 200, 500, 500_000, 15_000_000, 500, 1_800_000_000);
        // BRLC — dev 200 / stale 86400; div 200 / cum 500; _bandFor(BRLC): [0.05,0.40] jump 500;
        // SEED_BRLC = 516_000_000.
        L[6] = Legacy(0xa13c0935A98e2c175b31A4054f698819271a8FfC, 6, 200, 86_400, 200, 500, 5_000_000, 40_000_000, 500, 516_000_000);
    }

    // ───────────────────────────────────────────────────────────────────────
    // GAP #5 — aggregator PRIMARY wiring, via the orchestrator's REAL _aggWiring
    // ───────────────────────────────────────────────────────────────────────

    /// The orchestrator's OWN `_aggWiring` MUST set every aggregator's PRIMARY to
    /// the BOUNDED feed passed in (GAP #5), the SECONDARY to the P3 secondary, and
    /// the divergence/stale to the per-token `_cfg()` values. This is the exact
    /// decision `run()` consumes in `_deployP3Layer` / `_deployP3_5Aggregators`,
    /// so re-pointing PRIMARY at an old unbounded feed fails here.
    function test_gap5_aggWiring_primary_is_bounded_feed() public {
        TokenCfg[7] memory cfg = _cfg();
        for (uint256 i = 0; i < 7; i++) {
            address boundedPrimary = makeAddr(string.concat("boundedPrimary", vm.toString(i)));
            address p3Secondary = makeAddr(string.concat("p3Secondary", vm.toString(i)));

            AggWiring memory w = _aggWiring(cfg[i], boundedPrimary, p3Secondary);

            assertEq(w.primary, boundedPrimary, "agg PRIMARY != bounded feed (GAP #5)");
            assertEq(w.secondary, p3Secondary, "agg SECONDARY != p3 secondary");
            assertEq(w.divergenceBps, cfg[i].aggDivergenceBps, "agg divergence != _cfg()");
            assertEq(uint256(w.maxStaleSeconds), uint256(AGG_MAX_STALE_SECONDS), "agg stale != AGG_MAX_STALE_SECONDS");
            // PRIMARY must NEVER equal the SECONDARY, and must equal the bounded leg.
            assertTrue(w.primary != p3Secondary, "PRIMARY collapsed onto SECONDARY");
        }
    }

    /// End-to-end GAP #5 on real OracleAggregator instances built from `_aggWiring`:
    /// the aggregator the orchestrator wires reads the bounded feed, and the H-2
    /// bounds ARE in the live price path (an out-of-band push reverts).
    function test_gap5_bounds_in_live_price_path() public {
        TokenCfg[7] memory cfg = _cfg();
        // USDC (index 0): band [0.95, 1.05] at 8 decimals.
        TokenCfg memory c = cfg[0];

        MockChainlinkFeedV2 boundedPrimary =
            new MockChainlinkFeedV2(FEED_DECIMALS, c.initialPrice, keeperPrimary, address(this), c.minAnswer, c.maxAnswer, c.maxJumpBps, 0);
        MockChainlinkFeedV2 secondary =
            new MockChainlinkFeedV2(FEED_DECIMALS, c.initialPrice, keeperSecondary, address(this), c.minAnswer, c.maxAnswer, c.maxJumpBps, 0);

        AggWiring memory w = _aggWiring(c, address(boundedPrimary), address(secondary));
        OracleAggregator agg = new OracleAggregator(
            IChainlinkAggregator(w.primary),
            IChainlinkAggregator(w.secondary),
            w.divergenceBps,
            w.maxStaleSeconds,
            GOV_SAFE
        );

        assertEq(address(agg.PRIMARY()), address(boundedPrimary), "agg PRIMARY != bounded feed");

        // Bounds enforced on the live PRIMARY: an out-of-band push reverts.
        vm.prank(keeperPrimary);
        vm.expectRevert(
            abi.encodeWithSelector(MockChainlinkFeedV2.AnswerOutOfBounds.selector, int256(200_000_000), c.minAnswer, c.maxAnswer)
        );
        boundedPrimary.setAnswer(200_000_000); // $2.00 — above the 1.05 ceiling

        // control: an in-band push succeeds.
        vm.prank(keeperPrimary);
        boundedPrimary.setAnswer(101_000_000);
        assertEq(boundedPrimary.latestAnswer(), 101_000_000);
    }

    // ───────────────────────────────────────────────────────────────────────
    // GAP #2 — re-point targets the FRESH Registry, via the REAL _repointRegistry
    // ───────────────────────────────────────────────────────────────────────

    /// Exercises the orchestrator's REAL `_repointRegistry` step: builds an
    /// in-process `Deployed` ledger whose `.registry` is a FRESHLY-deployed
    /// Registry, lists mock tokens against bounded primaries, deploys P3.5
    /// aggregators, then calls `_repointRegistry`. Asserts the FRESH registry is
    /// re-pointed to the P3.5 aggregators (GAP #2) and a SEPARATE "live-like"
    /// registry is left untouched. If a regression makes `_repointRegistry` target
    /// a hardcoded (live) Registry, the fresh registry's oracle stays at the
    /// bounded feed and this test fails.
    function test_gap2_repointRegistry_targets_fresh_registry() public {
        address deployer = address(this);

        // Build a mock-token config (real `_cfg()` tokens have no code in a unit
        // test, so listToken's decimals check would revert). We still drive the
        // orchestrator's REAL `_repointRegistry` / `_repointTarget` code.
        TokenCfg[7] memory cfg = _cfg();
        Deployed memory d;
        d.registry = new ArcoraDexRegistry(deployer); // the FRESH registry
        ArcoraDexRegistry liveLike = new ArcoraDexRegistry(deployer); // pre-existing/live stand-in

        for (uint256 i = 0; i < 7; i++) {
            MintableERC20 tok = new MintableERC20("Mock", string.concat("M", vm.toString(i)), 6, deployer);
            cfg[i].token = address(tok);
            cfg[i].tokenDecimals = 6;

            MockChainlinkFeedV2 boundedPrimary =
                new MockChainlinkFeedV2(FEED_DECIMALS, cfg[i].initialPrice, keeperPrimary, deployer, cfg[i].minAnswer, cfg[i].maxAnswer, cfg[i].maxJumpBps, 0);
            MockChainlinkFeedV2 secondary =
                new MockChainlinkFeedV2(FEED_DECIMALS, cfg[i].initialPrice, keeperSecondary, deployer, cfg[i].minAnswer, cfg[i].maxAnswer, cfg[i].maxJumpBps, 0);

            d.boundedPrimary[i] = address(boundedPrimary);
            d.p3Secondary[i] = address(secondary);

            // P3.5 aggregator (PRIMARY = bounded), owner = Gov Safe.
            OracleAggregator agg = new OracleAggregator(
                IChainlinkAggregator(address(boundedPrimary)),
                IChainlinkAggregator(address(secondary)),
                cfg[i].aggDivergenceBps,
                AGG_MAX_STALE_SECONDS,
                GOV_SAFE
            );
            d.p3_5Aggregator[i] = address(agg);

            // List the token on BOTH registries against the bounded primary.
            d.registry.listToken(address(tok), 6, IChainlinkAggregator(address(boundedPrimary)), cfg[i].registryDeviationBps, cfg[i].registryMaxStaleSeconds);
            liveLike.listToken(address(tok), 6, IChainlinkAggregator(address(boundedPrimary)), cfg[i].registryDeviationBps, cfg[i].registryMaxStaleSeconds);
        }

        // The decision the orchestrator uses to pick the re-point target.
        assertEq(address(_repointTarget(d)), address(d.registry), "_repointTarget != fresh registry (GAP #2)");
        assertTrue(address(d.registry) != address(liveLike), "fresh and live-like registry must be distinct");

        // Drive the REAL orchestrator step.
        _repointRegistry(d, cfg);

        for (uint256 i = 0; i < 7; i++) {
            // FRESH registry re-pointed to the P3.5 aggregator.
            assertEq(
                address(d.registry.tokenInfo(cfg[i].token).usdOracle),
                d.p3_5Aggregator[i],
                "fresh registry not re-pointed to P3.5 agg (GAP #2)"
            );
            // The live-like registry is untouched: still the bounded primary.
            assertEq(
                address(liveLike.tokenInfo(cfg[i].token).usdOracle),
                d.boundedPrimary[i],
                "live-like registry must be left untouched (GAP #2)"
            );
        }
    }

    // ───────────────────────────────────────────────────────────────────────
    // Config drift guard — _cfg() must equal the audited legacy values
    // ───────────────────────────────────────────────────────────────────────

    /// Locks the orchestrator's `_cfg()` to the audited, deployed-on-chain params
    /// from the legacy scripts (per-token band min/max + maxJumpBps from
    /// MigrateFeedsToV2._bandFor; regDevBps / staleness / decimals / seed from
    /// DeployArcoraDexV3; aggregator divergence from DeployOraclesP3 /
    /// DeployOraclesP3_5). A future edit that diverges `_cfg()` from the on-chain
    /// values fails CI.
    function test_drift_cfg_matches_audited_legacy_values() public pure {
        TokenCfg[7] memory cfg = _cfg();
        Legacy[7] memory L = _legacy();

        for (uint256 i = 0; i < 7; i++) {
            string memory sym = cfg[i].symbol;
            assertEq(cfg[i].token, L[i].token, string.concat(sym, ": token drift"));
            assertEq(uint256(cfg[i].tokenDecimals), uint256(L[i].tokenDecimals), string.concat(sym, ": decimals drift (DeployArcoraDexV3)"));
            assertEq(uint256(cfg[i].registryDeviationBps), uint256(L[i].registryDeviationBps), string.concat(sym, ": registry deviationBps drift (DeployArcoraDexV3)"));
            assertEq(uint256(cfg[i].registryMaxStaleSeconds), uint256(L[i].registryMaxStaleSeconds), string.concat(sym, ": registry maxStaleSeconds drift (DeployArcoraDexV3)"));
            assertEq(uint256(cfg[i].aggDivergenceBps), uint256(L[i].aggDivergenceBps), string.concat(sym, ": aggregator divergenceBps drift (DeployOraclesP3/P3_5)"));
            assertEq(uint256(cfg[i].guardCumulativeBps), uint256(L[i].guardCumulativeBps), string.concat(sym, ": guard cumulativeBps drift (DeployOraclesP3)"));
            assertEq(cfg[i].minAnswer, L[i].minAnswer, string.concat(sym, ": band minAnswer drift (MigrateFeedsToV2._bandFor)"));
            assertEq(cfg[i].maxAnswer, L[i].maxAnswer, string.concat(sym, ": band maxAnswer drift (MigrateFeedsToV2._bandFor)"));
            assertEq(uint256(cfg[i].maxJumpBps), uint256(L[i].maxJumpBps), string.concat(sym, ": maxJumpBps drift (MigrateFeedsToV2._bandFor)"));
            assertEq(cfg[i].targetSeed, L[i].targetSeed, string.concat(sym, ": targetSeed drift (DeployArcoraDexV3 SEED_*)"));
            // initialPrice + the band are mutually consistent (within bounds).
            assertTrue(cfg[i].initialPrice >= cfg[i].minAnswer && cfg[i].initialPrice <= cfg[i].maxAnswer, string.concat(sym, ": initialPrice out of band"));
        }
    }

    // ───────────────────────────────────────────────────────────────────────
    // H-2 — the two feed legs use DISTINCT writers (separation preserved)
    // ───────────────────────────────────────────────────────────────────────

    function test_h2_writers_separated() public {
        TokenCfg memory c = _cfg()[0];
        MockChainlinkFeedV2 boundedPrimary =
            new MockChainlinkFeedV2(FEED_DECIMALS, c.initialPrice, keeperPrimary, address(this), c.minAnswer, c.maxAnswer, c.maxJumpBps, 0);
        MockChainlinkFeedV2 secondary =
            new MockChainlinkFeedV2(FEED_DECIMALS, c.initialPrice, keeperSecondary, address(this), c.minAnswer, c.maxAnswer, c.maxJumpBps, 0);
        assertEq(boundedPrimary.writer(), keeperPrimary, "primary writer");
        assertEq(secondary.writer(), keeperSecondary, "secondary writer");
        assertTrue(keeperPrimary != keeperSecondary, "writers not separated");
    }
}
