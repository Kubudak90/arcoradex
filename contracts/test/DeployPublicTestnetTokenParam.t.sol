// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPublicTestnet} from "../script/DeployPublicTestnet.s.sol";

/// @notice Couples the env-driven TOKEN ADDRESS override of
/// `DeployPublicTestnet.s.sol` to the orchestrator's REAL code.
///
/// DESIGN: inherits `DeployPublicTestnet` so the asserts call the orchestrator's
/// OWN `resolvedTokens()` view helper — the exact resolution `run()` uses to
/// override each `_cfg()[i].token` before listing/bootstrap. The override leaves
/// the per-token economic config (decimals, bands, seeds, divergence caps)
/// untouched: only the `.token` ADDRESS is swapped.
///
/// Branch C (fresh-redeploy): the old tokens' mint authority is lost, so the
/// orchestrator must be able to point at FRESH token addresses via env without
/// disturbing the audited oracle-wiring logic. With NO env set, resolution MUST
/// fall back to the historical hardcoded constants (legacy behavior unchanged).
contract DeployPublicTestnetTokenParamTest is Test, DeployPublicTestnet {
    // Historical hardcoded constants (defaults), in `_cfg()` order.
    address constant DEFAULT_USDC = 0x3BFa09fF6467639f0981948385bA1018Ac07d22C;
    address constant DEFAULT_BRLC = 0xa13c0935A98e2c175b31A4054f698819271a8FfC;

    /// With `TOKEN_USDC` set, `resolvedTokens()[0]` MUST be the fresh address;
    /// the rest fall back to constants.
    function test_tokenAddressesOverrideFromEnv() public {
        address fresh = makeAddr("freshUSDC");
        vm.setEnv("TOKEN_USDC", vm.toString(fresh));

        address[7] memory resolved = resolvedTokens();
        assertEq(resolved[0], fresh, "USDC slot not overridden from TOKEN_USDC env");
        // Untouched slots still resolve to their historical constants.
        assertEq(resolved[6], DEFAULT_BRLC, "BRLC slot must default when its env is unset");
    }

    /// With NO env set, every slot MUST resolve to its historical constant so
    /// legacy behavior is unchanged.
    function test_tokenAddressesDefaultToConstants() public view {
        address[7] memory resolved = resolvedTokens();
        assertEq(resolved[0], DEFAULT_USDC, "USDC slot 0 must default to historical constant");
        assertEq(resolved[6], DEFAULT_BRLC, "BRLC slot 6 must default to historical constant");
    }
}
