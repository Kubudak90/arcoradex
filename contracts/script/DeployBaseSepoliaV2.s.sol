// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArcoraDexRegistryV2} from "../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexPoolV2} from "../src/v2/ArcoraDexPoolV2.sol";
import {ArcoraDexLPV2} from "../src/v2/ArcoraDexLPV2.sol";
import {ChainlinkPythAdapterV2} from "../src/v2/ChainlinkPythAdapterV2.sol";
import {IArcoraDexRegistryV2} from "../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "../src/v2/interfaces/IOracleAdapterV2.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {IPythV2} from "../src/v2/interfaces/IPythV2.sol";
import {FeeBandMathV2} from "../src/v2/lib/FeeBandMathV2.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
import {MockChainlinkFeed} from "../src/testnet/MockChainlinkFeed.sol";
import {GovernanceFactory} from "./GovernanceFactory.sol";

/// @title DeployBaseSepoliaV2 — turnkey Base Sepolia V2 (re)deploy + drills bootstrap
/// @notice Single-broadcast orchestrator for the FRESH ArcoraDEX V2 stack on Base
/// Sepolia (chainId 84532), the spec §13-step-1/2 testnet deploy. Chains every
/// freshly-deployed address through an in-process ledger so the operator never
/// scrapes addresses from broadcast logs. Mirrors the proven house style of
/// DeployPublicTestnet.s.sol: pure `_cfg()` source of truth, `_summary` invariant
/// asserts, `_emitLedger`.
///
/// SEQUENCE:
///   0. chainid guard 84532
///   1. FRESH governance (GovernanceFactory): Gov Safe 3/5 + PG Safe 2/3 + 48h Timelock.
///      GOV_USE_TEST_MNEMONIC=true is ALLOWED on this testnet (factory's mainnet guard intact).
///   2. 3 fresh MintableERC20 test stables (USDC/USDT/EURC, 6-dec); mint seed+faucet headroom.
///   3. 3 ChainlinkPythAdapterV2 (Sepolia table values). EURC's Chainlink leg does NOT exist on
///      Sepolia -> an in-process MockChainlinkFeed(8, $1.15) is its CL leg (TESTNET-ONLY).
///   4. RegistryV2 + list 3 tokens (§7 default bands; conservative low §13-step-5 depositCapUsd).
///   5. Immutable PoolV2 (+ auto-LP) + setPool (I-1) + setPauseGuardian(PG Safe).
///   6. Bootstrap seed deposits (seed-robust: skip a token whose oracle is unsafe at deploy).
///   7. Handoffs: adapters -> Gov Safe (pending); Registry/Pool -> Timelock (pending). The EURC
///      mock CL feed stays DEPLOYER-owned so the §13 oracle-failure/divergence drills can flip it.
///   8. Invariant asserts; 9. address-ledger emit.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY — broadcasts; mints + seeds; initial owner before handoff
/// Governance env (FRESH; recommended):
///   GOV_SAFE_OWNERS / GOV_SAFE_THRESHOLD / PG_SAFE_OWNERS / PG_SAFE_THRESHOLD / TIMELOCK_MIN_DELAY
///   (testnet opt-in: GOV_USE_TEST_MNEMONIC=true derives owners from the public Foundry mnemonic)
/// Pre-deploy: the keeper MUST pull Pyth fresh for all 3 IDs in the same session (else bootstrap
///   skips unsafe tokens). See ops/basekeeper/update-pyth-base-sepolia.mjs.
contract DeployBaseSepoliaV2 is Script {
    uint256 internal constant CHAIN_ID = 84532;
    // UPGRADED (2026-07-31) Pyth Core on Base Sepolia. See the oracle-adapters plan table.
    // This becomes the live VAA-accepting receiver only AFTER the 2026-07-31 upgrade.
    address internal constant PYTH_SEPOLIA = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83;
    // CURRENT (pre-2026-07-31) live Pyth Core receiver on Base Sepolia. The upgraded
    // address above returns getUpdateFee==0 and reverts InvalidWormholeVaa() until the
    // DAO upgrade lands, so a deploy BEFORE 2026-07-31 must point adapters here. Override
    // with env `PYTH_SEPOLIA`; default stays the upgraded address for post-upgrade deploys.
    address internal constant PYTH_SEPOLIA_CURRENT = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;

    /// @dev Resolve the Pyth receiver: env `PYTH_SEPOLIA` override (set it to
    /// PYTH_SEPOLIA_CURRENT for a pre-upgrade deploy) else the upgraded default.
    function _pyth() internal view returns (address) {
        return vm.envOr("PYTH_SEPOLIA", PYTH_SEPOLIA);
    }
    uint16 internal constant PROTOCOL_FEE_SHARE_BPS = 1_000; // 10% protocol / 90% LP

    /// @dev Per-token Base Sepolia config — the SINGLE source of truth the drift
    /// guard + revalidation test bind to. `chainlinkFeed == address(0)` is the EURC
    /// sentinel: deploy an in-process MockChainlinkFeed(8, eurcMockAnswer) as its CL leg.
    struct TokenCfg {
        string symbol;
        string name;
        uint8 decimals;
        address chainlinkFeed; // real Sepolia proxy; address(0) => deploy EURC mock leg
        int256 eurcMockAnswer; // EURC mock CL answer (8-dec); 0 for non-mock tokens
        bytes32 pythPriceId;
        uint32 chainlinkMaxStaleSeconds;
        uint32 pythMaxStaleSeconds;
        uint16 pythMaxConfBps;
        uint16 maxDivergenceBps;
        uint256 minReserveUsd; // 1e18
        uint256 targetReserveUsd; // 1e18
        uint256 depositCapUsd; // 1e18 (conservative §13-step-5 cap)
        uint256 seedAmount; // token-native bootstrap: 5x minReserveUsd (~target, < cap)
        // so a LIVE deploy lands ABOVE the protected floor — maxSwapOut > 0 and the
        // §13 drills are runnable from genesis, before any external deposits.
    }

    function _cfg() internal pure returns (TokenCfg[3] memory c) {
        // USDC — real Sepolia CL proxy; 30d window (observed ~8d stale).
        c[0] = TokenCfg({
            symbol: "USDC",
            name: "USD Coin",
            decimals: 6,
            chainlinkFeed: 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165,
            eurcMockAnswer: 0,
            pythPriceId: 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a,
            chainlinkMaxStaleSeconds: 2_592_000,
            pythMaxStaleSeconds: 86_400,
            pythMaxConfBps: 30,
            maxDivergenceBps: 50,
            minReserveUsd: 1_000e18,
            targetReserveUsd: 5_000e18,
            depositCapUsd: 10_000e18, // conservative §13-step-5 cap
            seedAmount: 5_000_000_000 // 5,000 USDC (6-dec) — 5x the $1,000 floor (= target)
        });
        // USDT — real Sepolia CL proxy; 7d window (fresh feed).
        c[1] = TokenCfg({
            symbol: "USDT",
            name: "Tether USD",
            decimals: 6,
            chainlinkFeed: 0x3ec8593F930EA45ea58c968260e6e9FF53FC934f,
            eurcMockAnswer: 0,
            pythPriceId: 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b,
            chainlinkMaxStaleSeconds: 604_800,
            pythMaxStaleSeconds: 86_400,
            pythMaxConfBps: 30,
            maxDivergenceBps: 50,
            minReserveUsd: 1_000e18,
            targetReserveUsd: 5_000e18,
            depositCapUsd: 10_000e18,
            seedAmount: 5_000_000_000 // 5,000 USDT — 5x the $1,000 floor (= target)
        });
        // EURC — NO Sepolia CL proxy: address(0) sentinel -> in-process MockChainlinkFeed(8,$1.15).
        c[2] = TokenCfg({
            symbol: "EURC",
            name: "Euro Coin",
            decimals: 6,
            chainlinkFeed: address(0),
            eurcMockAnswer: 115_000_000, // $1.15 at 8 dec
            pythPriceId: 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c,
            chainlinkMaxStaleSeconds: 604_800,
            pythMaxStaleSeconds: 86_400,
            pythMaxConfBps: 40,
            maxDivergenceBps: 60,
            minReserveUsd: 1_000e18,
            targetReserveUsd: 5_000e18,
            depositCapUsd: 10_000e18,
            seedAmount: 4_350_000_000 // ~5,000 USD at $1.15 (6-dec EURC) — 5x the floor
        });
    }

    /// @dev §7 default 4-band schedule, identical to V2Fixture._defaultBands.
    function _defaultBands() internal pure returns (FeeBandMathV2.Band[] memory b) {
        b = new FeeBandMathV2.Band[](4);
        b[0] = FeeBandMathV2.Band({upperHealthBps: 10_000, rateBps: 5});
        b[1] = FeeBandMathV2.Band({upperHealthBps: 7_500, rateBps: 20});
        b[2] = FeeBandMathV2.Band({upperHealthBps: 5_000, rateBps: 75});
        b[3] = FeeBandMathV2.Band({upperHealthBps: 2_500, rateBps: 300});
    }

    struct Deployed {
        ArcoraDexRegistryV2 registry;
        ArcoraDexPoolV2 pool;
        ArcoraDexLPV2 lp;
        address[3] token;
        address[3] adapter;
        address[3] chainlinkLeg; // real proxy or the deployed EURC mock
        address govSafe;
        address payable timelock;
        address pgSafe;
        bool freshGovernance;
    }

    function run() external {
        require(block.chainid == CHAIN_ID, "DeployBaseSepoliaV2: Base Sepolia (84532) only");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        TokenCfg[3] memory cfg = _cfg();
        Deployed memory d;

        console2.log("=== ArcoraDEX V2 Base Sepolia turnkey deploy ===");
        console2.log("Deployer:", deployer);
        console2.log("");

        vm.startBroadcast(deployerKey);

        _deployGovernance(d);
        _deployTokens(d, cfg, deployer);
        _buildAdapters(d, cfg, deployer);
        _deployRegistryAndList(d, cfg, deployer);
        _deployPool(d, deployer);
        _bootstrap(d, cfg, deployer);
        _handoff(d);

        vm.stopBroadcast();

        _summary(d, cfg);
        _emitLedger(d, cfg);
    }

    // ── Step 1: governance ───────────────────────────────────────────────
    function _deployGovernance(Deployed memory d) internal {
        GovernanceFactory.Config memory gcfg = GovernanceFactory.resolveConfig();
        GovernanceFactory.Stack memory s = GovernanceFactory.deploy(gcfg, gcfg.timelockMinDelay);
        d.govSafe = address(s.govSafe);
        d.timelock = payable(address(s.timelock));
        d.pgSafe = address(s.pgSafe);
        d.freshGovernance = true;
        require(s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), d.govSafe), "Timelock: Gov Safe not proposer");
        require(s.timelock.hasRole(s.timelock.EXECUTOR_ROLE(), d.govSafe), "Timelock: Gov Safe not executor");
        console2.log("  Gov Safe:", d.govSafe);
        console2.log("  PG Safe: ", d.pgSafe);
        console2.log("  Timelock:", d.timelock);
        console2.log("");
    }

    // ── Step 2: tokens ───────────────────────────────────────────────────
    function _deployTokens(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        console2.log("--- Test tokens ---");
        for (uint256 i = 0; i < 3; i++) {
            MintableERC20 t = new MintableERC20(cfg[i].name, cfg[i].symbol, cfg[i].decimals, deployer);
            // seed + faucet headroom for drills.
            t.mint(deployer, cfg[i].seedAmount * 2);
            d.token[i] = address(t);
            console2.log(string.concat("  ", cfg[i].symbol, ":"), address(t));
        }
        console2.log("");
    }

    // ── Step 3: adapters (EURC mock CL leg in-process) ───────────────────
    function _buildAdapters(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        console2.log("--- Oracle adapters (Sepolia table values) ---");
        for (uint256 i = 0; i < 3; i++) {
            address clLeg = cfg[i].chainlinkFeed;
            if (clLeg == address(0)) {
                // EURC: Sepolia has NO Chainlink EURC -> deploy a mock CL leg (TESTNET-ONLY).
                // owner = msg.sender (deployer) by MockChainlinkFeed's constructor; left
                // deployer-owned so the §13 oracle-failure/divergence drills can flip it.
                MockChainlinkFeed mockCl = new MockChainlinkFeed(8, cfg[i].eurcMockAnswer);
                clLeg = address(mockCl);
                console2.log(string.concat("  ", cfg[i].symbol, " MOCK CL leg ($1.15):"), clLeg);
            }
            d.chainlinkLeg[i] = clLeg;
            address pythAddr = _pyth();
            ChainlinkPythAdapterV2 a = new ChainlinkPythAdapterV2(
                d.token[i],
                IChainlinkAggregator(clLeg),
                IPythV2(pythAddr),
                cfg[i].pythPriceId,
                cfg[i].chainlinkMaxStaleSeconds,
                cfg[i].pythMaxStaleSeconds,
                cfg[i].pythMaxConfBps,
                cfg[i].maxDivergenceBps,
                deployer // owner = deployer until step 7 handoff to Gov Safe
            );
            // N-6: post-deploy constructor verification (catches arg off-by-one).
            require(a.TOKEN() == d.token[i], "adapter TOKEN mismatch");
            require(address(a.PYTH()) == pythAddr, "adapter PYTH mismatch");
            require(a.PYTH_PRICE_ID() == cfg[i].pythPriceId, "adapter price id mismatch");
            require(a.maxDivergenceBps() == cfg[i].maxDivergenceBps, "adapter divergence mismatch");
            d.adapter[i] = address(a);
            console2.log(string.concat("  ", cfg[i].symbol, " adapter:"), address(a));
        }
        console2.log("");
    }

    // ── Step 4: registry + list ──────────────────────────────────────────
    function _deployRegistryAndList(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        d.registry = new ArcoraDexRegistryV2(deployer);
        console2.log("Registry:", address(d.registry));
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
            console2.log(string.concat("  Listed ", cfg[i].symbol), d.token[i]);
        }
        console2.log("");
    }

    // ── Step 5: pool + setPool + guardian ────────────────────────────────
    function _deployPool(Deployed memory d, address deployer) internal {
        d.pool = new ArcoraDexPoolV2(address(d.registry), PROTOCOL_FEE_SHARE_BPS, deployer);
        d.lp = ArcoraDexLPV2(address(d.pool.LP()));
        d.registry.setPool(address(d.pool)); // I-1 reserve guard
        d.pool.setPauseGuardian(d.pgSafe); // §6.2 pause guardian = PG Safe
        console2.log("Pool:", address(d.pool));
        console2.log("LP:  ", address(d.lp));
        console2.log("setPool wired (I-1); pauseGuardian = PG Safe");
        console2.log("");
    }

    // ── Step 6: bootstrap (seed-robust; skip an unsafe token) ────────────
    function _bootstrap(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        console2.log("--- Bootstrap deposits ---");
        for (uint256 i = 0; i < 3; i++) {
            (, bool safe) = ChainlinkPythAdapterV2(d.adapter[i]).peekPrice(d.token[i]);
            if (!safe) {
                console2.log(string.concat("  SKIP ", cfg[i].symbol, " (oracle unsafe; pull Pyth then re-seed)"));
                continue;
            }
            IERC20(d.token[i]).approve(address(d.pool), cfg[i].seedAmount);
            uint256 lpOut = d.pool.deposit(d.token[i], cfg[i].seedAmount, 0, block.timestamp + 1 days);
            console2.log(string.concat("  Deposited ", cfg[i].symbol), cfg[i].seedAmount);
            console2.log("    LP minted:", lpOut);
        }
        console2.log("");
    }

    // ── Step 7: ownership handoffs (clean pending state) ─────────────────
    function _handoff(Deployed memory d) internal {
        console2.log("--- Handoffs ---");
        for (uint256 i = 0; i < 3; i++) {
            // Adapters -> Gov Safe (the §10 safety-param retune authority).
            ChainlinkPythAdapterV2(d.adapter[i]).transferOwnership(d.govSafe);
        }
        // Registry + Pool -> Timelock (pendingOwner; governance accepts via a scheduled op).
        d.registry.transferOwnership(d.timelock);
        d.pool.transferOwnership(d.timelock);
        console2.log("  Adapters pendingOwner -> Gov Safe");
        console2.log("  Registry/Pool pendingOwner -> Timelock");
        console2.log("  EURC mock CL leg stays DEPLOYER-owned (testnet drill control).");
        console2.log("");
    }

    // ── Step 8: invariant asserts ────────────────────────────────────────
    function _summary(Deployed memory d, TokenCfg[3] memory cfg) internal view {
        console2.log("=== Deployed-state invariants ===");
        require(d.registry.pool() == address(d.pool), "Registry.pool() != Pool");
        require(d.pool.pauseGuardian() == d.pgSafe, "pauseGuardian != PG Safe");
        require(d.pool.pendingOwner() == d.timelock, "Pool pendingOwner != Timelock");
        require(d.registry.pendingOwner() == d.timelock, "Registry pendingOwner != Timelock");
        for (uint256 i = 0; i < 3; i++) {
            IArcoraDexRegistryV2.TokenConfigV2 memory tc = d.registry.tokenConfig(d.token[i]);
            require(address(tc.adapter) == d.adapter[i], "registry adapter != deployed adapter");
            require(tc.isActive, "token not active");
            require(tc.depositCapUsd == cfg[i].depositCapUsd, "deposit cap drift");
            require(
                ChainlinkPythAdapterV2(d.adapter[i]).pendingOwner() == d.govSafe, "adapter pendingOwner != Gov Safe"
            );
            require(ChainlinkPythAdapterV2(d.adapter[i]).TOKEN() == d.token[i], "adapter TOKEN != token");
        }
        require(d.freshGovernance, "governance not fresh");
        console2.log("Registry.pool, pauseGuardian, pending owners, adapters, caps: ok");
        // NAV read reverts while ANY active token's oracle is unsafe (e.g. Pyth not yet
        // pulled at deploy time). The bootstrap is seed-robust (skip-not-abort), so the
        // summary must be too — log NAV when readable, else point at the keeper step.
        try d.pool.totalReservesUSD() returns (uint256 nav) {
            console2.log("NAV USD (1e18):", nav);
        } catch {
            console2.log("NAV unreadable (oracle unsafe) - run the Pyth keeper, then seed deposits");
        }
    }

    // ── Step 9: address ledger ───────────────────────────────────────────
    function _emitLedger(Deployed memory d, TokenCfg[3] memory cfg) internal view {
        console2.log("");
        console2.log("=== ADDRESS LEDGER (capture into ops/basekeeper/.env) ===");
        console2.log("REGISTRY=", address(d.registry));
        console2.log("POOL=", address(d.pool));
        console2.log("LP=", address(d.lp));
        console2.log("GOV_SAFE=", d.govSafe);
        console2.log("PG_SAFE=", d.pgSafe);
        console2.log("TIMELOCK=", d.timelock);
        for (uint256 i = 0; i < 3; i++) {
            console2.log(string.concat("TOKEN_", cfg[i].symbol, "= "), d.token[i]);
            console2.log(string.concat("ADAPTER_", cfg[i].symbol, "= "), d.adapter[i]);
            console2.log(string.concat("CL_LEG_", cfg[i].symbol, "= "), d.chainlinkLeg[i]);
        }
        console2.log("");
        console2.log("NEXT: Gov Safe schedules+executes Timelock ops calling");
        console2.log("  Registry.acceptOwnership() and Pool.acceptOwnership() (48h delay).");
        console2.log("  Gov Safe calls each adapter.acceptOwnership() directly (Ownable2Step).");
    }
}
