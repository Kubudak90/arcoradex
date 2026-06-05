// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IArcoraDexPool} from "../src/interfaces/IArcoraDexPool.sol";
import {IArcoraDexRegistry} from "../src/interfaces/IArcoraDexRegistry.sol";

/// @title SweepProtocolFees — sweep ALL accrued protocol fees to the treasury
/// @notice Enumerates every listed token via the Registry and, for each token with
/// a non-zero `protocolFeesAccrued(token)`, calls
/// `ArcoraDexPool.withdrawProtocolFees(token, accrued, TREASURY)` so the entire
/// accrued protocol-fee balance lands in the treasury EOA in a single broadcast.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// WHAT THE TREASURY IS
/// ─────────────────────────────────────────────────────────────────────────────
/// There is NO separate treasury contract. The protocol's "treasury" is simply the
/// `to` address of `withdrawProtocolFees(token, amount, to)`. The operator holds a
/// single user-generated EOA as the treasury; its PRIVATE KEY never reaches this
/// script — only its ADDRESS, supplied at run time via the `TREASURY` env var. This
/// gives accrued protocol fees a dedicated home (closes the wide-audit R7 "fee
/// destination" concern for the deferred-governance testnet).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// OWNER PATH — deployer-owned (this script) vs Timelock-owned (NOT this script)
/// ─────────────────────────────────────────────────────────────────────────────
/// `withdrawProtocolFees` is `onlyOwner` + `whenNotPaused`. The Pool OWNER is
/// whoever currently holds ownership:
///
///   • DEFERRED-GOVERNANCE / DEPLOYER-OWNED Pool (THIS SCRIPT'S PATH).
///     On the freshly-deployed public testnet the Pool is owned by the DEPLOYER
///     until governance is handed off to the Timelock. The broadcaster key here
///     (`SWEEPER_PRIVATE_KEY`, falling back to `DEPLOYER_PRIVATE_KEY`) MUST be that
///     owner EOA. The script asserts `msg.sender == pool.owner()` BEFORE broadcasting
///     so an owner mismatch fails LOUDLY rather than reverting opaquely on-chain.
///
///   • TIMELOCK-OWNED Pool (POST-HANDOFF — DO NOT USE THIS SCRIPT).
///     Once `DeployPublicTestnet`'s governance handoff completes (Pool ownership →
///     `TimelockController`), an EOA can no longer call `withdrawProtocolFees`
///     directly. The sweep must instead be proposed by the Governance Safe as a
///     Timelock batch: for each token with accrued fees, a
///     `pool.withdrawProtocolFees(token, accrued, TREASURY)` call scheduled via
///     `TimelockController.scheduleBatch` (48-hour delay), then `executeBatch`. The
///     `msg.sender == pool.owner()` guard below will revert this script with a clear
///     message in that state — that is intentional. Building the full Timelock-batch
///     path is OUT OF SCOPE here; route through the Gov Safe / Timelock instead.
///
/// `whenNotPaused`: the sweep reverts if the Pool is paused (audit fix I-3 added
/// this gate — admin must not be able to extract fees while users cannot exit). If a
/// sweep is needed during an incident, the owner must `unpause()` first.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// REQUIRED ENV
/// ─────────────────────────────────────────────────────────────────────────────
///   POOL                  — the ArcoraDexPool address (read from env; NOT hardcoded,
///                           so this works against the freshly-deployed testnet Pool).
///   TREASURY              — destination EOA for all swept fees (address only).
///   SWEEPER_PRIVATE_KEY   — broadcaster; MUST be the current Pool owner. Falls back
///     (or DEPLOYER_PRIVATE_KEY)  to DEPLOYER_PRIVATE_KEY when SWEEPER_PRIVATE_KEY is unset
///                           (deferred-governance testnet: the deployer owns the Pool).
///
/// USAGE:
///   POOL=0x... TREASURY=0x... DEPLOYER_PRIVATE_KEY=0x... \
///     forge script script/SweepProtocolFees.s.sol \
///       --rpc-url $ARC_TESTNET_RPC --broadcast
///
/// The Registry is discovered from the Pool itself (`pool.REGISTRY()`); neither the
/// Pool nor the Registry address is hardcoded.
contract SweepProtocolFees is Script {
    /// @notice Emitted-to-console summary of one token's sweep outcome.
    struct SweepResult {
        address token;
        uint256 amount;
        bool swept; // false => skipped (zero accrued)
    }

    function run() external {
        address poolAddr = vm.envAddress("POOL");
        address treasury = vm.envAddress("TREASURY");
        uint256 sweeperKey = _broadcasterKey();

        require(poolAddr != address(0), "SweepProtocolFees: POOL is zero");
        require(treasury != address(0), "SweepProtocolFees: TREASURY is zero");

        IArcoraDexPool pool = IArcoraDexPool(poolAddr);
        address sweeper = vm.addr(sweeperKey);
        address owner = _poolOwner(poolAddr);

        console2.log("=== ArcoraDEX protocol-fee sweep ===");
        console2.log("Pool:     ", poolAddr);
        console2.log("Registry: ", address(pool.REGISTRY()));
        console2.log("Treasury: ", treasury);
        console2.log("Sweeper:  ", sweeper);
        console2.log("Pool owner:", owner);
        console2.log("");

        // Fail LOUDLY before broadcasting if the broadcaster is not the Pool owner.
        // On a Timelock-owned (post-handoff) Pool this message tells the operator to
        // route the sweep through the Governance Safe / Timelock batch instead.
        require(
            sweeper == owner,
            "SweepProtocolFees: broadcaster is NOT the Pool owner. On the deferred-governance testnet use the deployer key; if the Pool is Timelock-owned, route the sweep through a Gov-Safe Timelock batch (see header)."
        );
        require(
            !pool.paused(), "SweepProtocolFees: Pool is paused (whenNotPaused gate, I-3) -- unpause before sweeping"
        );

        vm.startBroadcast(sweeperKey);
        (uint256 tokensSwept, uint256 tokensSkipped) = _sweepAll(pool, treasury, true);
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Sweep complete ===");
        console2.log("Tokens swept:  ", tokensSwept);
        console2.log("Tokens skipped:", tokensSkipped);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core sweep logic — factored into internal helpers so the test can drive the
    // EXACT code path `run()` uses (mirrors the DeployPublicTestnetGaps coupling).
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Enumerate every Registry-listed token and sweep each non-zero
    /// accrued balance to `treasury`. Skips zero-accrued tokens. Returns the
    /// (swept, skipped) token counts.
    /// @param log when false, suppresses console output (used by unit tests).
    /// @dev SINGLE SOURCE OF TRUTH for the sweep: `run()` and the coupling test both
    /// call this. The Registry is read from the Pool (`pool.REGISTRY()`), and tokens
    /// are enumerated via `tokensLength()` + `tokens(i)` exactly as the NAV loop does.
    function _sweepAll(IArcoraDexPool pool, address treasury, bool log)
        internal
        returns (uint256 tokensSwept, uint256 tokensSkipped)
    {
        IArcoraDexRegistry registry = pool.REGISTRY();
        uint256 n = registry.tokensLength();
        for (uint256 i; i < n; ++i) {
            address token = registry.tokens(i);
            SweepResult memory r = _sweepToken(pool, token, treasury, log);
            if (r.swept) {
                ++tokensSwept;
            } else {
                ++tokensSkipped;
            }
        }
    }

    /// @notice Sweep ONE token's accrued protocol fees to `treasury`. Returns a
    /// `SweepResult` describing the outcome (swept + amount, or skipped on zero).
    /// @dev The per-token unit of work. Reads `protocolFeesAccrued(token)`; if it is
    /// non-zero, calls `withdrawProtocolFees(token, accrued, treasury)` (which moves
    /// the full accrued balance and zeroes the accrual). Zero-accrued tokens are
    /// skipped — the Pool would otherwise revert `ZeroAmount`.
    function _sweepToken(IArcoraDexPool pool, address token, address treasury, bool log)
        internal
        returns (SweepResult memory)
    {
        uint256 accrued = pool.protocolFeesAccrued(token);
        if (accrued == 0) {
            if (log) {
                console2.log("  SKIP (zero accrued):", token);
            }
            return SweepResult({token: token, amount: 0, swept: false});
        }
        pool.withdrawProtocolFees(token, accrued, treasury);
        if (log) {
            console2.log("  SWEPT token:", token);
            console2.log("    amount -> treasury:", accrued);
        }
        return SweepResult({token: token, amount: accrued, swept: true});
    }

    // ─────────────────────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Pick the broadcaster key: prefer SWEEPER_PRIVATE_KEY, else fall back to
    /// DEPLOYER_PRIVATE_KEY (deferred-governance testnet: the deployer owns the Pool).
    function _broadcasterKey() internal view returns (uint256) {
        try vm.envUint("SWEEPER_PRIVATE_KEY") returns (uint256 k) {
            return k;
        } catch {
            return vm.envUint("DEPLOYER_PRIVATE_KEY");
        }
    }

    /// @dev Read the Pool's current owner. The Pool is `Ownable2Step`; we only need
    /// the live `owner()` view, declared via a minimal local interface so the script
    /// does not depend on the concrete contract type.
    function _poolOwner(address poolAddr) internal view returns (address) {
        return IOwnable(poolAddr).owner();
    }
}

/// @dev Minimal local view of the Ownable `owner()` accessor the Pool inherits.
interface IOwnable {
    function owner() external view returns (address);
}
