// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockOracleAdapterV2} from "./MockOracleAdapterV2.sol";

contract MockOracleAdapterV2Test is Test {
    MockOracleAdapterV2 adapter;
    address tok = makeAddr("tok");

    function setUp() public {
        adapter = new MockOracleAdapterV2();
    }

    function test_default_isUnsafe() public {
        (uint256 p, bool safe) = adapter.peekPrice(tok);
        assertEq(p, 0);
        assertFalse(safe, "unset token must be unsafe");
    }

    function test_setPrice_makesSafe() public {
        adapter.setPrice(tok, 1e18, true);
        (uint256 p, bool safe) = adapter.peekPrice(tok);
        assertEq(p, 1e18);
        assertTrue(safe);
    }

    function test_setSafe_false_keepsPriceButUnsafe() public {
        adapter.setPrice(tok, 1e18, true);
        adapter.setSafe(tok, false);
        (uint256 p, bool safe) = adapter.peekPrice(tok);
        assertEq(p, 1e18, unicode"last price retained for display (§11)");
        assertFalse(safe, "unsafe gate independent of price");
    }

    function test_readPrice_matchesPeek() public {
        adapter.setPrice(tok, 11e17, true);
        (uint256 rp, bool rs) = adapter.readPrice(tok);
        (uint256 pp, bool ps) = adapter.peekPrice(tok);
        assertEq(rp, pp);
        assertEq(rs, ps);
    }
}
