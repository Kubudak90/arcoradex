// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {P3GovernanceActions} from "../../script/P3GovernanceActions.s.sol";
import {ExecuteP3Batch} from "../../script/ExecuteP3Batch.s.sol";

/// @notice L-7 (audit 2026-05-31): the retired P3 scripts must be un-runnable.
/// Their run() reverts at the first statement (before any env/RPC access), so
/// they can never re-point the live Registry at the superseded V1 aggregators.
/// These tests pin that hard guard.
contract RetiredP3ScriptsTest is Test {
    bytes constant L7_REVERT = bytes("P3 retired - superseded by P3.5; see docs/audits/2026-05-31-wide-audit.md L-7");

    function test_P3GovernanceActions_run_reverts() public {
        P3GovernanceActions s = new P3GovernanceActions();
        vm.expectRevert(L7_REVERT);
        s.run();
    }

    function test_ExecuteP3Batch_run_reverts() public {
        ExecuteP3Batch s = new ExecuteP3Batch();
        vm.expectRevert(L7_REVERT);
        s.run();
    }
}
