// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {ArcoraDexPool} from "../src/ArcoraDexPool.sol";
import {ArcoraDexLP} from "../src/ArcoraDexLP.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {MockChainlinkFeedV2} from "../src/testnet/MockChainlinkFeedV2.sol";
import {OracleAggregator} from "../src/oracle/OracleAggregator.sol";
import {CumulativeDeviationGuard} from "../src/oracle/CumulativeDeviationGuard.sol";
import {GovernanceFactory} from "./GovernanceFactory.sol";

/// @title DeployPublicTestnet — turnkey ArcoraDEX public-testnet (re)deploy
/// @notice Single-execution orchestrator for the FRESH ArcoraDEX redeploy on Arc
/// testnet (chainId 5042002). Runs the full validated sequence in ONE
/// `forge script` broadcast, chaining every freshly-deployed address IN-PROCESS
/// so the operator never hand-scrapes feed/aggregator addresses from broadcast
/// logs between steps. Reuses the existing tokens.
///
/// GOVERNANCE — TWO MODES (M-1 audit fix):
///   - FRESH (default for a real launch): when GOV_SAFE_OWNERS is provided (or
///     the explicit GOV_USE_TEST_MNEMONIC=true opt-in is set), the orchestrator
///     deploys a BRAND-NEW Gov Safe + Pause-Guardian Safe + Timelock from the
///     env-provided owner ADDRESSES (via GovernanceFactory) and wires the fresh
///     oracle layer to the NEW Gov Safe, with the Pool/Registry handoff target =
///     the NEW Timelock. Because the fixed contracts need a fresh deploy anyway,
///     this avoids rotating the old public-mnemonic governance.
///   - REUSE (legacy): when no governance env is set, falls back to the existing
///     public-mnemonic Gov Safe / Timelock constants below (kept for continuity;
///     NOT for a real launch — see M-1).
///
/// This consolidates the previously-manual chain:
///   DeployArcoraDexV3 (Registry/Pool/LP + setPool + list + bootstrap)
///   → MigrateFeedsToV2 (bounded PRIMARY feeds, writer = KEEPER_EOA)
///   → DeployOraclesP3   (secondary feeds + V1 aggregators + guard)
///   → DeployOraclesP3_5 (V2 aggregators)
///   → MigrateSecondaryWriters (secondary writer = KEEPER_SECONDARY)
///   → deployer setOracle re-point of the NEW Registry → P3.5 aggregators
///   → governance handoff (Pool/Registry ownership → existing Timelock).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// TWO CORRECTNESS GAPS CLOSED (these silently broke the wide-audit remediation
/// when the legacy per-step scripts were used for a fresh-Registry redeploy):
///
///  GAP #5 — aggregators MUST read the BOUNDED primary feeds (H-2), not the old
///  UNBOUNDED 2026-05-10 feeds. The legacy DeployOraclesP3 hardcoded the old
///  feeds as `primaryFeed`, and DeployOraclesP3_5 read FEED_* (= old feeds) from
///  env, so the H-2 on-chain bounds were NOT in the live price path. Here, every
///  aggregator's PRIMARY is the bounded MockChainlinkFeedV2 deployed in step 2,
///  threaded in by address (see `_deployBoundedPrimaries` outputs flowing into
///  `_deployP3Layer` and `_deployP3_5Aggregators`).
///
///  GAP #2 — the canonical fresh re-point targets the NEW Registry. The legacy
///  P3_5BatchBuilder hardcoded the LIVE Registry 0x9914…, so a Timelock batch
///  would re-point the OLD live Registry, not the freshly-deployed one. Here the
///  re-point is a deployer `setOracle` on the NEW Registry, executed while the
///  deployer still owns it (before the governance handoff). No Timelock batch is
///  needed for the fresh deploy — the deployer is the Registry owner until step 8.
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Bootstrap freshness: tokens are listed DIRECTLY against the freshly-deployed
/// bounded primary feeds (fresh by construction — `latestUpdatedAt == block.timestamp`),
/// so the first-deposit oracle read can never revert `NoValidPrice` on stale data.
///
/// Seed robustness: each bootstrap seeds `min(targetSeed, deployerBalance)` of the
/// token (SEED_TRYC etc. can exceed the deployer's balance on a real deploy), so
/// the bootstrap never reverts on `ERC20InsufficientBalance`. A token with zero
/// balance is skipped with a loud log line rather than silently aborting the run.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY  — broadcasts; must own the seed token balances + gas
///   KEEPER_EOA            — PRIMARY-feed writer (address, not key)
///   KEEPER_SECONDARY      — SECONDARY-feed writer (address; MUST differ from KEEPER_EOA, H-2)
/// Governance env (FRESH mode — recommended for a real launch, M-1):
///   GOV_SAFE_OWNERS       — comma-separated Gov Safe owner ADDRESSES
///   GOV_SAFE_THRESHOLD    — uint signatures required for the Gov Safe
///   PG_SAFE_OWNERS        — comma-separated Pause-Guardian owner ADDRESSES
///   PG_SAFE_THRESHOLD     — uint signatures required for the PG Safe
///   TIMELOCK_MIN_DELAY    — uint seconds (default 48h = 172800)
///   (testnet-only opt-in: GOV_USE_TEST_MNEMONIC=true derives owners from the
///    public Foundry mnemonic instead — loud warning + mainnet guard.)
///   When NONE of the above governance env is set, the orchestrator falls back to
///   REUSE mode (legacy public-mnemonic Gov Safe / Timelock constants).
/// Optional env:
///   HANDOFF_GOVERNANCE    — if "true", transfer Pool+Registry ownership to the
///                           (fresh or legacy) Timelock so the Gov Safe can accept
///                           (default: leave ownership with the deployer so the
///                           operator can stage the handoff separately). On a fork
///                           the orchestrator's revalidation drives this directly.
contract DeployPublicTestnet is Script {
    // ── Legacy governance (REUSE mode fallback ONLY — see M-1) ───────────────
    // Used only when NO fresh-governance env is supplied. These are the OLD
    // public-mnemonic Gov Safe / Timelock; a real launch MUST use FRESH mode
    // (GOV_SAFE_OWNERS) so these are never wired into a new deployment.
    address constant LEGACY_GOVERNANCE_SAFE = 0x715f669D79Cc72d6685F8724c0B86f7B53d7e624;
    address payable constant LEGACY_TIMELOCK = payable(0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83);

    // ── Pool params (match DeployArcoraDexV3) ────────────────────────────────
    uint16 constant SWAP_FEE_BPS = 5; // 0.05%
    uint16 constant PROTOCOL_FEE_SHARE_BPS = 2500; // 25% protocol / 75% LP

    // ── Oracle layer params ──────────────────────────────────────────────────
    uint32 constant GUARD_WINDOW_SECONDS = 86_400; // 24h tumbling window (P3 Task C)
    uint32 constant AGG_MAX_STALE_SECONDS = 3600; // OracleAggregator per-source staleness (C-2)
    uint8 constant FEED_DECIMALS = 8; // all MockChainlinkFeedV2 oracles report 8-dec

    /// @dev Single source of truth for the 7-token config. Consolidates the
    /// (previously duplicated, audited) values from DeployArcoraDexV3 (decimals,
    /// registry deviation caps, registry maxStale), MigrateFeedsToV2 / DeployOraclesP3
    /// (H-2 on-chain bounds + jump), and DeployOraclesP3 (aggregator divergence,
    /// guard cumulative bps, initial feed price). `initialPrice` is a fresh
    /// within-band 8-dec price used to construct the bounded primary + secondary
    /// feeds (so the bootstrap reads a fresh price on BOTH legs).
    struct TokenCfg {
        string symbol;
        address token;
        uint8 tokenDecimals;
        // Registry listing
        uint16 registryDeviationBps;
        uint32 registryMaxStaleSeconds;
        // Aggregator
        uint16 aggDivergenceBps;
        uint32 guardCumulativeBps;
        // Feed (8-dec) initial price + H-2 on-chain band
        int256 initialPrice;
        int256 minAnswer;
        int256 maxAnswer;
        uint32 maxJumpBps;
        // ~$100-equivalent target seed (token-native units); capped at balance
        uint256 targetSeed;
    }

    function _cfg() internal pure returns (TokenCfg[7] memory c) {
        // USD-pegged: registry dev 50 / stale 3600; agg div 50 / cum 200; band [0.90,1.10] (USDC [0.95,1.05]).
        c[0] = TokenCfg(
            "USDC",
            0x3BFa09fF6467639f0981948385bA1018Ac07d22C,
            6,
            50,
            3600,
            50,
            200,
            100_000_000,
            95_000_000,
            105_000_000,
            300,
            100_000_000
        );
        c[1] = TokenCfg(
            "USDT",
            0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B,
            6,
            50,
            3600,
            50,
            200,
            100_000_000,
            90_000_000,
            110_000_000,
            300,
            100_000_000
        );
        c[2] = TokenCfg(
            "PYUSD",
            0xfdB2c86d010698401f0b969348DC58b6659B96a3,
            6,
            50,
            3600,
            50,
            200,
            100_000_000,
            90_000_000,
            110_000_000,
            300,
            100_000_000
        );
        c[3] = TokenCfg(
            "DAI",
            0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE,
            18,
            50,
            3600,
            50,
            200,
            100_000_000,
            90_000_000,
            110_000_000,
            300,
            100 ether
        );
        // EURC: registry dev 150 / stale 14400; agg div 100 / cum 300; band [0.90,1.40] jump 500.
        c[4] = TokenCfg(
            "EURC",
            0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD,
            6,
            150,
            14_400,
            100,
            300,
            108_000_000,
            90_000_000,
            140_000_000,
            500,
            86_000_000
        );
        // soft-FX: registry dev 200 / stale 86400; agg div 200 / cum 500.
        c[5] = TokenCfg(
            "TRYC",
            0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61,
            6,
            200,
            86_400,
            200,
            500,
            2_900_000,
            500_000,
            15_000_000,
            500,
            1_800_000_000
        );
        c[6] = TokenCfg(
            "BRLC",
            0xa13c0935A98e2c175b31A4054f698819271a8FfC,
            6,
            200,
            86_400,
            200,
            500,
            20_000_000,
            5_000_000,
            40_000_000,
            500,
            516_000_000
        );
    }

    /// @notice Resolve the 7 token ADDRESSES, layering an env-driven override on
    /// top of the audited `_cfg()` constants (Branch C fresh-redeploy). For each
    /// slot i, returns `vm.envOr("TOKEN_<SYM>", <constant>)` where the default is
    /// the historical hardcoded address from `_cfg()`. This ONLY overrides the
    /// `.token` ADDRESS — the per-token economic config (decimals, oracle bands,
    /// seeds, divergence caps) is left intact in `_cfg()`. With NO env set, every
    /// slot resolves to its `_cfg()` constant so legacy behavior is unchanged.
    ///
    /// Kept SEPARATE from the `internal pure` `_cfg()` (which the gap/coupling
    /// tests are bound to) — `run()` applies this override over the `_cfg()`
    /// memory array before any downstream use (listing, bootstrap, etc.).
    /// Symbols/order: [USDC, USDT, PYUSD, DAI, EURC, TRYC, BRLC].
    function resolvedTokens() public view returns (address[7] memory tokens) {
        TokenCfg[7] memory c = _cfg();
        tokens[0] = vm.envOr("TOKEN_USDC", c[0].token);
        tokens[1] = vm.envOr("TOKEN_USDT", c[1].token);
        tokens[2] = vm.envOr("TOKEN_PYUSD", c[2].token);
        tokens[3] = vm.envOr("TOKEN_DAI", c[3].token);
        tokens[4] = vm.envOr("TOKEN_EURC", c[4].token);
        tokens[5] = vm.envOr("TOKEN_TRYC", c[5].token);
        tokens[6] = vm.envOr("TOKEN_BRLC", c[6].token);
    }

    /// @notice The constructor args for ONE token's OracleAggregator, derived
    /// purely from the in-process address ledger + config. This is the single
    /// WIRING DECISION that both the P3 (V1) and P3.5 (V2) aggregator-deploy
    /// steps consume, and that the gap test exercises directly: every aggregator's
    /// PRIMARY MUST be the bounded H-2 feed (GAP #5), its SECONDARY the P3 secondary,
    /// and its divergence cap the per-token `_cfg()` value.
    struct AggWiring {
        address primary; // GAP #5: bounded H-2 feed from step 2
        address secondary; // P3 secondary feed from step 5
        uint16 divergenceBps; // per-token _cfg() divergence cap
        uint32 maxStaleSeconds; // AGG_MAX_STALE_SECONDS
    }

    /// @dev SINGLE SOURCE OF TRUTH for "given the deployed feeds, what does each
    /// aggregator get wired to?". `run()` (via `_deployP3Layer` / `_deployP3_5Aggregators`)
    /// and the coupling test both call this, so a regression in the wiring (e.g.
    /// pointing PRIMARY at an old unbounded feed instead of `boundedPrimary[i]`)
    /// is caught in CI. Pure: takes the resolved feed addresses + config in, no state.
    function _aggWiring(TokenCfg memory c, address boundedPrimary_, address p3Secondary_)
        internal
        pure
        returns (AggWiring memory)
    {
        return AggWiring({
            primary: boundedPrimary_, // GAP #5: bounded feed, NOT the old unbounded one
            secondary: p3Secondary_,
            divergenceBps: c.aggDivergenceBps,
            maxStaleSeconds: AGG_MAX_STALE_SECONDS
        });
    }

    /// @dev SINGLE SOURCE OF TRUTH for the re-point target (GAP #2): the FRESH
    /// Registry deployed in step 1 — NOT the hardcoded LIVE Registry that the
    /// legacy P3_5BatchBuilder used. `run()` (via `_repointRegistry`) and the
    /// coupling test both resolve the target through this helper, so a regression
    /// that re-points the wrong Registry fails CI.
    function _repointTarget(Deployed memory d) internal pure returns (ArcoraDexRegistry) {
        return d.registry;
    }

    // ── In-process address ledger (chained between steps; no log scraping) ───
    struct Deployed {
        ArcoraDexRegistry registry;
        ArcoraDexPool pool;
        ArcoraDexLP lp;
        address[7] boundedPrimary; // step 2: bounded H-2 primary feeds (writer=KEEPER_EOA)
        address[7] p3Secondary; // step 3: secondary feeds (writer migrated to KEEPER_SECONDARY)
        address[7] p3Aggregator; // step 3: V1 aggregators (primary=boundedPrimary)
        CumulativeDeviationGuard guard; // step 3
        address[7] p3_5Aggregator; // step 4: V2 aggregators (primary=boundedPrimary, secondary=p3Secondary)
        // ── Governance targets (M-1): the oracle layer owner (Gov Safe) and the
        // Pool/Registry handoff target (Timelock). In FRESH mode these are the
        // newly-deployed addresses; in REUSE mode they are the LEGACY_* constants.
        address govSafe; // oracle layer ownership target (Gov Safe)
        address payable timelock; // Pool/Registry handoff target (Timelock)
        address pgSafe; // Pause-Guardian Safe (FRESH mode only; address(0) in REUSE)
        bool freshGovernance; // true when a NEW governance stack was deployed here
    }

    function run() external {
        require(block.chainid == 5042002, "DeployPublicTestnet: Arc testnet (fork) only");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address keeperPrimary = vm.envAddress("KEEPER_EOA");
        address keeperSecondary = vm.envAddress("KEEPER_SECONDARY");
        require(keeperPrimary != address(0), "KEEPER_EOA is zero");
        require(keeperSecondary != address(0), "KEEPER_SECONDARY is zero");
        // H-2: the two feed legs MUST use distinct writers, else a single
        // compromised keeper can move both aggregator inputs in lock-step and
        // defeat the two-source divergence check.
        require(keeperSecondary != keeperPrimary, "KEEPER_SECONDARY must differ from KEEPER_EOA (H-2)");

        bool handoff = _envBool("HANDOFF_GOVERNANCE");

        TokenCfg[7] memory cfg = _cfg();
        // Branch C (fresh-redeploy): override ONLY the token ADDRESSES from env
        // (TOKEN_<SYM>), leaving the audited per-token economic config intact.
        // Default (no env) keeps the historical hardcoded `_cfg()` addresses, so
        // legacy behavior is unchanged. Applied here, before any downstream use
        // (listing, bootstrap, re-point), so the entire run targets the resolved
        // tokens.
        address[7] memory tokens = resolvedTokens();
        for (uint256 i = 0; i < 7; i++) {
            cfg[i].token = tokens[i];
        }
        Deployed memory d;

        // M-1: decide governance mode. FRESH when any governance env is supplied
        // (GOV_SAFE_OWNERS or the GOV_USE_TEST_MNEMONIC opt-in); else REUSE legacy.
        bool freshGov = _freshGovernanceRequested();

        console2.log("=== ArcoraDEX public-testnet turnkey (re)deploy ===");
        console2.log("Deployer:        ", deployer);
        console2.log("KEEPER primary:  ", keeperPrimary);
        console2.log("KEEPER secondary:", keeperSecondary);
        console2.log("Governance mode: ", freshGov ? "FRESH (new Gov Safe/Timelock)" : "REUSE (legacy constants)");
        console2.log("");

        vm.startBroadcast(deployerKey);

        // 0. Governance: deploy a FRESH stack (M-1) or resolve the legacy
        //    constants. Sets d.govSafe (oracle layer owner) + d.timelock
        //    (Pool/Registry handoff target). Done FIRST so every downstream
        //    ownership transfer targets the correct governance.
        _resolveGovernance(d, freshGov);

        // 1. Registry + Pool (+ auto-LP) + setPool (I-1 reserve guard).
        _deployCore(d, deployer);

        // 2. Bounded H-2 PRIMARY feeds (writer = KEEPER_EOA, owner = deployer).
        //    Fresh by construction (latestUpdatedAt == block.timestamp).
        _deployBoundedPrimaries(d, cfg, keeperPrimary, deployer);

        // 3. List each token against its BOUNDED primary (so bootstrap reads
        //    a fresh, bounded price — no stale NoValidPrice, no re-point dance).
        _listTokens(d, cfg);

        // 4. Bootstrap initial liquidity (seed = min(target, balance)).
        _bootstrap(d, cfg, deployer);

        // 5. P3 layer: secondary feeds + V1 aggregators (PRIMARY = bounded
        //    primary — GAP #5) + guard. The secondary-feed writer is set to
        //    KEEPER_SECONDARY in-process (distinct from the primary keeper, H-2)
        //    while the deployer still owns the secondaries, THEN ownership of
        //    aggregators/secondaries/guard → Gov Safe (Ownable2Step pending-accept,
        //    matching legacy P3). This obviates the Safe-signature dance of the
        //    legacy MigrateSecondaryWriters.s.sol for a fresh deploy.
        _deployP3Layer(d, cfg, deployer, keeperSecondary);

        // 6. P3.5 V2 aggregators (PRIMARY = bounded primary — GAP #5;
        //    SECONDARY = p3Secondary), owner = Gov Safe directly.
        _deployP3_5Aggregators(d, cfg);

        // 7. Re-point the NEW Registry → P3.5 aggregators via deployer setOracle
        //    (GAP #2 — done while the deployer still owns the new Registry).
        _repointRegistry(d, cfg);

        vm.stopBroadcast();

        // Final summary + invariant asserts on the deployed state.
        _summary(d, cfg, keeperPrimary, keeperSecondary);

        // 8. Optional governance handoff (revalidation drives this on the fork).
        if (handoff) {
            _handoffGovernance(d, deployerKey);
        } else {
            console2.log("");
            console2.log("HANDOFF_GOVERNANCE not set: Pool/Registry remain deployer-owned.");
            console2.log("Stage the handoff separately (transferOwnership -> Timelock; Gov Safe acceptOwnership).");
        }

        // Emit the address ledger so the operator can wire the SDK/keeper/frontend.
        _emitLedger(d, cfg);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 0 — governance resolution (M-1)
    // ─────────────────────────────────────────────────────────────────────────
    /// @notice FRESH mode is requested when ANY governance env is supplied:
    /// GOV_SAFE_OWNERS (the real-owners default) OR the GOV_USE_TEST_MNEMONIC
    /// opt-in. Otherwise the orchestrator stays on the legacy REUSE constants.
    function _freshGovernanceRequested() internal view returns (bool) {
        if (vm.envOr("GOV_USE_TEST_MNEMONIC", false)) return true;
        // GOV_SAFE_OWNERS present (non-empty) => fresh, real-owners mode.
        address[] memory empty = new address[](0);
        address[] memory owners = vm.envOr("GOV_SAFE_OWNERS", ",", empty);
        return owners.length > 0;
    }

    /// @dev Sets d.govSafe (oracle layer owner) and d.timelock (Pool/Registry
    /// handoff target). FRESH: deploys a brand-new Gov Safe + Pause-Guardian Safe
    /// + Timelock from env-provided owner ADDRESSES via GovernanceFactory, wiring
    /// proposer=executor=Gov Safe (L-8), admin=0. The Timelock is deployed at the
    /// final TIMELOCK_MIN_DELAY (the orchestrator does not self-drive the 3/5 Safe,
    /// so there is no setup-delay-0 phase here — see _handoffGovernance for the
    /// 48h-accept timing note). REUSE: resolves the legacy constants.
    /// MUST run inside the deployer's active broadcast.
    function _resolveGovernance(Deployed memory d, bool freshGov) internal {
        if (freshGov) {
            GovernanceFactory.Config memory gcfg = GovernanceFactory.resolveConfig();
            GovernanceFactory.Stack memory s = GovernanceFactory.deploy(gcfg, gcfg.timelockMinDelay);
            d.govSafe = address(s.govSafe);
            d.timelock = payable(address(s.timelock));
            d.pgSafe = address(s.pgSafe);
            d.freshGovernance = true;
            // L-8 sanity: executor is the Gov Safe, NOT address(0); the old
            // public-mnemonic Gov Safe has no role on the fresh Timelock.
            require(s.timelock.hasRole(s.timelock.EXECUTOR_ROLE(), d.govSafe), "fresh Timelock: Gov Safe not executor");
            require(s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), d.govSafe), "fresh Timelock: Gov Safe not proposer");
            console2.log("  Governance Safe (oracle owner):", d.govSafe);
            console2.log("  Timelock (Pool/Registry target):", d.timelock);
            console2.log("");
        } else {
            d.govSafe = LEGACY_GOVERNANCE_SAFE;
            d.timelock = LEGACY_TIMELOCK;
            d.pgSafe = address(0);
            d.freshGovernance = false;
            console2.log("  REUSE legacy Governance Safe:", d.govSafe);
            console2.log("  REUSE legacy Timelock:       ", d.timelock);
            console2.log("");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 1 — core
    // ─────────────────────────────────────────────────────────────────────────
    function _deployCore(Deployed memory d, address deployer) internal {
        d.registry = new ArcoraDexRegistry(deployer);
        d.pool = new ArcoraDexPool(address(d.registry), SWAP_FEE_BPS, PROTOCOL_FEE_SHARE_BPS, deployer);
        d.lp = ArcoraDexLP(address(d.pool.LP()));
        // Wire the I-1 reserve guard while deployer owns the Registry.
        d.registry.setPool(address(d.pool));
        console2.log("Registry:", address(d.registry));
        console2.log("Pool:    ", address(d.pool));
        console2.log("LP:      ", address(d.lp));
        console2.log("Registry.setPool(pool) wired (I-1 reserve guard active)");
        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 2 — bounded H-2 primary feeds
    // ─────────────────────────────────────────────────────────────────────────
    function _deployBoundedPrimaries(Deployed memory d, TokenCfg[7] memory cfg, address keeper, address deployer)
        internal
    {
        console2.log("--- Bounded H-2 PRIMARY feeds (writer = KEEPER primary) ---");
        for (uint256 i = 0; i < 7; i++) {
            MockChainlinkFeedV2 feed = new MockChainlinkFeedV2(
                FEED_DECIMALS,
                cfg[i].initialPrice,
                keeper, // writer = primary keeper
                deployer, // owner = deployer for now; feed ownership is handed to the Gov Safe in a later rotation (see P3 secondaries below, which transferOwnership -> d.govSafe)
                cfg[i].minAnswer,
                cfg[i].maxAnswer,
                cfg[i].maxJumpBps,
                0 // minUpdateSeconds = 0 (keeper cadence, never block a legit re-push)
            );
            require(feed.writer() == keeper, "primary writer != keeper");
            d.boundedPrimary[i] = address(feed);
            console2.log(string.concat("  ", cfg[i].symbol, " primary:"), address(feed));
        }
        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 3 — list tokens against bounded primaries
    // ─────────────────────────────────────────────────────────────────────────
    function _listTokens(Deployed memory d, TokenCfg[7] memory cfg) internal {
        console2.log("--- Listing tokens (oracle = bounded primary feed) ---");
        for (uint256 i = 0; i < 7; i++) {
            d.registry
                .listToken(
                    cfg[i].token,
                    cfg[i].tokenDecimals,
                    IChainlinkAggregator(d.boundedPrimary[i]),
                    cfg[i].registryDeviationBps,
                    cfg[i].registryMaxStaleSeconds
                );
            console2.log(string.concat("  Listed ", cfg[i].symbol), cfg[i].token);
        }
        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 4 — bootstrap (seed-robust)
    // ─────────────────────────────────────────────────────────────────────────
    function _bootstrap(Deployed memory d, TokenCfg[7] memory cfg, address deployer) internal {
        console2.log("--- Bootstrap deposits (seed = min(target, balance)) ---");
        for (uint256 i = 0; i < 7; i++) {
            address token = cfg[i].token;
            uint256 bal = IERC20(token).balanceOf(deployer);
            uint256 amount = bal < cfg[i].targetSeed ? bal : cfg[i].targetSeed;
            if (amount == 0) {
                console2.log(string.concat("  SKIP ", cfg[i].symbol, " (deployer balance is 0)"), token);
                continue;
            }
            if (amount < cfg[i].targetSeed) {
                console2.log(
                    string.concat("  NOTE ", cfg[i].symbol, " seed capped to balance (target was larger):"), amount
                );
            }
            IERC20(token).approve(address(d.pool), amount);
            uint256 lpOut = d.pool.deposit(token, amount, 0, block.timestamp + 1 days);
            console2.log(string.concat("  Deposited ", cfg[i].symbol), amount);
            console2.log("    LP minted:", lpOut);
        }
        console2.log("  NAV USD (1e18):", d.pool.totalReservesUSD());
        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 5 — P3 layer (secondaries + V1 aggregators + guard)
    // ─────────────────────────────────────────────────────────────────────────
    function _deployP3Layer(Deployed memory d, TokenCfg[7] memory cfg, address deployer, address keeperSecondary)
        internal
    {
        console2.log("--- P3 layer: secondary feeds + V1 aggregators + guard ---");
        d.guard = new CumulativeDeviationGuard(deployer);
        console2.log("  Guard:", address(d.guard));

        for (uint256 i = 0; i < 7; i++) {
            // Secondary feed — owner = deployer so we can set the writer below
            // before the ownership handoff. Writer set to KEEPER_SECONDARY (H-2:
            // DISTINCT from the bounded-primary writer KEEPER_EOA).
            MockChainlinkFeedV2 secondary = new MockChainlinkFeedV2(
                FEED_DECIMALS,
                cfg[i].initialPrice,
                deployer, // initial writer; reset to keeperSecondary immediately below
                deployer,
                cfg[i].minAnswer,
                cfg[i].maxAnswer,
                cfg[i].maxJumpBps,
                0
            );
            // H-2: separate the secondary writer in-process (deployer still owner).
            secondary.setWriter(keeperSecondary);
            require(secondary.writer() == keeperSecondary, "secondary writer != KEEPER_SECONDARY");

            // GAP #5: aggregator PRIMARY = the BOUNDED primary feed from step 2,
            // NOT the old unbounded 2026-05-10 feed. Secondary = this fresh feed.
            // The wiring decision is routed through `_aggWiring` (the shared,
            // test-coupled helper) so a regression here fails CI.
            AggWiring memory w = _aggWiring(cfg[i], d.boundedPrimary[i], address(secondary));
            OracleAggregator agg = new OracleAggregator(
                IChainlinkAggregator(w.primary),
                IChainlinkAggregator(w.secondary),
                w.divergenceBps,
                w.maxStaleSeconds,
                deployer
            );

            d.guard.setConfig(cfg[i].token, cfg[i].guardCumulativeBps, GUARD_WINDOW_SECONDS);

            d.p3Secondary[i] = address(secondary);
            d.p3Aggregator[i] = address(agg);
            console2.log(string.concat("  ", cfg[i].symbol, " secondary:"), address(secondary));
            console2.log(string.concat("  ", cfg[i].symbol, " V1 agg:   "), address(agg));

            // Ownership → Gov Safe (Ownable2Step pending-accept), matching legacy P3.
            // M-1: d.govSafe is the FRESH Gov Safe (or the legacy constant in REUSE mode).
            agg.transferOwnership(d.govSafe);
            secondary.transferOwnership(d.govSafe);
        }
        d.guard.transferOwnership(d.govSafe);
        console2.log("  Secondary writers set to KEEPER_SECONDARY (H-2 separation, in-process).");
        console2.log("  P3 ownership transfer (pending Gov Safe acceptance) emitted.");
        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 6 — P3.5 V2 aggregators
    // ─────────────────────────────────────────────────────────────────────────
    function _deployP3_5Aggregators(Deployed memory d, TokenCfg[7] memory cfg) internal {
        console2.log("--- P3.5 V2 aggregators (owner = Gov Safe directly) ---");
        for (uint256 i = 0; i < 7; i++) {
            // GAP #5: PRIMARY = bounded primary (H-2 bounds in the live price path).
            // Wiring routed through the shared, test-coupled `_aggWiring` helper.
            AggWiring memory w = _aggWiring(cfg[i], d.boundedPrimary[i], d.p3Secondary[i]);
            OracleAggregator agg = new OracleAggregator(
                IChainlinkAggregator(w.primary),
                IChainlinkAggregator(w.secondary),
                w.divergenceBps,
                w.maxStaleSeconds,
                d.govSafe // M-1: FRESH Gov Safe (or legacy constant in REUSE mode)
            );
            // N-6: post-deploy constructor verification (catches arg off-by-one).
            require(agg.owner() == d.govSafe, "P3.5: wrong owner");
            require(agg.MAX_STALE_SECONDS() == AGG_MAX_STALE_SECONDS, "P3.5: wrong stale");
            require(agg.maxDivergenceBps() == cfg[i].aggDivergenceBps, "P3.5: wrong div bps");
            require(address(agg.PRIMARY()) == d.boundedPrimary[i], "P3.5: primary != bounded feed (GAP#5)");
            d.p3_5Aggregator[i] = address(agg);
            console2.log(string.concat("  ", cfg[i].symbol, " V2 agg:"), address(agg));
        }
        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 7 — re-point NEW Registry → P3.5 aggregators (GAP #2)
    // ─────────────────────────────────────────────────────────────────────────
    function _repointRegistry(Deployed memory d, TokenCfg[7] memory cfg) internal {
        console2.log("--- Re-point NEW Registry -> P3.5 aggregators (deployer setOracle, GAP #2) ---");
        // GAP #2: target resolved through the shared, test-coupled `_repointTarget`
        // (the FRESH Registry from step 1), NOT the hardcoded live Registry that
        // the legacy P3_5BatchBuilder used.
        ArcoraDexRegistry target = _repointTarget(d);
        for (uint256 i = 0; i < 7; i++) {
            target.setOracle(cfg[i].token, IChainlinkAggregator(d.p3_5Aggregator[i]));
            require(
                address(target.tokenInfo(cfg[i].token).usdOracle) == d.p3_5Aggregator[i],
                "Registry not re-pointed to P3.5 agg"
            );
            console2.log(string.concat("  ", cfg[i].symbol, " usdOracle ->"), d.p3_5Aggregator[i]);
        }
        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Summary + invariant asserts
    // ─────────────────────────────────────────────────────────────────────────
    function _summary(Deployed memory d, TokenCfg[7] memory cfg, address keeperPrimary, address keeperSecondary)
        internal
        view
    {
        console2.log("=== Deployed-state invariants ===");
        // GAP #2: the NEW Registry is the one wired to the pool + aggregators.
        require(d.registry.pool() == address(d.pool), "Registry.pool() != new Pool");
        console2.log("Registry.pool() == new Pool:        ok");

        for (uint256 i = 0; i < 7; i++) {
            // GAP #5: the Registry's oracle resolves through an aggregator whose
            // PRIMARY is the bounded feed.
            OracleAggregator agg = OracleAggregator(address(d.registry.tokenInfo(cfg[i].token).usdOracle));
            require(address(agg) == d.p3_5Aggregator[i], "registry oracle != P3.5 agg");
            require(address(agg.PRIMARY()) == d.boundedPrimary[i], "P3.5 agg primary != bounded feed (GAP#5)");
            require(address(agg.SECONDARY()) == d.p3Secondary[i], "P3.5 agg secondary != p3 secondary");
            // bounded primary's writer = primary keeper.
            require(MockChainlinkFeedV2(d.boundedPrimary[i]).writer() == keeperPrimary, "primary writer != keeper");
            // bounded primary actually enforces bounds (immutables non-trivial).
            require(MockChainlinkFeedV2(d.boundedPrimary[i]).maxAnswer() == cfg[i].maxAnswer, "primary band missing");
            // H-2: writers separated — secondary writer == KEEPER_SECONDARY != primary.
            require(
                MockChainlinkFeedV2(d.p3Secondary[i]).writer() == keeperSecondary,
                "secondary writer != KEEPER_SECONDARY"
            );
            require(keeperSecondary != keeperPrimary, "writers not separated (H-2)");
            // M-1: the P3.5 aggregator (oracle layer) is owned by d.govSafe (the
            // FRESH Gov Safe in FRESH mode), NOT the legacy public-mnemonic Safe.
            require(agg.owner() == d.govSafe, "P3.5 agg owner != resolved Gov Safe (M-1)");
            if (d.freshGovernance) {
                require(d.govSafe != LEGACY_GOVERNANCE_SAFE, "FRESH mode but Gov Safe == legacy (M-1)");
            }
        }
        // M-1: guard ownership pending-accept to d.govSafe (Ownable2Step).
        require(d.guard.pendingOwner() == d.govSafe, "guard pendingOwner != resolved Gov Safe (M-1)");
        console2.log("All 7 registry oracles resolve via P3.5 agg whose PRIMARY == bounded feed: ok (GAP#5)");
        console2.log("Writers separated: primary == KEEPER_EOA, secondary == KEEPER_SECONDARY (H-2): ok");
        console2.log("Oracle layer owner == resolved Gov Safe (M-1): ok");
        console2.log("NAV USD (1e18):", d.pool.totalReservesUSD());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 8 — governance handoff (Pool/Registry ownership → Timelock)
    // ─────────────────────────────────────────────────────────────────────────
    /// @dev Transfers Pool + Registry ownership to d.timelock (the FRESH Timelock
    /// in FRESH mode; the legacy constant in REUSE mode). The Ownable2Step
    /// `acceptOwnership` must be executed by the Timelock itself (it becomes
    /// pendingOwner), which requires a Gov-Safe-scheduled Timelock op. Scheduling/
    /// accept is driven separately (or by the fork revalidation harness) because
    /// it needs the 3/5 Gov Safe signatures; this step only performs the
    /// deployer-side transferOwnership so the run leaves a clean pending state.
    ///
    /// 48h-ACCEPT TIMING: the Gov Safe's acceptOwnership runs THROUGH the
    /// Timelock, so it incurs the configured TIMELOCK_MIN_DELAY (default 48h).
    /// To minimize the wait at launch, the operator can deploy with
    /// TIMELOCK_MIN_DELAY=0, schedule+execute both accepts immediately, then
    /// updateDelay to 48h afterward (the fork harness does exactly this).
    function _handoffGovernance(Deployed memory d, uint256 deployerKey) internal {
        console2.log("");
        console2.log("--- Governance handoff: transferOwnership(Pool, Registry) -> Timelock ---");
        vm.startBroadcast(deployerKey);
        d.pool.transferOwnership(d.timelock);
        d.registry.transferOwnership(d.timelock);
        vm.stopBroadcast();
        console2.log("Pool pendingOwner  -> Timelock:", d.timelock);
        console2.log("Registry pendingOwner -> Timelock:", d.timelock);
        console2.log("NEXT: Gov Safe must schedule+execute Timelock ops calling");
        console2.log("  Pool.acceptOwnership() and Registry.acceptOwnership() (Gov Safe threshold).");
        console2.log("  NOTE: each accept incurs the Timelock delay (48h unless deployed at delay 0).");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Ledger emit (for SDK/keeper/frontend wiring)
    // ─────────────────────────────────────────────────────────────────────────
    function _emitLedger(Deployed memory d, TokenCfg[7] memory cfg) internal view {
        console2.log("");
        console2.log("=== ADDRESS LEDGER (capture for SDK/keeper/frontend) ===");
        console2.log("REGISTRY_V3=", address(d.registry));
        console2.log("POOL_V3=", address(d.pool));
        console2.log("LP_V3=", address(d.lp));
        console2.log("GUARD=", address(d.guard));
        console2.log("GOVERNANCE_SAFE=", d.govSafe);
        console2.log("TIMELOCK=", d.timelock);
        if (d.freshGovernance) {
            console2.log("PAUSE_GUARDIAN_SAFE=", d.pgSafe);
        }
        for (uint256 i = 0; i < 7; i++) {
            console2.log(string.concat("FEED_", cfg[i].symbol, "= "), d.boundedPrimary[i]);
            console2.log(string.concat("P3_SECONDARY_", cfg[i].symbol, "= "), d.p3Secondary[i]);
            console2.log(string.concat("P3_5_AGG_", cfg[i].symbol, "= "), d.p3_5Aggregator[i]);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────────────────────
    function _envBool(string memory name) internal view returns (bool) {
        try vm.envBool(name) returns (bool v) {
            return v;
        } catch {
            return false;
        }
    }
}
