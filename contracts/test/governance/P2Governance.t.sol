// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Safe} from "@safe-global/safe-contracts/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import {Enum} from "@safe-global/safe-contracts/contracts/common/Enum.sol";

import {ArcoraDexPool} from "../../src/ArcoraDexPool.sol";
import {ArcoraDexRegistry} from "../../src/ArcoraDexRegistry.sol";
import {IArcoraDexPool} from "../../src/interfaces/IArcoraDexPool.sol";
import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";
import {MockChainlinkFeedV2} from "../../src/testnet/MockChainlinkFeedV2.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

import {SafeSigHelpers} from "./SafeSigHelpers.sol";

contract P2GovernanceTest is Test {
    using SafeSigHelpers for Safe;

    // Standard Foundry/Hardhat test mnemonic (all BIP-39 valid words).
    // Gives 8 deterministic but throwaway private keys — no mainnet funds.
    string constant MNEMONIC = "test test test test test test test test test test test junk";

    address constant DEPLOYER = address(0xD3);
    uint256 constant TIMELOCK_DELAY = 48 hours;

    // Test signer keys
    uint256[5] govKeys;
    uint256[3] pgKeys;
    address[5] govAddrs;
    address[3] pgAddrs;

    // Deployed contracts
    Safe governanceSafe;
    Safe pauseGuardianSafe;
    TimelockController timelock;
    ArcoraDexRegistry reg;
    ArcoraDexPool pool;
    MockERC20 usdc;
    MockChainlinkFeedV2 fUsdc;

    function setUp() public {
        // Advance past timestamp=1 (OZ TimelockController uses DONE_TIMESTAMP=1;
        // delay=0 at timestamp=1 would set _timestamps[id]=1 which looks Done).
        vm.warp(1_000_000);

        // Derive signers
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i] = vm.deriveKey(MNEMONIC, uint32(i));
            govAddrs[i] = vm.addr(govKeys[i]);
        }
        for (uint256 i = 0; i < 3; i++) {
            pgKeys[i] = vm.deriveKey(MNEMONIC, uint32(5 + i));
            pgAddrs[i] = vm.addr(pgKeys[i]);
        }

        // Deploy Pool + Registry + a test token under DEPLOYER ownership
        vm.startPrank(DEPLOYER);
        reg = new ArcoraDexRegistry(DEPLOYER);
        usdc = new MockERC20("USDC", "USDC", 6);
        fUsdc = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER, 1, type(int256).max, 0, 0);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(fUsdc)), 50, 3600);
        pool = new ArcoraDexPool(address(reg), 5, 2500, DEPLOYER);

        // Seed a tiny bit of liquidity so NAV math has something to chew on
        usdc.mint(DEPLOYER, 100_000_000);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 100_000_000, 0, block.timestamp + 60);
        vm.stopPrank();

        // Deploy Safe singletons + factory
        Safe safeSingleton = new Safe();
        SafeProxyFactory factory = new SafeProxyFactory();

        // Governance Safe (3/5)
        address[] memory govOwners = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            govOwners[i] = govAddrs[i];
        }
        bytes memory govSetup = abi.encodeCall(
            Safe.setup, (govOwners, 3, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        governanceSafe = Safe(payable(address(factory.createProxyWithNonce(address(safeSingleton), govSetup, 1))));

        // Pause Guardian Safe (2/3)
        address[] memory pgOwners = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            pgOwners[i] = pgAddrs[i];
        }
        bytes memory pgSetup = abi.encodeCall(
            Safe.setup, (pgOwners, 2, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        pauseGuardianSafe = Safe(payable(address(factory.createProxyWithNonce(address(safeSingleton), pgSetup, 2))));

        // TimelockController: minDelay = 0 (setup), proposers = [govSafe].
        // L-8 (audit 2026-05-31): executor = Governance Safe (controlled
        // execution), NOT address(0) (open). Mirrors DeployGovernanceP2.s.sol:
        // every scheduled op must be executed by the 3/5 Safe, not a random EOA.
        address[] memory proposers = new address[](1);
        proposers[0] = address(governanceSafe);
        address[] memory executors = new address[](1);
        executors[0] = address(governanceSafe);
        timelock = new TimelockController(0, proposers, executors, address(0));

        // Transfer Pool + Registry ownership to Timelock (in setup mode)
        vm.startPrank(DEPLOYER);
        pool.transferOwnership(address(timelock));
        reg.transferOwnership(address(timelock));
        vm.stopPrank();

        // Timelock executes acceptOwnership on Pool + Registry
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.schedule,
                (address(pool), 0, abi.encodeCall(pool.acceptOwnership, ()), bytes32(0), bytes32(0), 0)
            )
        );
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.execute,
                (address(pool), 0, abi.encodeCall(pool.acceptOwnership, ()), bytes32(0), bytes32(0))
            )
        );
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.schedule,
                (address(reg), 0, abi.encodeCall(reg.acceptOwnership, ()), bytes32(0), bytes32(0), 0)
            )
        );
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.execute,
                (address(reg), 0, abi.encodeCall(reg.acceptOwnership, ()), bytes32(0), bytes32(0))
            )
        );

        // setPauseGuardian
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.schedule,
                (
                    address(pool),
                    0,
                    abi.encodeCall(pool.setPauseGuardian, (address(pauseGuardianSafe))),
                    bytes32(0),
                    bytes32(0),
                    0
                )
            )
        );
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.execute,
                (
                    address(pool),
                    0,
                    abi.encodeCall(pool.setPauseGuardian, (address(pauseGuardianSafe))),
                    bytes32(0),
                    bytes32(0)
                )
            )
        );

        // Lockdown: updateDelay(48h)
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.schedule,
                (
                    address(timelock),
                    0,
                    abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY)),
                    bytes32(0),
                    bytes32(0),
                    0
                )
            )
        );
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.execute,
                (
                    address(timelock),
                    0,
                    abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY)),
                    bytes32(0),
                    bytes32(0)
                )
            )
        );
    }

    /// @dev Calls Safe.execTransaction with the first 3 governance signers (meets the 3/5 threshold).
    function _govExec(address to, bytes memory data) internal {
        uint256[] memory keys = new uint256[](3);
        keys[0] = govKeys[0];
        keys[1] = govKeys[1];
        keys[2] = govKeys[2];
        require(governanceSafe.execCall(to, data, keys), "gov exec failed");
    }

    /// @dev L-8: like _govExec, but asserts the inner call reverts. With
    /// safeTxGas=0 and gasPrice=0, a failed inner call makes Safe.execTransaction
    /// revert with "GS013" (Safe v1.4). Used to pin that a not-yet-ready Timelock
    /// op cannot be executed even via the Safe. Signatures are built BEFORE the
    /// expectRevert so the cheatcode wraps only the final execTransaction call
    /// (the helper's nonce()/getTransactionHash() reads must not consume it).
    function _govExecExpectFail(address to, bytes memory data) internal {
        bytes32 safeTxHash = governanceSafe.getTransactionHash(
            to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), governanceSafe.nonce()
        );
        // Build sorted packed sigs from the first 3 gov signers (3/5 threshold).
        uint256[3] memory keys = [govKeys[0], govKeys[1], govKeys[2]];
        address[3] memory signers;
        bytes[3] memory sigs;
        for (uint256 i = 0; i < 3; i++) {
            signers[i] = vm.addr(keys[i]);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], safeTxHash);
            sigs[i] = abi.encodePacked(r, s, v);
        }
        // Sort by signer address ascending (Safe requires this).
        for (uint256 i = 1; i < 3; i++) {
            for (uint256 j = i; j > 0 && signers[j - 1] > signers[j]; j--) {
                (signers[j - 1], signers[j]) = (signers[j], signers[j - 1]);
                (sigs[j - 1], sigs[j]) = (sigs[j], sigs[j - 1]);
            }
        }
        bytes memory packed = bytes.concat(sigs[0], sigs[1], sigs[2]);

        vm.expectRevert(bytes("GS013"));
        governanceSafe.execTransaction(
            to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), packed
        );
    }

    /// @dev Calls Safe.execTransaction with the first 2 PG signers (meets the 2/3 threshold).
    function _pgExec(address to, bytes memory data) internal {
        uint256[] memory keys = new uint256[](2);
        keys[0] = pgKeys[0];
        keys[1] = pgKeys[1];
        require(pauseGuardianSafe.execCall(to, data, keys), "pg exec failed");
    }

    function test_setup_state_correct() public view {
        assertEq(pool.owner(), address(timelock));
        assertEq(reg.owner(), address(timelock));
        assertEq(pool.pauseGuardian(), address(pauseGuardianSafe));
        assertEq(timelock.getMinDelay(), TIMELOCK_DELAY);
        assertEq(governanceSafe.getThreshold(), 3);
        assertEq(pauseGuardianSafe.getThreshold(), 2);
    }

    function test_governance_proposes_executes_setSwapFeeBps() public {
        uint16 newFee = 10;
        bytes memory call = abi.encodeCall(pool.setSwapFeeBps, (newFee));
        bytes memory execCall =
            abi.encodeCall(TimelockController.execute, (address(pool), 0, call, bytes32(0), bytes32(0)));

        // Schedule via governance
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.schedule, (address(pool), 0, call, bytes32(0), bytes32(0), TIMELOCK_DELAY)
            )
        );

        // L-8: cannot execute before delay — even via the Safe (the op is not
        // ready). _govExecExpectFail asserts the inner Timelock call reverts
        // (Safe.execTransaction returns false / reverts on a failed inner call).
        _govExecExpectFail(address(timelock), execCall);

        // Warp 48h. L-8: execution now routes through the 3/5 Safe (the sole
        // EXECUTOR_ROLE holder), not a bare EOA timelock.execute(...).
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        _govExec(address(timelock), execCall);

        assertEq(pool.swapFeeBps(), newFee);
    }

    function test_pauseGuardian_canPauseInstantly() public {
        assertEq(pool.paused(), false);
        _pgExec(address(pool), abi.encodeCall(pool.pause, ()));
        assertEq(pool.paused(), true);
    }

    function test_pauseGuardian_cannotUnpause() public {
        // Guardian can pause ...
        _pgExec(address(pool), abi.encodeCall(pool.pause, ()));
        assertEq(pool.paused(), true);
        // ... but must NOT be able to unpause — only the owner (Timelock) may restart.
        // A compromised guardian must not be able to un-protect a pool the owner
        // deliberately paused during an incident.
        vm.prank(address(pauseGuardianSafe));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(pauseGuardianSafe)));
        pool.unpause();
    }

    function test_owner_canUnpause() public {
        // Pause via guardian (fast path)
        _pgExec(address(pool), abi.encodeCall(pool.pause, ()));
        assertEq(pool.paused(), true);

        // Owner (Timelock) schedules + executes unpause after delay
        bytes memory unpauseCall = abi.encodeCall(pool.unpause, ());
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.schedule, (address(pool), 0, unpauseCall, bytes32(0), bytes32(0), TIMELOCK_DELAY)
            )
        );
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        // L-8: execute via the Safe (sole EXECUTOR_ROLE holder), not a bare EOA.
        _govExec(
            address(timelock),
            abi.encodeCall(TimelockController.execute, (address(pool), 0, unpauseCall, bytes32(0), bytes32(0)))
        );

        assertEq(pool.paused(), false);
    }

    function test_deployerEOA_cannotPause_post_migration() public {
        vm.prank(DEPLOYER);
        vm.expectRevert();
        pool.pause();
    }

    function test_governance_proposes_executes_setMaxStaleSeconds() public {
        uint32 newStale = 7200;
        bytes memory call = abi.encodeCall(reg.setMaxStaleSeconds, (address(usdc), newStale));

        _govExec(
            address(timelock),
            abi.encodeCall(TimelockController.schedule, (address(reg), 0, call, bytes32(0), bytes32(0), TIMELOCK_DELAY))
        );

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        // L-8: execute via the Safe (sole EXECUTOR_ROLE holder), not a bare EOA.
        _govExec(
            address(timelock),
            abi.encodeCall(TimelockController.execute, (address(reg), 0, call, bytes32(0), bytes32(0)))
        );

        assertEq(reg.tokenInfo(address(usdc)).maxStaleSeconds, newStale);
    }

    /// L-8 (audit 2026-05-31): the executor is now the Governance Safe, NOT the
    /// open role (address(0)). This test pins the closed-executor behaviour that
    /// replaced the old open-executor test (`test_executor_open_anyone_can_execute_after_delay`):
    /// after the delay, a random EOA CANNOT execute (AccessControl revert), but
    /// the 3/5 Safe CAN. This is the intentional liveness/control trade-off:
    /// execution now requires a 3/5 Safe tx.
    function test_executor_closed_onlySafe_can_execute_after_delay() public {
        uint16 newFee = 7;
        bytes memory call = abi.encodeCall(pool.setSwapFeeBps, (newFee));
        bytes memory execCall =
            abi.encodeCall(TimelockController.execute, (address(pool), 0, call, bytes32(0), bytes32(0)));
        _govExec(
            address(timelock),
            abi.encodeCall(
                TimelockController.schedule, (address(pool), 0, call, bytes32(0), bytes32(0), TIMELOCK_DELAY)
            )
        );

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Random non-Safe EOA is NOT an executor — execution must revert even
        // though the op is ready (closed executor; was permitted under the old
        // open-executor model this test replaces). Read EXECUTOR_ROLE() before
        // the prank so the staticcall doesn't consume the prank.
        bytes32 execRole = timelock.EXECUTOR_ROLE();
        bytes memory expectedErr =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", address(0xABCD), execRole);
        vm.prank(address(0xABCD));
        vm.expectRevert(expectedErr);
        timelock.execute(address(pool), 0, call, bytes32(0), bytes32(0));
        assertEq(pool.swapFeeBps(), 5, "fee unchanged: random EOA could not execute");

        // The Governance Safe (sole EXECUTOR_ROLE holder) executes successfully.
        _govExec(address(timelock), execCall);
        assertEq(pool.swapFeeBps(), newFee);
    }
}
