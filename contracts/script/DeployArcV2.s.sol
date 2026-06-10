// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArcoraDexRegistryV2} from "../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexPoolV2} from "../src/v2/ArcoraDexPoolV2.sol";
import {ArcoraDexLPV2} from "../src/v2/ArcoraDexLPV2.sol";
import {IArcoraDexRegistryV2} from "../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "../src/v2/interfaces/IOracleAdapterV2.sol";
import {FeeBandMathV2} from "../src/v2/lib/FeeBandMathV2.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
import {MockOracleAdapterV2Settable} from "../src/v2/testnet/MockOracleAdapterV2Settable.sol";
import {GovernanceFactory} from "./GovernanceFactory.sol";

/// @title DeployArcV2 — turnkey Arc testnet V2 deploy with MOCK oracles
/// @notice Single-broadcast orchestrator for the FRESH ArcoraDEX V2 stack on Arc
/// testnet (chainId 5042002). Arc has NO Pyth and NO real Chainlink, so each token
/// is priced by a deployable keeper-settable MockOracleAdapterV2Settable (seeded at
/// peg, SAFE). Mirrors the proven house style of DeployBaseSepoliaV2/DeployPublicTestnet:
/// pure `_cfg()` source of truth, in-process ledger, `_summary` invariant asserts,
/// `_emitLedger`. The §9 UI is identical to Base because the Pool reads only the
/// (price1e18, safe) tuple from the adapter.
///
/// SEQUENCE:
///   0. chainid guard 5042002
///   1. FRESH governance (GovernanceFactory): Gov Safe 3/5 + PG Safe 2/3 + 48h Timelock.
///      GOV_USE_TEST_MNEMONIC=true ALLOWED on this testnet (factory's mainnet guard intact).
///   2. 3 fresh MintableERC20 test stables (USDC/USDT/EURC, 6-dec); mint seed+faucet headroom.
///   3. 3 MockOracleAdapterV2Settable (writer=deployer to seed, then setWriter(keeper)); seeded SAFE at peg.
///   4. RegistryV2 + list 3 tokens (§7 default bands; conservative low §13-step-5 depositCapUsd).
///   5. Immutable PoolV2 (+ auto-LP) + setPool (I-1) + setPauseGuardian(PG Safe).
///   6. Bootstrap seed deposits (oracles safe by construction; seed-robust skip retained).
///   7. Handoffs: adapters admin -> Gov Safe (pending; writer stays keeper EOA); Registry/Pool -> Timelock (pending).
///   8. Invariant asserts; 9. address-ledger emit.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY — broadcasts; mints + seeds; initial owner/writer before handoff
///   KEEPER_EOA           — the price-pusher address (becomes each adapter's writer)
/// Governance env (FRESH; recommended):
///   GOV_SAFE_OWNERS / GOV_SAFE_THRESHOLD / PG_SAFE_OWNERS / PG_SAFE_THRESHOLD / TIMELOCK_MIN_DELAY
///   (testnet opt-in: GOV_USE_TEST_MNEMONIC=true derives owners from the public Foundry mnemonic)
contract DeployArcV2 is Script {
    uint256 internal constant CHAIN_ID = 5042002;
    uint16 internal constant PROTOCOL_FEE_SHARE_BPS = 1_000; // 10% protocol / 90% LP

    /// @dev Per-token Arc config — the SINGLE source of truth the drift guard +
    /// revalidation test bind to. Fresh 6-dec MintableERC20s priced at peg by the
    /// keeper-settable mock adapter.
    struct TokenCfg {
        string symbol;
        string name;
        uint8 decimals;
        uint256 pegPrice1e18; // 1e18-scaled USD peg the adapter is seeded at
        uint256 minReserveUsd; // 1e18
        uint256 targetReserveUsd; // 1e18
        uint256 depositCapUsd; // 1e18 (conservative §13-step-5 cap)
        uint256 seedAmount; // token-native bootstrap (< cap)
    }

    function _cfg() internal pure returns (TokenCfg[3] memory c) {
        c[0] = TokenCfg({
            symbol: "USDC",
            name: "USD Coin",
            decimals: 6,
            pegPrice1e18: 1e18,
            minReserveUsd: 1_000e18,
            targetReserveUsd: 5_000e18,
            depositCapUsd: 10_000e18,
            seedAmount: 1_000_000_000 // 1,000 USDC (6-dec)
        });
        c[1] = TokenCfg({
            symbol: "USDT",
            name: "Tether USD",
            decimals: 6,
            pegPrice1e18: 1e18,
            minReserveUsd: 1_000e18,
            targetReserveUsd: 5_000e18,
            depositCapUsd: 10_000e18,
            seedAmount: 1_000_000_000 // 1,000 USDT
        });
        c[2] = TokenCfg({
            symbol: "EURC",
            name: "Euro Coin",
            decimals: 6,
            pegPrice1e18: 115e16, // $1.15
            minReserveUsd: 1_000e18,
            targetReserveUsd: 5_000e18,
            depositCapUsd: 10_000e18,
            seedAmount: 870_000_000 // ~1,000 USD at $1.15 (6-dec EURC)
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
        address govSafe;
        address payable timelock;
        address pgSafe;
        bool freshGovernance;
    }

    function run() external {
        require(block.chainid == CHAIN_ID, "DeployArcV2: Arc testnet (5042002) only");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address keeper = vm.envAddress("KEEPER_EOA");
        require(keeper != address(0), "KEEPER_EOA is zero");

        TokenCfg[3] memory cfg = _cfg();
        Deployed memory d;

        console2.log("=== ArcoraDEX V2 Arc testnet turnkey deploy (MOCK oracles) ===");
        console2.log("Deployer:", deployer);
        console2.log("Keeper:  ", keeper);
        console2.log("");

        vm.startBroadcast(deployerKey);

        _deployGovernance(d);
        _deployTokens(d, cfg, deployer);
        _buildAdapters(d, cfg, deployer, keeper);
        _deployRegistryAndList(d, cfg, deployer);
        _deployPool(d, deployer);
        _bootstrap(d, cfg, deployer);
        _handoff(d);

        vm.stopBroadcast();

        _summary(d, cfg);
        _emitLedger(d, cfg);
    }

    // -- Step 1: governance --------------------------------------------------
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

    // -- Step 2: tokens ------------------------------------------------------
    function _deployTokens(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        console2.log("--- Test tokens (fresh MintableERC20) ---");
        for (uint256 i = 0; i < 3; i++) {
            MintableERC20 t = new MintableERC20(cfg[i].name, cfg[i].symbol, cfg[i].decimals, deployer);
            t.mint(deployer, cfg[i].seedAmount * 2); // seed + faucet headroom
            d.token[i] = address(t);
            console2.log(string.concat("  ", cfg[i].symbol, ":"), address(t));
        }
        console2.log("");
    }

    // -- Step 3: adapters (seeded SAFE at peg; writer = keeper after seeding) -
    function _buildAdapters(Deployed memory d, TokenCfg[3] memory cfg, address deployer, address keeper) internal {
        console2.log("--- Mock oracle adapters (seeded SAFE at peg) ---");
        for (uint256 i = 0; i < 3; i++) {
            // writer=deployer so the deploy can seed the peg; rotated to the keeper below.
            MockOracleAdapterV2Settable a = new MockOracleAdapterV2Settable(deployer, deployer);
            a.setPrice(d.token[i], cfg[i].pegPrice1e18, true); // SAFE at peg
            a.setWriter(keeper); // hand the writer role to the keeper EOA
            // N-6: post-deploy verification.
            (uint256 p, bool safe) = a.peekPrice(d.token[i]);
            require(p == cfg[i].pegPrice1e18 && safe, "adapter not seeded safe at peg");
            require(a.writer() == keeper, "adapter writer != keeper");
            d.adapter[i] = address(a);
            console2.log(string.concat("  ", cfg[i].symbol, " adapter:"), address(a));
        }
        console2.log("");
    }

    // -- Step 4: registry + list ---------------------------------------------
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

    // -- Step 5: pool + setPool + guardian ------------------------------------
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

    // -- Step 6: bootstrap (oracles safe by construction; skip-guard retained) -
    function _bootstrap(Deployed memory d, TokenCfg[3] memory cfg, address deployer) internal {
        console2.log("--- Bootstrap deposits ---");
        for (uint256 i = 0; i < 3; i++) {
            (, bool safe) = MockOracleAdapterV2Settable(d.adapter[i]).peekPrice(d.token[i]);
            if (!safe) {
                console2.log(string.concat("  SKIP ", cfg[i].symbol, " (oracle unsafe)"));
                continue;
            }
            IERC20(d.token[i]).approve(address(d.pool), cfg[i].seedAmount);
            uint256 lpOut = d.pool.deposit(d.token[i], cfg[i].seedAmount, 0, block.timestamp + 1 days);
            console2.log(string.concat("  Deposited ", cfg[i].symbol), cfg[i].seedAmount);
            console2.log("    LP minted:", lpOut);
        }
        console2.log("");
    }

    // -- Step 7: ownership handoffs (clean pending state) ---------------------
    function _handoff(Deployed memory d) internal {
        console2.log("--- Handoffs ---");
        for (uint256 i = 0; i < 3; i++) {
            // Adapter admin -> Gov Safe (the §10 retune authority). Writer stays the keeper EOA.
            MockOracleAdapterV2Settable(d.adapter[i]).transferOwnership(d.govSafe);
        }
        d.registry.transferOwnership(d.timelock);
        d.pool.transferOwnership(d.timelock);
        console2.log("  Adapters admin pendingOwner -> Gov Safe (writer stays keeper EOA)");
        console2.log("  Registry/Pool pendingOwner -> Timelock");
        console2.log("");
    }

    // -- Step 8: invariant asserts -------------------------------------------
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
                MockOracleAdapterV2Settable(d.adapter[i]).pendingOwner() == d.govSafe,
                "adapter admin pendingOwner != Gov Safe"
            );
            (uint256 p, bool safe) = MockOracleAdapterV2Settable(d.adapter[i]).peekPrice(d.token[i]);
            require(p == cfg[i].pegPrice1e18 && safe, "adapter not safe at peg");
        }
        require(d.freshGovernance, "governance not fresh");
        console2.log("Registry.pool, pauseGuardian, pending owners, adapters, caps: ok");
        console2.log("NAV USD (1e18):", d.pool.totalReservesUSD());
    }

    // -- Step 9: address ledger ----------------------------------------------
    function _emitLedger(Deployed memory d, TokenCfg[3] memory cfg) internal view {
        console2.log("");
        console2.log("=== ADDRESS LEDGER (capture into ops/arckeeper/.env + the SDK Arc config) ===");
        console2.log("REGISTRY=", address(d.registry));
        console2.log("POOL=", address(d.pool));
        console2.log("LP=", address(d.lp));
        console2.log("GOV_SAFE=", d.govSafe);
        console2.log("PG_SAFE=", d.pgSafe);
        console2.log("TIMELOCK=", d.timelock);
        for (uint256 i = 0; i < 3; i++) {
            console2.log(string.concat("TOKEN_", cfg[i].symbol, "= "), d.token[i]);
            console2.log(string.concat("ADAPTER_", cfg[i].symbol, "= "), d.adapter[i]);
        }
        console2.log("");
        console2.log("NEXT: start the keeper (ops/arckeeper/push-prices-arc.mjs) so adapters stay fresh.");
        console2.log("  Gov Safe schedules+executes Timelock ops calling Registry/Pool.acceptOwnership().");
        console2.log("  Gov Safe calls each adapter.acceptOwnership() directly (Ownable2Step admin).");
    }
}
