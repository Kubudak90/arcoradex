// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 }              from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ArcoraDexRegistry }   from "../src/ArcoraDexRegistry.sol";
import { ArcoraDexPool }       from "../src/ArcoraDexPool.sol";
import { ArcoraDexLP }         from "../src/ArcoraDexLP.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";

/// @notice Deploys a fresh ArcoraDexRegistry + ArcoraDexPool (+ auto-deployed LP)
/// for the Phase 2 pause-guardian post-upgrade testnet redeploy. Reuses existing
/// testnet MintableERC20 stables and MockChainlinkFeedV2 feeds — those addresses
/// are hardcoded below from the 2026-05-10 key-separation cutover (verified live
/// on Arc testnet).
///
/// After deploy, the script lists all 7 stables on the new Registry with their
/// per-token deviation caps + maxStaleSeconds, then bootstraps ~$100 USD-equivalent
/// of each stable from the deployer's existing balances (TRYC reduced because the
/// deployer's TRYC balance was partially consumed during the Phase 1 redeploy).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY  — broadcasts; must own the seed token balances
///   ARC_TESTNET_RPC       — RPC URL
///
/// Old (pre-upgrade) testnet contracts are NOT touched by this script:
/// the operator must separately call `pause()` on the old pool and update
/// SDK/frontend addresses to point at the new deployment.
contract DeployArcoraDexV3 is Script {
    // ── Reused token addresses (Arc testnet, listed 2026-05-06) ──────
    address constant USDC  = 0x3BFa09fF6467639f0981948385bA1018Ac07d22C;
    address constant USDT  = 0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B;
    address constant PYUSD = 0xfdB2c86d010698401f0b969348DC58b6659B96a3;
    address constant DAI   = 0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE;
    address constant EURC  = 0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD;
    address constant TRYC  = 0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61;
    address constant BRLC  = 0xa13c0935A98e2c175b31A4054f698819271a8FfC;

    // ── Reused MockChainlinkFeedV2 addresses (deployed 2026-05-10) ────
    address constant FEED_USDC  = 0x2E6B862E1Ac74328238494B22317262004534B39;
    address constant FEED_USDT  = 0x741af784a1d4C69843A1764099433160088a1c70;
    address constant FEED_PYUSD = 0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896;
    address constant FEED_DAI   = 0xAAC5a5855deF9414f7330f350c2E00119C2097c8;
    address constant FEED_EURC  = 0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170;
    address constant FEED_TRYC  = 0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C;
    address constant FEED_BRLC  = 0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d;

    // ── Pool initial parameters ──────────────────────────────────────
    uint16 constant SWAP_FEE_BPS          = 5;     // 0.05%
    uint16 constant PROTOCOL_FEE_SHARE_BPS = 2500;  // 25% of swap fee to protocol (MAX); 75% retained as LP yield

    // ── Bootstrap amounts (~$100 equivalent each, deployer's existing tokens) ──
    // USD stables (6-dec): 100 USDC-units = 100_000_000
    uint256 constant SEED_USDC  = 100_000_000;             // $100
    uint256 constant SEED_USDT  = 100_000_000;             // $100
    uint256 constant SEED_PYUSD = 100_000_000;             // $100
    uint256 constant SEED_DAI   = 100 * 1e18;              // $100 (18-dec)
    // FX stables — divide $100 by approximate USD value:
    uint256 constant SEED_EURC  = 86_000_000;              // ~$100 at $1.16
    uint256 constant SEED_TRYC  = 1_800_000_000;           // ~$41 at $0.023 (deployer balance at P2 deploy time)
    uint256 constant SEED_BRLC  = 516_000_000;             // ~$100 at $0.194

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console2.log("=== Deploying ArcoraDEX v3 (post-Phase-2) ===");
        console2.log("Deployer:", deployer);
        console2.log("");

        vm.startBroadcast(deployerKey);

        // 1. New Registry
        ArcoraDexRegistry reg = new ArcoraDexRegistry(deployer);
        console2.log("Registry:", address(reg));

        // 2. New Pool (which deploys its own LP token)
        ArcoraDexPool pool = new ArcoraDexPool(
            address(reg),
            SWAP_FEE_BPS,
            PROTOCOL_FEE_SHARE_BPS,
            deployer
        );
        ArcoraDexLP lp = ArcoraDexLP(address(pool.LP()));
        console2.log("Pool:    ", address(pool));
        console2.log("LP:      ", address(lp));
        console2.log("");

        // 3. List all 7 stables on the new Registry
        _list(reg, USDC,  6,  FEED_USDC,    50,  3600,  "USDC");
        _list(reg, USDT,  6,  FEED_USDT,    50,  3600,  "USDT");
        _list(reg, PYUSD, 6,  FEED_PYUSD,   50,  3600,  "PYUSD");
        _list(reg, DAI,  18,  FEED_DAI,     50,  3600,  "DAI");
        _list(reg, EURC,  6,  FEED_EURC,   150, 14400,  "EURC");
        _list(reg, TRYC,  6,  FEED_TRYC,  5000, 86400,  "TRYC");
        _list(reg, BRLC,  6,  FEED_BRLC,  5000, 86400,  "BRLC");
        console2.log("");

        // 4. Bootstrap initial liquidity
        _bootstrap(pool, USDC,  SEED_USDC,  "USDC");
        _bootstrap(pool, USDT,  SEED_USDT,  "USDT");
        _bootstrap(pool, PYUSD, SEED_PYUSD, "PYUSD");
        _bootstrap(pool, DAI,   SEED_DAI,   "DAI");
        _bootstrap(pool, EURC,  SEED_EURC,  "EURC");
        _bootstrap(pool, TRYC,  SEED_TRYC,  "TRYC");
        _bootstrap(pool, BRLC,  SEED_BRLC,  "BRLC");

        console2.log("");
        console2.log("=== Final state ===");
        console2.log("LP totalSupply:", lp.totalSupply());
        console2.log("NAV USD (1e18):", pool.totalReservesUSD());

        vm.stopBroadcast();
    }

    function _list(
        ArcoraDexRegistry reg,
        address token,
        uint8   decimals,
        address feed,
        uint16  deviationBps,
        uint32  maxStaleSeconds,
        string memory symbol
    ) internal {
        reg.listToken(token, decimals, IChainlinkAggregator(feed), deviationBps, maxStaleSeconds);
        console2.log(string.concat("Listed ", symbol), token);
    }

    function _bootstrap(
        ArcoraDexPool pool,
        address token,
        uint256 amount,
        string memory symbol
    ) internal {
        IERC20(token).approve(address(pool), amount);
        uint256 lpOut = pool.deposit(token, amount, 0, block.timestamp + 1 days);
        console2.log(string.concat("Deposited ", symbol), amount, "LP:", lpOut);
    }
}
