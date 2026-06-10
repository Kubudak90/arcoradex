// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPythAdapterV2} from "../../src/v2/ChainlinkPythAdapterV2.sol";
import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";
import {IPythV2} from "../../src/v2/interfaces/IPythV2.sol";

/// @notice Base-MAINNET fork test against the verified (2026-06-10) feeds. Skips when
/// BASE_MAINNET_RPC is unset so default CI never needs an RPC. Run with:
///   BASE_MAINNET_RPC=<url> forge test --match-path "test/v2/ChainlinkPythAdapterV2.fork.t.sol"
contract ChainlinkPythAdapterV2ForkTest is Test {
    // Verified Base mainnet (8453) Chainlink proxies (8 dec, 86400s heartbeat).
    address constant CL_USDC = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant CL_EURC = 0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250;
    address constant CL_USDT = 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9;
    // Pyth UPGRADED Core (2026-07-31) contract on Base mainnet.
    address constant PYTH = 0xbC16aee60f64864882BC6C4E428e148Fc0E272F5;
    // Verified Pyth feed IDs.
    bytes32 constant PID_USDC = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PID_EURC = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;
    bytes32 constant PID_USDT = 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b;

    address owner = makeAddr("owner");
    address token = makeAddr("token"); // arbitrary — fork test only exercises the read path

    function _maybeFork() internal returns (bool) {
        string memory url = vm.envOr("BASE_MAINNET_RPC", string(""));
        if (bytes(url).length == 0) {
            emit log(unicode"BASE_MAINNET_RPC unset — skipping fork test");
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(url);
        return true;
    }

    function _deploy(address clFeed, bytes32 pid) internal returns (ChainlinkPythAdapterV2) {
        // Wide windows so a live-but-slow feed still reads safe at fork time. Pyth on a
        // bare fork has NO recent pull (publishTime old) → expect Pyth-stale ⇒ unsafe is
        // acceptable; we assert the CHAINLINK leg and normalization, and that read==peek.
        return new ChainlinkPythAdapterV2(
            token,
            IChainlinkAggregator(clFeed),
            IPythV2(PYTH),
            pid,
            90_000, // CL stale window > 24h heartbeat
            type(uint32).max, // Pyth window wide so a stale-on-fork pull doesn't dominate the assertion
            500, // 5% conf cap (loose for fork)
            500, // 5% divergence cap (loose for fork)
            owner
        );
    }

    function _assertLiveStable(address clFeed, bytes32 pid) internal {
        ChainlinkPythAdapterV2 a = _deploy(clFeed, pid);
        (uint256 rp, bool rs) = a.readPrice(token);
        (uint256 pp, bool ps) = a.peekPrice(token);
        assertEq(rp, pp, "O6 peek==read on fork");
        assertEq(rs, ps, "O6 safe parity on fork");
        // Whatever the safe verdict, the returned price must be a plausible ~$1 (or ~$1.15
        // for EURC) 1e18 value when at least one leg answered.
        if (rp > 0) {
            assertGt(rp, 0.5e18, "price sane lower bound");
            assertLt(rp, 2e18, "price sane upper bound");
        }
        emit log_named_uint("price1e18", rp);
        emit log_named_uint("safe", rs ? 1 : 0);
    }

    function test_fork_usdc() public {
        if (!_maybeFork()) return;
        _assertLiveStable(CL_USDC, PID_USDC);
    }

    function test_fork_eurc() public {
        if (!_maybeFork()) return;
        _assertLiveStable(CL_EURC, PID_EURC);
    }

    function test_fork_usdt() public {
        if (!_maybeFork()) return;
        _assertLiveStable(CL_USDT, PID_USDT);
    }
}
