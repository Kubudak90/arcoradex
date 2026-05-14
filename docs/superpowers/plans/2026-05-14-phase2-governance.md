# Phase 2 — Governance Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate ownership of ArcoraDexPool, ArcoraDexRegistry, and the 7 MockChainlinkFeedV2 instances from the deployer EOA to a Safe 3/5 governance multisig fronted by an OZ `TimelockController` (48h delay), plus a separate Safe 2/3 Pause Guardian that bypasses timelock for emergency pause/unpause. Testnet rehearsal only; mainnet rotation deferred to P5.

**Architecture:** Pool gets a small additive contract change to expose a `pauseGuardian` role (storage + `onlyOwnerOrGuardian` modifier + owner-only setter), forcing a Pool+Registry+LP redeploy. Then a second Forge script deploys the governance stack — `SafeProxyFactory` + 2 Safes + `TimelockController` — and runs all `transferOwnership` calls under a "minDelay = 0" setup mode, locking the Timelock to 48h as the last step.

**Tech Stack:** Solidity 0.8.26, Foundry, OpenZeppelin v5 (`TimelockController`, `Ownable2Step`), Safe v1.4.1 (`SafeProxyFactory`, `Safe` singleton, `CompatibilityFallbackHandler`).

**Spec:** `docs/superpowers/specs/2026-05-14-phase2-governance-design.md`
**Parent roadmap:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §4

---

## File Structure

### Files modified
| File | Changes |
|------|---------|
| `contracts/src/ArcoraDexPool.sol` | Add `pauseGuardian` storage + `onlyOwnerOrGuardian` modifier + `setPauseGuardian` setter; update `pause()` / `unpause()` modifier |
| `contracts/src/interfaces/IArcoraDexPool.sol` | Add `NotAuthorized` error, `PauseGuardianUpdated` event, `pauseGuardian()` view, `setPauseGuardian` declaration |
| `contracts/test/ArcoraDexPool.t.sol` | Add 3 pauseGuardian unit tests |
| `foundry.toml` | Add `@safe-global/safe-contracts/` remapping |

### Files created
| File | Purpose |
|------|---------|
| `contracts/test/governance/SafeSigHelpers.sol` | Helper library: derive signer keys, compute safeTxHash, sign + sort + pack Safe v1.4 signatures |
| `contracts/test/governance/P2Governance.t.sol` | Full-stack dry-run tests: governance proposes → 48h warp → execute; pauseGuardian instant pause/unpause; deployer EOA reverts post-migration |
| `contracts/script/DeployArcoraDexV3.s.sol` | Pool+Registry+LP redeploy with `pauseGuardian` storage; bootstrap ~$700 NAV; reuse existing tokens+feeds from 2026-05-10 cutover |
| `contracts/script/DeployGovernanceP2.s.sol` | Derive 8 test signers; fund 0.1 ARC each; deploy Safe singletons (if missing on Arc) + 2 Safes (3/5 gov, 2/3 guardian) + TimelockController; transferOwnership Pool/Registry → Timelock; transferOwnership 7 feeds → GovernanceSafe; setPauseGuardian; lockdown to 48h |
| `docs/rollouts/2026-05-14-phase2-governance.md` | Live addresses, signer mnemonic, per-action runbook, dry-run results |

### Branches
- `phase2/governance-migration` — already created; planning artifacts (this plan + spec) live here.
- After this PR (planning) merges, implementation work proceeds on new branches per task grouping:
  - `phase2/pool-pause-guardian` (Tasks 2-4: Pool change + tests + dependency)
  - `phase2/governance-deploy-scripts` (Tasks 5-7: helper lib + dry-run tests + deploy scripts)
  - `phase2/testnet-rollout` (Tasks 8-11: broadcast + sanity + rollout doc)

To keep the workflow tractable, this plan describes Tasks 1-12 as if executing on a single `phase2/governance-rollout` branch off main. The implementer may split into multiple PRs at logical boundaries (after Task 4, after Task 7) if review burden grows.

---

### Task 1: Branch setup and baseline verification

**Files:** none modified; verification only.

- [ ] **Step 1: Confirm planning PR has merged to main**

Run:
```bash
git checkout main && git pull --ff-only origin main
git log -1 --format='%h %s'
```
Expected: HEAD commit subject mentions the P2 planning merge (e.g. `docs(plan): phase 2 governance migration ...` or its merge commit).

- [ ] **Step 2: Create the implementation branch**

Run:
```bash
git checkout -b phase2/governance-rollout
```
Expected: clean branch at the same SHA as main.

- [ ] **Step 3: Establish forge test baseline**

Run:
```bash
cd contracts && forge build && forge test 2>&1 | tail -3
```
Expected: `91 tests passed, 0 failed, 0 skipped`. If different, record the actual count as the new baseline.

- [ ] **Step 4: Confirm deployer ARC balance**

Run:
```bash
RPC=https://rpc.testnet.arc.network
cast balance 0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b --rpc-url $RPC --ether
```
Expected: ≥ 1.5 ARC (covers V3 redeploy ~0.4 ARC + governance deploy ~0.5 ARC + 8×0.1 ARC signer funding + safety margin). If below, top up deployer wallet before proceeding.

No commit — Task 1 is verification only.

---

### Task 2: Add Safe contracts dependency

**Files:**
- Modify: `foundry.toml`
- Create: `contracts/lib/safe-contracts/` (via `forge install`)
- Modify: `.gitmodules` (auto-generated)

- [ ] **Step 1: Install Safe contracts**

Run:
```bash
cd contracts && forge install safe-global/safe-contracts@v1.4.1 --no-commit 2>&1 | tail -5
```
Expected: clones into `contracts/lib/safe-contracts`. If `v1.4.1` tag doesn't exist, try `v1.4.1-3` or whatever the latest 1.4.x tag is per `git tag` inside `lib/safe-contracts`.

- [ ] **Step 2: Add remapping to `foundry.toml`**

Open `contracts/foundry.toml`. Locate the `[profile.default]` section (or wherever `remappings` lives — may be in a separate `remappings.txt`).

If `remappings` is in `foundry.toml`:
Add to the array:
```
"@safe-global/safe-contracts/=lib/safe-contracts/",
```

If a separate `remappings.txt` exists, append the line:
```
@safe-global/safe-contracts/=lib/safe-contracts/
```

- [ ] **Step 3: Verify the import resolves**

Create a temporary scratch file `contracts/test/SafeImportSmoke.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { SafeProxyFactory } from "@safe-global/safe-contracts/contracts/proxies/SafeProxyFactory.sol";

contract SafeImportSmoke {
    // intentionally empty — just verifies imports resolve at compile time
}
```

Run:
```bash
cd contracts && forge build 2>&1 | tail -5
```
Expected: `Compiler run successful`. If Safe contracts use a different Solidity pragma (e.g. `^0.7.6`), `foundry.toml` may need `[profile.default]` `via_ir = true` or a Solidity pragma override per file. Most likely the contracts compile cleanly under 0.8.26 since v1.4.1 is multi-pragma.

- [ ] **Step 4: Delete the scratch file**

Run:
```bash
rm contracts/test/SafeImportSmoke.t.sol
```

- [ ] **Step 5: Stage and commit**

Run:
```bash
git add contracts/foundry.toml contracts/remappings.txt contracts/lib/safe-contracts .gitmodules 2>/dev/null || true
git status -s
```
Expected: shows the submodule addition + remapping file change. (If `remappings.txt` doesn't exist, only `foundry.toml` is modified.)

Run:
```bash
git commit -m "$(cat <<'EOF'
chore(deps): add safe-contracts v1.4.1 dependency

P2 governance migration uses Safe multisigs (3/5 governance + 2/3
Pause Guardian) fronted by OZ TimelockController. Adds the
@safe-global/safe-contracts library as a Foundry submodule and the
matching remapping.

Spec: docs/superpowers/specs/2026-05-14-phase2-governance-design.md §3

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Pool `pauseGuardian` role (TDD)

**Files:**
- Modify: `contracts/src/interfaces/IArcoraDexPool.sol`
- Modify: `contracts/src/ArcoraDexPool.sol`
- Modify: `contracts/test/ArcoraDexPool.t.sol`

This is a small, isolated contract change. Three new tests + four code edits + one commit.

- [ ] **Step 1: Write the three new tests (red phase)**

Append to `contracts/test/ArcoraDexPool.t.sol` inside the test contract:

```solidity
    // ── pauseGuardian role (Phase 2) ──
    function test_setPauseGuardian_byOwner_emitsAndStores() public {
        address guardian = address(0xC0DE);
        vm.expectEmit(true, true, false, true);
        emit IArcoraDexPool.PauseGuardianUpdated(address(0), guardian);
        pool.setPauseGuardian(guardian);
        assertEq(pool.pauseGuardian(), guardian);
    }

    function test_setPauseGuardian_byNonOwner_reverts() public {
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert();
        pool.setPauseGuardian(address(0xC0DE));
    }

    function test_pause_byGuardian_succeeds_byThirdParty_reverts() public {
        address guardian = address(0xC0DE);
        address attacker = address(0xBAD);
        pool.setPauseGuardian(guardian);

        // Guardian can pause
        vm.prank(guardian);
        pool.pause();
        assertEq(pool.paused(), true);

        // Guardian can unpause
        vm.prank(guardian);
        pool.unpause();
        assertEq(pool.paused(), false);

        // Random third party cannot
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexPool.NotAuthorized.selector));
        pool.pause();
    }
```

- [ ] **Step 2: Run the new tests, verify they fail to compile**

Run:
```bash
cd contracts && forge build 2>&1 | tail -10
```
Expected: compile failure citing missing `IArcoraDexPool.PauseGuardianUpdated`, `IArcoraDexPool.NotAuthorized`, `pool.pauseGuardian()`, and `pool.setPauseGuardian(...)`. This is the red phase.

- [ ] **Step 3: Extend `IArcoraDexPool` interface**

Edit `contracts/src/interfaces/IArcoraDexPool.sol`. Find the existing error block and add (immediately after the existing errors):
```solidity
    error NotAuthorized();
```

Find the existing events block and add (immediately after the existing events):
```solidity
    event PauseGuardianUpdated(address indexed prev, address indexed next);
```

Find the existing view declarations (near `lastValidPriceAt(address)`) and add:
```solidity
    function pauseGuardian() external view returns (address);
```

Find the function declarations section (near `pause`, `unpause`, `syncAcceptedPrice`) and add:
```solidity
    function setPauseGuardian(address newGuardian) external;
```

- [ ] **Step 4: Extend `ArcoraDexPool` storage + modifier**

Edit `contracts/src/ArcoraDexPool.sol`. In the storage section (after `lastMintAt`), add:
```solidity
    address public override pauseGuardian;
```

In the modifiers section (after `whenNotPaused`), add:
```solidity
    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != pauseGuardian) revert NotAuthorized();
        _;
    }
```

- [ ] **Step 5: Switch `pause()` and `unpause()` to `onlyOwnerOrGuardian`**

Find:
```solidity
    function pause() external override onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }
```
Replace with:
```solidity
    function pause() external override onlyOwnerOrGuardian {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyOwnerOrGuardian {
        paused = false;
        emit Unpaused(msg.sender);
    }
```

- [ ] **Step 6: Add `setPauseGuardian` function**

After `syncAcceptedPrice` (or anywhere in the owner-functions section), add:
```solidity
    function setPauseGuardian(address newGuardian) external override onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        emit PauseGuardianUpdated(pauseGuardian, newGuardian);
        pauseGuardian = newGuardian;
    }
```

- [ ] **Step 7: Recompile and run the new tests**

Run:
```bash
cd contracts && forge build 2>&1 | tail -3
cd contracts && forge test --match-contract ArcoraDexPoolTest --match-test "pauseGuardian|pause_by" -vv 2>&1 | tail -15
```
Expected: build clean, all 3 new tests PASS.

- [ ] **Step 8: Run full test suite**

Run:
```bash
cd contracts && forge test 2>&1 | tail -5
```
Expected: 91 baseline + 3 new = 94 tests passing. No regressions.

- [ ] **Step 9: Commit**

Run:
```bash
git add contracts/src/interfaces/IArcoraDexPool.sol \
        contracts/src/ArcoraDexPool.sol \
        contracts/test/ArcoraDexPool.t.sol
git commit -m "$(cat <<'EOF'
feat(contracts): add pauseGuardian role to ArcoraDexPool

P2 governance migration requires a fast-response pause path that
bypasses the 48h timelock delay. Adds a `pauseGuardian` address slot
and an `onlyOwnerOrGuardian` modifier on `pause()` / `unpause()`.
`setPauseGuardian` is owner-only (gets routed through Timelock after
migration).

Storage layout: new `address public pauseGuardian` slot appended
after `lastMintAt` (slot 10). No collision with existing storage.

Interface additions: `NotAuthorized` error, `PauseGuardianUpdated`
event, `pauseGuardian()` view, `setPauseGuardian(address)`.

3 new tests cover: owner-only setter, owner+guardian pause access,
third-party revert.

Spec: docs/superpowers/specs/2026-05-14-phase2-governance-design.md §4

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Safe signature helper library

**Files:**
- Create: `contracts/test/governance/SafeSigHelpers.sol`

A small Solidity helper used by both the dry-run tests (Task 5) and the deploy script (Task 7) to construct + sign + pack Safe v1.4 transactions.

- [ ] **Step 1: Create the helper library file**

Create `contracts/test/governance/SafeSigHelpers.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { Enum } from "@safe-global/safe-contracts/contracts/libraries/Enum.sol";

/// @notice Helpers for constructing + signing + packing Safe v1.4 transactions
/// in Foundry scripts and tests. Avoids the need to write the signature-encoding
/// boilerplate at every call site.
library SafeSigHelpers {
    /// @dev Forge's deterministic Vm address.
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct SafeTxParams {
        address to;
        uint256 value;
        bytes   data;
        Enum.Operation operation;
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address payable refundReceiver;
    }

    /// @notice Sign + pack signatures from `signerKeys` (sorted by signer address ASC)
    /// and call `safe.execTransaction(...)`.
    /// @param safe         The Safe contract to execute against.
    /// @param p            Transaction parameters.
    /// @param signerKeys   Private keys of the signers (must be >= threshold).
    function signAndExec(Safe safe, SafeTxParams memory p, uint256[] memory signerKeys)
        internal
        returns (bool success)
    {
        uint256 nonce = safe.nonce();
        bytes32 safeTxHash = safe.getTransactionHash(
            p.to, p.value, p.data, p.operation,
            p.safeTxGas, p.baseGas, p.gasPrice, p.gasToken, p.refundReceiver,
            nonce
        );

        // Derive addresses + signatures
        uint256 n = signerKeys.length;
        address[] memory signers = new address[](n);
        bytes[]   memory sigs    = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            signers[i] = vm.addr(signerKeys[i]);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[i], safeTxHash);
            sigs[i] = abi.encodePacked(r, s, v);
        }

        // Sort by address ascending (Safe requires this for the packed sig blob)
        for (uint256 i = 1; i < n; i++) {
            for (uint256 j = i; j > 0 && signers[j - 1] > signers[j]; j--) {
                (signers[j - 1], signers[j]) = (signers[j], signers[j - 1]);
                (sigs[j - 1],   sigs[j])   = (sigs[j],   sigs[j - 1]);
            }
        }

        bytes memory packed;
        for (uint256 i = 0; i < n; i++) {
            packed = bytes.concat(packed, sigs[i]);
        }

        success = safe.execTransaction(
            p.to, p.value, p.data, p.operation,
            p.safeTxGas, p.baseGas, p.gasPrice, p.gasToken, p.refundReceiver,
            packed
        );
    }

    /// @notice Convenience wrapper for simple call (Operation.Call, zero gas refunds).
    function execCall(Safe safe, address to, bytes memory data, uint256[] memory signerKeys)
        internal
        returns (bool)
    {
        SafeTxParams memory p = SafeTxParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.Call,
            safeTxGas: 0,
            baseGas: 0,
            gasPrice: 0,
            gasToken: address(0),
            refundReceiver: payable(address(0))
        });
        return signAndExec(safe, p, signerKeys);
    }
}
```

- [ ] **Step 2: Build to verify the helper compiles**

Run:
```bash
cd contracts && forge build 2>&1 | tail -3
```
Expected: clean build. If Safe's `Enum.Operation` import path is different in the installed version, adjust the import path (`@safe-global/safe-contracts/contracts/libraries/Enum.sol` vs `common/Enum.sol`).

- [ ] **Step 3: Commit**

Run:
```bash
git add contracts/test/governance/SafeSigHelpers.sol
git commit -m "$(cat <<'EOF'
chore(test): SafeSigHelpers library for Safe v1.4 tx construction

Helper library used by P2Governance.t.sol (dry-run tests) and
DeployGovernanceP2.s.sol to sign + sort + pack Safe v1.4
multisig signatures from Foundry test signers.

Spec: docs/superpowers/specs/2026-05-14-phase2-governance-design.md §6

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `P2Governance.t.sol` dry-run suite

**Files:**
- Create: `contracts/test/governance/P2Governance.t.sol`

End-to-end Foundry tests exercising the full governance lifecycle in-memory: 8 test signers, full deploy of all contracts, propose-warp-execute via Timelock, and direct pause via Guardian Safe.

- [ ] **Step 1: Create the test file**

Create `contracts/test/governance/P2Governance.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { SafeProxyFactory } from "@safe-global/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import { Enum } from "@safe-global/safe-contracts/contracts/libraries/Enum.sol";

import { ArcoraDexPool }      from "../../src/ArcoraDexPool.sol";
import { ArcoraDexRegistry }  from "../../src/ArcoraDexRegistry.sol";
import { IArcoraDexPool }     from "../../src/interfaces/IArcoraDexPool.sol";
import { IChainlinkAggregator } from "../../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeedV2 } from "../../src/testnet/MockChainlinkFeedV2.sol";
import { MockERC20 } from "../helpers/MockERC20.sol";

import { SafeSigHelpers } from "./SafeSigHelpers.sol";

contract P2GovernanceTest is Test {
    using SafeSigHelpers for Safe;

    string constant MNEMONIC =
        "arcora p2 testnet rehearsal twentyone twentytwo twentythree twentyfour twentyfive twentysix twentyseven twentyeight";

    address constant DEPLOYER = address(0xD3);
    uint256 constant TIMELOCK_DELAY = 48 hours;

    // Test signer keys
    uint256[5] govKeys;
    uint256[3] pgKeys;
    address[5] govAddrs;
    address[3] pgAddrs;

    // Deployed contracts
    Safe                governanceSafe;
    Safe                pauseGuardianSafe;
    TimelockController  timelock;
    ArcoraDexRegistry   reg;
    ArcoraDexPool       pool;
    MockERC20           usdc;
    MockChainlinkFeedV2 fUsdc;

    function setUp() public {
        // Derive signers
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i]  = vm.deriveKey(MNEMONIC, uint32(i));
            govAddrs[i] = vm.addr(govKeys[i]);
        }
        for (uint256 i = 0; i < 3; i++) {
            pgKeys[i]  = vm.deriveKey(MNEMONIC, uint32(5 + i));
            pgAddrs[i] = vm.addr(pgKeys[i]);
        }

        // Deploy Pool + Registry + a test token under DEPLOYER ownership
        vm.startPrank(DEPLOYER);
        reg  = new ArcoraDexRegistry(DEPLOYER);
        usdc = new MockERC20("USDC", "USDC", 6);
        fUsdc = new MockChainlinkFeedV2(8, 100_000_000, DEPLOYER, DEPLOYER);
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
        for (uint256 i = 0; i < 5; i++) govOwners[i] = govAddrs[i];
        bytes memory govSetup = abi.encodeCall(
            Safe.setup,
            (govOwners, 3, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        governanceSafe = Safe(payable(address(factory.createProxyWithNonce(address(safeSingleton), govSetup, 1))));

        // Pause Guardian Safe (2/3)
        address[] memory pgOwners = new address[](3);
        for (uint256 i = 0; i < 3; i++) pgOwners[i] = pgAddrs[i];
        bytes memory pgSetup = abi.encodeCall(
            Safe.setup,
            (pgOwners, 2, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        pauseGuardianSafe = Safe(payable(address(factory.createProxyWithNonce(address(safeSingleton), pgSetup, 2))));

        // TimelockController: minDelay = 0 (setup), proposers = [govSafe], executors = [0x0] (open)
        address[] memory proposers = new address[](1);
        proposers[0] = address(governanceSafe);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(0, proposers, executors, address(0));

        // Transfer Pool + Registry ownership to Timelock (in setup mode)
        vm.startPrank(DEPLOYER);
        pool.transferOwnership(address(timelock));
        reg.transferOwnership(address(timelock));
        vm.stopPrank();

        // Timelock executes acceptOwnership on Pool + Registry
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(pool), 0, abi.encodeCall(pool.acceptOwnership, ()), bytes32(0), bytes32(0), 0)));
        _govExec(address(timelock), abi.encodeCall(TimelockController.execute,
            (address(pool), 0, abi.encodeCall(pool.acceptOwnership, ()), bytes32(0), bytes32(0))));
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(reg), 0, abi.encodeCall(reg.acceptOwnership, ()), bytes32(0), bytes32(0), 0)));
        _govExec(address(timelock), abi.encodeCall(TimelockController.execute,
            (address(reg), 0, abi.encodeCall(reg.acceptOwnership, ()), bytes32(0), bytes32(0))));

        // setPauseGuardian
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(pool), 0, abi.encodeCall(pool.setPauseGuardian, (address(pauseGuardianSafe))), bytes32(0), bytes32(0), 0)));
        _govExec(address(timelock), abi.encodeCall(TimelockController.execute,
            (address(pool), 0, abi.encodeCall(pool.setPauseGuardian, (address(pauseGuardianSafe))), bytes32(0), bytes32(0))));

        // Lockdown: updateDelay(48h)
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(timelock), 0, abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY)), bytes32(0), bytes32(0), 0)));
        _govExec(address(timelock), abi.encodeCall(TimelockController.execute,
            (address(timelock), 0, abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY)), bytes32(0), bytes32(0))));
    }

    /// @dev Calls Safe.execTransaction with the first 3 governance signers (meets the 3/5 threshold).
    function _govExec(address to, bytes memory data) internal {
        uint256[] memory keys = new uint256[](3);
        keys[0] = govKeys[0];
        keys[1] = govKeys[1];
        keys[2] = govKeys[2];
        require(governanceSafe.execCall(to, data, keys), "gov exec failed");
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
        assertEq(reg.owner(),  address(timelock));
        assertEq(pool.pauseGuardian(), address(pauseGuardianSafe));
        assertEq(timelock.getMinDelay(), TIMELOCK_DELAY);
        assertEq(governanceSafe.getThreshold(), 3);
        assertEq(pauseGuardianSafe.getThreshold(), 2);
    }

    function test_governance_proposes_executes_setSwapFeeBps() public {
        uint16 newFee = 10;
        bytes memory call = abi.encodeCall(pool.setSwapFeeBps, (newFee));

        // Schedule via governance
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(pool), 0, call, bytes32(0), bytes32(0), TIMELOCK_DELAY)));

        // Cannot execute before delay
        vm.expectRevert();
        timelock.execute(address(pool), 0, call, bytes32(0), bytes32(0));

        // Warp 48h, execute
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        timelock.execute(address(pool), 0, call, bytes32(0), bytes32(0));

        assertEq(pool.swapFeeBps(), newFee);
    }

    function test_pauseGuardian_canPauseInstantly() public {
        assertEq(pool.paused(), false);
        _pgExec(address(pool), abi.encodeCall(pool.pause, ()));
        assertEq(pool.paused(), true);
    }

    function test_pauseGuardian_canUnpauseInstantly() public {
        _pgExec(address(pool), abi.encodeCall(pool.pause, ()));
        assertEq(pool.paused(), true);
        _pgExec(address(pool), abi.encodeCall(pool.unpause, ()));
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

        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(reg), 0, call, bytes32(0), bytes32(0), TIMELOCK_DELAY)));

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        timelock.execute(address(reg), 0, call, bytes32(0), bytes32(0));

        assertEq(reg.tokenInfo(address(usdc)).maxStaleSeconds, newStale);
    }

    function test_executor_open_anyone_can_execute_after_delay() public {
        uint16 newFee = 7;
        bytes memory call = abi.encodeCall(pool.setSwapFeeBps, (newFee));
        _govExec(address(timelock), abi.encodeCall(TimelockController.schedule,
            (address(pool), 0, call, bytes32(0), bytes32(0), TIMELOCK_DELAY)));

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        // Random non-Safe address executes
        vm.prank(address(0xABCD));
        timelock.execute(address(pool), 0, call, bytes32(0), bytes32(0));

        assertEq(pool.swapFeeBps(), newFee);
    }
}
```

- [ ] **Step 2: Run the new suite**

Run:
```bash
cd contracts && forge test --match-contract P2GovernanceTest -vv 2>&1 | tail -25
```
Expected: 7 tests passing (setup_state + 6 lifecycle tests). If any fail with a Safe-specific error (e.g. "GS013" = invalid signatures), debug the signature packing in `SafeSigHelpers.sol`.

Common debugging notes:
- Safe v1.4 expects signatures sorted by signer address ASCENDING. The helper does this; if a test reverts with `GS026` (invalid owner ordering), check the sort logic.
- `Safe.execTransaction` returns `bool` but reverts on internal failure; if you see `success == false` without a revert, increase `safeTxGas` to a non-zero value.

- [ ] **Step 3: Run full test suite**

Run:
```bash
cd contracts && forge test 2>&1 | tail -5
```
Expected: 94 (P2 baseline after Task 3) + 7 = 101 tests passing.

- [ ] **Step 4: Commit**

Run:
```bash
git add contracts/test/governance/P2Governance.t.sol
git commit -m "$(cat <<'EOF'
test(governance): P2 governance lifecycle dry-run suite

Full-stack Foundry tests for the P2 governance migration:
- 8 test signers derived from the testnet mnemonic
- Setup deploys Safe singleton + factory + 2 Safes + Timelock,
  transfers Pool/Registry ownership, sets pauseGuardian, locks down
  Timelock to 48h
- 6 lifecycle tests cover: governance propose-warp-execute on Pool
  and Registry parameters, Pause Guardian instant pause/unpause,
  deployer-EOA reverts post-migration, open-executor demonstration

Spec: docs/superpowers/specs/2026-05-14-phase2-governance-design.md §7

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `DeployArcoraDexV3.s.sol`

**Files:**
- Create: `contracts/script/DeployArcoraDexV3.s.sol`

Mirror of `DeployArcoraDexV2.s.sol` from P1 Task 7 with the same token + feed addresses + bootstrap amounts. The only difference is the Pool now has the `pauseGuardian` field (storage layout change) so it's a fresh deploy.

- [ ] **Step 1: Create the script**

Copy `contracts/script/DeployArcoraDexV2.s.sol` to `contracts/script/DeployArcoraDexV3.s.sol`. Rename the contract from `DeployArcoraDexV2` to `DeployArcoraDexV3`. No functional changes — the file content is otherwise identical to V2 because the bootstrap math doesn't depend on the new storage slot.

Verify the script compiles:
```bash
cd contracts && forge build 2>&1 | tail -3
```
Expected: clean.

- [ ] **Step 2: Dry-run against Arc testnet**

Run:
```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool && set -a; source contracts/.env; set +a; cd contracts && forge script script/DeployArcoraDexV3.s.sol --rpc-url https://rpc.testnet.arc.network 2>&1 | tail -20
```
Expected: simulation complete, NAV at the end ≈ 699_799_512e9 ($699.80).

If the simulation reverts with `InvalidProtocolFeeShareBps(2500)` or similar, the constant in the script may need to match the actual MAX in the contract — the V2 script already uses 2500 since the P1 audit-driven cap tightening.

- [ ] **Step 3: Commit (broadcast comes in Task 8)**

Run:
```bash
git add contracts/script/DeployArcoraDexV3.s.sol
git commit -m "$(cat <<'EOF'
chore(deploy): DeployArcoraDexV3.s.sol for P2 pause-guardian redeploy

Identical to DeployArcoraDexV2.s.sol from P1 Task 7 except for the
contract name. The pauseGuardian storage addition to ArcoraDexPool
(Task 3 of P2) forces a fresh deploy of Pool + Registry + LP; this
script handles it. Tokens + feeds are reused from the 2026-05-10
cutover; bootstrap ~$100 each (NAV ~$700).

Broadcast deferred to Task 8 of the implementation plan.

Spec: docs/superpowers/specs/2026-05-14-phase2-governance-design.md §6.1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `DeployGovernanceP2.s.sol`

**Files:**
- Create: `contracts/script/DeployGovernanceP2.s.sol`

Forge script that deploys the full governance stack and wires it up. Runs AFTER `DeployArcoraDexV3.s.sol` and consumes its output addresses via env vars (`POOL_V3`, `REGISTRY_V3`).

- [ ] **Step 1: Create the script**

Create `contracts/script/DeployGovernanceP2.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { SafeProxyFactory } from "@safe-global/safe-contracts/contracts/proxies/SafeProxyFactory.sol";

import { ArcoraDexPool }      from "../src/ArcoraDexPool.sol";
import { ArcoraDexRegistry }  from "../src/ArcoraDexRegistry.sol";
import { SafeSigHelpers }     from "../test/governance/SafeSigHelpers.sol";

contract DeployGovernanceP2 is Script {
    using SafeSigHelpers for Safe;

    string constant MNEMONIC =
        "arcora p2 testnet rehearsal twentyone twentytwo twentythree twentyfour twentyfive twentysix twentyseven twentyeight";
    uint256 constant TIMELOCK_DELAY = 48 hours;
    uint256 constant SIGNER_FUND_AMT = 0.1 ether;

    // Reused feed addresses from 2026-05-10 cutover (owners get transferred to GovSafe)
    address[7] FEEDS = [
        0x2E6B862E1Ac74328238494B22317262004534B39,
        0x741af784a1d4C69843A1764099433160088a1c70,
        0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896,
        0xAAC5a5855deF9414f7330f350c2E00119C2097c8,
        0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170,
        0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C,
        0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d
    ];

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        ArcoraDexPool     pool = ArcoraDexPool(vm.envAddress("POOL_V3"));
        ArcoraDexRegistry reg  = ArcoraDexRegistry(vm.envAddress("REGISTRY_V3"));

        // Derive signers (8 total: 5 gov + 3 pg)
        uint256[5] memory govKeys;
        address[5] memory govAddrs;
        uint256[3] memory pgKeys;
        address[3] memory pgAddrs;
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i]  = vm.deriveKey(MNEMONIC, uint32(i));
            govAddrs[i] = vm.addr(govKeys[i]);
        }
        for (uint256 i = 0; i < 3; i++) {
            pgKeys[i]  = vm.deriveKey(MNEMONIC, uint32(5 + i));
            pgAddrs[i] = vm.addr(pgKeys[i]);
        }

        vm.startBroadcast(deployerKey);

        // 1. Fund signers
        for (uint256 i = 0; i < 5; i++) payable(govAddrs[i]).transfer(SIGNER_FUND_AMT);
        for (uint256 i = 0; i < 3; i++) payable(pgAddrs[i]).transfer(SIGNER_FUND_AMT);
        console2.log("Funded 8 signers (0.1 ARC each)");

        // 2. Deploy Safe singleton + factory
        Safe safeSingleton = new Safe();
        SafeProxyFactory factory = new SafeProxyFactory();
        console2.log("Safe singleton:", address(safeSingleton));
        console2.log("Safe factory:  ", address(factory));

        // 3. Governance Safe (3/5)
        address[] memory govOwners = new address[](5);
        for (uint256 i = 0; i < 5; i++) govOwners[i] = govAddrs[i];
        bytes memory govSetup = abi.encodeCall(
            Safe.setup,
            (govOwners, 3, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        Safe governanceSafe = Safe(payable(address(factory.createProxyWithNonce(address(safeSingleton), govSetup, 1))));
        console2.log("Governance Safe:", address(governanceSafe));

        // 4. Pause Guardian Safe (2/3)
        address[] memory pgOwners = new address[](3);
        for (uint256 i = 0; i < 3; i++) pgOwners[i] = pgAddrs[i];
        bytes memory pgSetup = abi.encodeCall(
            Safe.setup,
            (pgOwners, 2, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        Safe pauseGuardianSafe = Safe(payable(address(factory.createProxyWithNonce(address(safeSingleton), pgSetup, 2))));
        console2.log("Pause Guardian Safe:", address(pauseGuardianSafe));

        // 5. TimelockController (minDelay = 0 for setup)
        address[] memory proposers = new address[](1);
        proposers[0] = address(governanceSafe);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(0, proposers, executors, address(0));
        console2.log("Timelock:", address(timelock));

        // 6. Pool + Registry: transferOwnership to Timelock
        pool.transferOwnership(address(timelock));
        reg.transferOwnership(address(timelock));

        // 7. Governance Safe schedules + executes Pool/Registry acceptOwnership
        //    (broadcast continues — Safe.execTransaction is called from deployerKey's
        //     address as msg.sender, but Safe verifies the multisig signatures internally)
        _scheduleAndExec(governanceSafe, govKeys, timelock,
            address(pool), abi.encodeCall(pool.acceptOwnership, ()));
        _scheduleAndExec(governanceSafe, govKeys, timelock,
            address(reg), abi.encodeCall(reg.acceptOwnership, ()));

        // 8. setPauseGuardian
        _scheduleAndExec(governanceSafe, govKeys, timelock,
            address(pool), abi.encodeCall(pool.setPauseGuardian, (address(pauseGuardianSafe))));

        // 9. Transfer feed ownership to Governance Safe (direct, no timelock)
        for (uint256 i = 0; i < 7; i++) {
            (bool ok,) = FEEDS[i].call(abi.encodeWithSignature("transferOwnership(address)", address(governanceSafe)));
            require(ok, "feed transferOwnership failed");
        }
        // Governance Safe accepts each feed's ownership (Ownable2Step)
        uint256[] memory acceptKeys = new uint256[](3);
        acceptKeys[0] = govKeys[0]; acceptKeys[1] = govKeys[1]; acceptKeys[2] = govKeys[2];
        for (uint256 i = 0; i < 7; i++) {
            require(
                governanceSafe.execCall(FEEDS[i], abi.encodeWithSignature("acceptOwnership()"), acceptKeys),
                "feed acceptOwnership failed"
            );
        }

        // 10. Lockdown: updateDelay(48h)
        _scheduleAndExec(governanceSafe, govKeys, timelock,
            address(timelock), abi.encodeCall(TimelockController.updateDelay, (TIMELOCK_DELAY)));

        vm.stopBroadcast();

        console2.log("=== Final state ===");
        console2.log("Pool owner:       ", pool.owner());
        console2.log("Registry owner:   ", reg.owner());
        console2.log("Pool pauseGuardian:", pool.pauseGuardian());
        console2.log("Timelock minDelay:", timelock.getMinDelay());
    }

    /// @dev Schedules an action via Governance Safe at the current Timelock delay,
    /// then executes it. Used in setup mode where delay=0 lets us schedule+execute
    /// in immediate succession. The msg.sender of the Safe.execTransaction call is
    /// whoever is currently broadcasting (typically the deployer EOA); Safe internally
    /// verifies the multisig signatures, so any caller can submit a properly-signed
    /// transaction.
    function _scheduleAndExec(
        Safe gov,
        uint256[5] memory govKeys,
        TimelockController timelock,
        address target,
        bytes memory call
    ) internal {
        uint256[] memory keys = new uint256[](3);
        keys[0] = govKeys[0]; keys[1] = govKeys[1]; keys[2] = govKeys[2];

        require(
            gov.execCall(
                address(timelock),
                abi.encodeCall(TimelockController.schedule, (target, 0, call, bytes32(0), bytes32(0), 0)),
                keys
            ),
            "schedule failed"
        );
        require(
            gov.execCall(
                address(timelock),
                abi.encodeCall(TimelockController.execute, (target, 0, call, bytes32(0), bytes32(0))),
                keys
            ),
            "execute failed"
        );
    }
}
```

- [ ] **Step 2: Verify the script compiles**

Run:
```bash
cd contracts && forge build 2>&1 | tail -3
```
Expected: clean. If `SafeSigHelpers` path-resolution fails (script in `script/`, helper in `test/governance/`), Foundry should still find it via the project root — but if not, move `SafeSigHelpers.sol` to `contracts/src/governance/` and update the import paths in both the script and the test.

- [ ] **Step 3: Local fork dry-run (no real broadcast)**

A live dry-run against Arc testnet would mutate the test signers' addresses (which don't yet have ARC). Instead, run the script against a forked local Anvil instance to exercise the full flow:

Run:
```bash
cd contracts && anvil --fork-url https://rpc.testnet.arc.network --chain-id 5042002 --port 18545 &
ANVIL_PID=$!
sleep 3
# Use the deployer key from .env to fund and run
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" POOL_V3=0x0000000000000000000000000000000000000000 REGISTRY_V3=0x0000000000000000000000000000000000000000 \
  forge script script/DeployGovernanceP2.s.sol --rpc-url http://localhost:18545 2>&1 | tail -30
kill $ANVIL_PID
```
Expected: simulation reverts because POOL_V3 is `0x0`. This is correct — the script can't run without real V3 addresses. The dry-run here is for compile-and-import sanity only, not for end-to-end behavior. The `P2GovernanceTest` suite (Task 5) covers end-to-end behavior in a pure in-memory setup.

- [ ] **Step 4: Commit**

Run:
```bash
git add contracts/script/DeployGovernanceP2.s.sol
git commit -m "$(cat <<'EOF'
chore(deploy): DeployGovernanceP2.s.sol governance stack rollout

Forge script that deploys the full P2 governance migration:
- Funds 8 test signers (5 gov + 3 pg) from deployer
- Deploys Safe singleton + factory
- Deploys Governance Safe (3/5) and Pause Guardian Safe (2/3)
- Deploys TimelockController (minDelay=0 setup mode, gov as proposer,
  open executor)
- Transfers Pool + Registry ownership to Timelock (via the
  Ownable2Step accept pattern through Safe-scheduled timelock execs)
- Sets pauseGuardian on Pool
- Transfers all 7 MockChainlinkFeedV2 ownerships to Governance Safe
  (no timelock — instant writer rotation)
- Locks down Timelock to 48h delay as the FINAL action

Consumes POOL_V3 and REGISTRY_V3 from env vars (output by the
DeployArcoraDexV3 broadcast).

Spec: docs/superpowers/specs/2026-05-14-phase2-governance-design.md §6.2

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Broadcast V3 redeploy (operator-driven, live testnet)

**Files:** none modified.

Live broadcast. Requires `DEPLOYER_PRIVATE_KEY` in `contracts/.env`.

- [ ] **Step 1: Final dry-run**

Run:
```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool && set -a; source contracts/.env; set +a; cd contracts && forge script script/DeployArcoraDexV3.s.sol --rpc-url https://rpc.testnet.arc.network 2>&1 | tail -10
```
Expected: simulation complete; final NAV ≈ $699.80; estimated gas ≈ 0.4 ARC.

- [ ] **Step 2: Broadcast**

Run:
```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool && set -a; source contracts/.env; set +a; cd contracts && forge script script/DeployArcoraDexV3.s.sol --rpc-url https://rpc.testnet.arc.network --broadcast 2>&1 | tail -10
```
Expected: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`.

- [ ] **Step 3: Capture new addresses**

Run:
```bash
python3 -c "
import json
with open('contracts/broadcast/DeployArcoraDexV3.s.sol/5042002/run-latest.json') as f:
    data = json.load(f)
for tx in data['transactions']:
    if tx['transactionType'] == 'CREATE':
        print(f\"{tx['contractName']:24s} {tx['contractAddress']}\")
"
```
Capture `REGISTRY_V3`, `POOL_V3`, and (query separately) `LP_V3`:
```bash
RPC=https://rpc.testnet.arc.network
echo "LP_V3: $(cast call $POOL_V3 'LP()(address)' --rpc-url $RPC)"
```

Save these addresses for Task 9 — they're the env vars for the governance deploy.

- [ ] **Step 4: Verify V3 state on-chain**

Run:
```bash
RPC=https://rpc.testnet.arc.network
echo "Pool paused: $(cast call $POOL_V3 'paused()(bool)' --rpc-url $RPC)"
echo "Pool owner:  $(cast call $POOL_V3 'owner()(address)' --rpc-url $RPC)"
echo "Pool NAV:    $(cast call $POOL_V3 'totalReservesUSD()(uint256)' --rpc-url $RPC)"
echo "Pool guardian: $(cast call $POOL_V3 'pauseGuardian()(address)' --rpc-url $RPC)"
echo "Registry owner: $(cast call $REGISTRY_V3 'owner()(address)' --rpc-url $RPC)"
echo "Registry tokensLength: $(cast call $REGISTRY_V3 'tokensLength()(uint256)' --rpc-url $RPC)"
```
Expected: pool paused=false, owner=deployer, NAV ≈ 699.8e18, guardian=0x0 (not yet set), Registry owner=deployer, tokensLength=7.

No commit — broadcast artifacts are gitignored (`contracts/broadcast/` is in `.gitignore`).

---

### Task 9: Broadcast governance stack (operator-driven, live testnet)

**Files:** none modified.

- [ ] **Step 1: Export V3 addresses to env**

Run (replace addresses with the values captured in Task 8 Step 3):
```bash
export POOL_V3=<address>
export REGISTRY_V3=<address>
```

- [ ] **Step 2: Final dry-run**

Run:
```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool && set -a; source contracts/.env; set +a
export POOL_V3 REGISTRY_V3
cd contracts && forge script script/DeployGovernanceP2.s.sol --rpc-url https://rpc.testnet.arc.network 2>&1 | tail -15
```
Expected: simulation complete; logs `Pool owner: <Timelock addr>`, `Pool pauseGuardian: <PauseGuardian Safe addr>`, `Timelock minDelay: 172800`.

- [ ] **Step 3: Broadcast**

Run:
```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool && set -a; source contracts/.env; set +a
export POOL_V3 REGISTRY_V3
cd contracts && forge script script/DeployGovernanceP2.s.sol --rpc-url https://rpc.testnet.arc.network --broadcast 2>&1 | tail -20
```
Expected: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`.

- [ ] **Step 4: Capture governance addresses**

Run:
```bash
python3 -c "
import json
with open('contracts/broadcast/DeployGovernanceP2.s.sol/5042002/run-latest.json') as f:
    data = json.load(f)
for tx in data['transactions']:
    if tx['transactionType'] == 'CREATE':
        print(f\"{tx['contractName']:24s} {tx['contractAddress']}\")
"
```
Expected: Safe singleton, SafeProxyFactory, TimelockController, 2 Safe proxies (governance + guardian).

Save addresses for the rollout doc (Task 11): `SAFE_SINGLETON`, `SAFE_FACTORY`, `GOVERNANCE_SAFE`, `PAUSE_GUARDIAN_SAFE`, `TIMELOCK`.

- [ ] **Step 5: Verify migrated state**

Run:
```bash
RPC=https://rpc.testnet.arc.network
echo "Pool owner (expect Timelock):    $(cast call $POOL_V3 'owner()(address)' --rpc-url $RPC)"
echo "Pool pauseGuardian (expect Safe): $(cast call $POOL_V3 'pauseGuardian()(address)' --rpc-url $RPC)"
echo "Registry owner (expect Timelock): $(cast call $REGISTRY_V3 'owner()(address)' --rpc-url $RPC)"
echo "Timelock minDelay (expect 172800): $(cast call $TIMELOCK 'getMinDelay()(uint256)' --rpc-url $RPC)"
echo "Governance Safe threshold (expect 3): $(cast call $GOVERNANCE_SAFE 'getThreshold()(uint256)' --rpc-url $RPC)"
echo "Pause Guardian Safe threshold (expect 2): $(cast call $PAUSE_GUARDIAN_SAFE 'getThreshold()(uint256)' --rpc-url $RPC)"
for FEED in 0x2E6B862E1Ac74328238494B22317262004534B39 0x741af784a1d4C69843A1764099433160088a1c70 0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896 0xAAC5a5855deF9414f7330f350c2E00119C2097c8 0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170 0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C 0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d; do
  echo "Feed $FEED owner: $(cast call $FEED 'owner()(address)' --rpc-url $RPC)"
done
```
Expected: all owners point at Timelock or Governance Safe as specified.

No commit at this step.

---

### Task 10: Pause P1 pool + sanity ping + scheduled-action demo

**Files:** none modified.

- [ ] **Step 1: Pause P1 pool**

The P1 pool (`0xb01a7a4da9986e9eb197d98242cf74d15f1f648b`) is still owned by the deployer EOA (it was never migrated). Pause it so SDK consumers know to use V3.

Run:
```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool && set -a; source contracts/.env; set +a
RPC=https://rpc.testnet.arc.network
P1_POOL=0xb01a7a4da9986e9eb197d98242cf74d15f1f648b
cast send $P1_POOL 'pause()' --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url $RPC 2>&1 | grep -E "^(status|transactionHash) "
cast call $P1_POOL 'paused()(bool)' --rpc-url $RPC
```
Expected: status 1; `paused()` returns `true`.

- [ ] **Step 2: Sanity ping — deployer EOA cannot pause V3**

Direct deployer call to `pool.pause()` should revert because owner is now Timelock and deployer is not the pause guardian.

Run:
```bash
cast send $POOL_V3 'pause()' --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url $RPC 2>&1 | tail -5
```
Expected: `execution reverted` with `NotAuthorized()` or `OwnableUnauthorizedAccount(<deployer>)`.

- [ ] **Step 3: Schedule a no-op governance action**

Demonstrate the full lifecycle by scheduling a no-op `setSwapFeeBps(5)` (the value is already 5; the scheduled action is for ceremony, not effect). The execute happens 48 hours later — outside this session — and is captured in the rollout doc.

This step requires signing a Safe transaction with at least 3 of the 5 governance signers' derived keys. The mnemonic is in the spec / rollout doc, so an operator can replay derivation off-chain.

For this session, document the scheduled action's parameters in the rollout doc (Task 11) and skip the actual on-chain schedule. Foundry tests in Task 5 already prove the schedule + execute cycle works.

Alternatively, if the operator wants a live demonstration NOW, they can write a small one-shot script that:
1. Derives `govKeys[0..2]`.
2. Constructs the schedule call.
3. Submits to the Governance Safe via `SafeSigHelpers.execCall`.

For the plan's purposes, mark this as **optional / off-band** — Foundry coverage in Task 5 is the audit-quality demonstration.

- [ ] **Step 4: Sanity ping — pause guardian instant pause/unpause (LIVE)**

This demonstrates the no-timelock-pause path on the live testnet. Requires the operator to write a small one-shot script that derives `pgKeys[0..1]`, calls `pauseGuardianSafe.execCall(pool, encodeCall(pool.pause, ()), keys)`, then `pool.paused()` should be `true`, then unpause to return to operational state.

Optional but high-value for the rollout doc. If the operator skips this in-session, mark as a known follow-up.

No commit at this step.

---

### Task 11: Rollout doc

**Files:**
- Create: `docs/rollouts/2026-05-14-phase2-governance.md`

- [ ] **Step 1: Write the rollout doc**

Create `docs/rollouts/2026-05-14-phase2-governance.md` with the following structure (fill in actual addresses from Tasks 8 and 9):

```markdown
# Phase 2 — Governance Migration Rollout (Testnet Rehearsal)

**Date:** 2026-05-14
**Branch:** `phase2/governance-rollout` (merged to main as PR #N)
**Spec:** `docs/superpowers/specs/2026-05-14-phase2-governance-design.md`
**Roadmap parent:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §4

## Why migrate

P1 closed contract-level economic footguns. P2 closes the governance footgun (audit finding #3, HIGH): the deployer EOA was a single point of failure for every owner action across Pool, Registry, and the 7 feeds. P2 migrates ownership to a Safe 3/5 + OZ TimelockController (48h delay) for governance, and a separate Safe 2/3 Pause Guardian that bypasses the timelock for emergency pause/unpause.

**Scope: testnet rehearsal only. Mainnet rotation deferred to P5 with real signers + hardware wallets.**

## New (V3) protocol addresses

| Contract           | Address |
|--------------------|---------|
| ArcoraDexRegistry  | `<REGISTRY_V3>` |
| ArcoraDexPool      | `<POOL_V3>` |
| ArcoraDexLP        | `<LP_V3>` |

(P1 pool at `0xb01a7a4da9986e9eb197d98242cf74d15f1f648b` is paused; old NAV ~$700 abandoned.)

## Governance addresses

| Contract           | Address |
|--------------------|---------|
| Safe singleton     | `<SAFE_SINGLETON>` |
| SafeProxyFactory   | `<SAFE_FACTORY>` |
| Governance Safe (3/5) | `<GOVERNANCE_SAFE>` |
| Pause Guardian Safe (2/3) | `<PAUSE_GUARDIAN_SAFE>` |
| TimelockController | `<TIMELOCK>` |

## Test signers (testnet-only — DO NOT use on mainnet)

Derived via Forge `vm.deriveKey` from BIP39 mnemonic:

```
arcora p2 testnet rehearsal twentyone twentytwo twentythree twentyfour twentyfive twentysix twentyseven twentyeight
```

| Role | Index | Address |
|------|-------|---------|
| gov1 | 0 | `<address>` |
| gov2 | 1 | `<address>` |
| gov3 | 2 | `<address>` |
| gov4 | 3 | `<address>` |
| gov5 | 4 | `<address>` |
| pg1  | 5 | `<address>` |
| pg2  | 6 | `<address>` |
| pg3  | 7 | `<address>` |

Each signer received 0.1 ARC at deploy time.

## Ownership matrix

| Contract            | Owner |
|---------------------|-------|
| ArcoraDexPool       | TimelockController (48h delay for all owner actions; pauseGuardian for instant pause) |
| ArcoraDexRegistry   | TimelockController (48h delay) |
| 7× MockChainlinkFeedV2 | Governance Safe (direct, no timelock — instant writer rotation) |

## Verified state post-deploy

(Snapshot from Task 9 Step 5; reproduce with `cast call` commands in the test plan.)

## Per-action operator runbook

### Emergency pause (Pause Guardian Safe)

To pause Pool immediately:

1. Two of {pg1, pg2, pg3} sign `pool.pause()` via Safe.
2. Any address executes the Safe transaction.

The pool is paused within one block. No 48h delay.

### Governance action (Timelock 48h delay)

To change e.g. `swapFeeBps` from 5 to 10:

1. Three of {gov1..gov5} sign a Safe tx calling `timelock.schedule(pool, 0, encodeCall(setSwapFeeBps, (10)), 0, 0, 172800)`.
2. Wait 48 hours.
3. Anyone executes `timelock.execute(pool, 0, encodeCall(setSwapFeeBps, (10)), 0, 0)`.

### Feed writer rotation (Governance Safe direct)

To rotate the keeper EOA on a compromised feed:

1. Three of {gov1..gov5} sign a Safe tx calling `<feed>.setWriter(newKeeperEOA)`.
2. Any address executes the Safe transaction.

No timelock delay; instant.

### Adding new token to Registry

1. Three of {gov1..gov5} sign `timelock.schedule(registry, 0, encodeCall(listToken, (...)), 0, 0, 172800)`.
2. Wait 48h.
3. Execute.

(For mainnet, prepend an off-chain 7-day public announcement before scheduling.)

## Downstream tasks

- [ ] Update SDK to point at new V3 Pool / Registry / LP addresses
- [ ] Update Vercel app env (`NEXT_PUBLIC_POOL_ADDR`, `NEXT_PUBLIC_REGISTRY_ADDR`)
- [ ] Update VPS keeper `.env` if any addresses changed (feeds reused so likely no change)
- [ ] Update auto-memory `arcoradex_role_eoas.md` with V3 addresses + governance addresses
- [ ] Announce in ops channel

## Rollback

The deployer EOA still controls 0 contracts directly; rolling back ownership requires governance proposals (which themselves take 48h). For emergency rollback within 48h, only the Pause Guardian can act (pause the pool, halting swaps but not unwinding governance).

For the mainnet equivalent, design includes a fail-safe owner-recovery path via a Sentinel module that, after a multi-week no-activity timer, can return ownership to a designated recovery address. **Not implemented in this testnet rehearsal.**

## Phase 2 status

✅ Pool pauseGuardian role merged (PR #N1)
✅ V3 protocol redeploy live
✅ Governance stack deployed and ownership migrated
⏭ Next: P3 oracle hardening (multi-source aggregator, tighten TRYC/BRLC caps, cumulative deviation circuit breaker)
```

- [ ] **Step 2: Stage and commit**

Run:
```bash
git add docs/rollouts/2026-05-14-phase2-governance.md
git commit -m "$(cat <<'EOF'
docs(rollout): phase 2 governance migration rollout (2026-05-14)

Live testnet rehearsal of the P2 governance migration. New V3 Pool +
Registry + LP deployed with pauseGuardian role; Safe 3/5 governance,
Safe 2/3 Pause Guardian, OZ TimelockController (48h delay)
deployed and wired up; all ownerships transferred from the deployer
EOA.

Documents: all addresses, test-signer mnemonic + indices, per-action
operator runbook (emergency pause, governance proposal, feed writer
rotation, new token listing), and the downstream SDK / app / memory
update checklist.

Mainnet equivalent deploy script + real signer rotation deferred to
P5.

Spec: docs/superpowers/specs/2026-05-14-phase2-governance-design.md §8

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Final pre-merge checks

**Files:** none modified.

- [ ] **Step 1: Run full test suite**

Run:
```bash
cd contracts && forge test 2>&1 | tail -5
```
Expected: ≥101 tests passing (91 P1 baseline + 3 pauseGuardian + 7 governance).

- [ ] **Step 2: Coverage check on changed files**

Run:
```bash
cd contracts && forge coverage --report summary 2>&1 | grep -E "src/(ArcoraDex|interfaces|testnet)"
```
Expected: ArcoraDexPool ≥93%, ArcoraDexRegistry ≥95%, ArcoraDexLP 100%. Pool's `pauseGuardian` paths covered by the 3 Task 3 tests.

- [ ] **Step 3: Slither check**

Run:
```bash
cd contracts && slither . 2>&1 | tail -10
```
Expected: same warning categories as P1 baseline. No new HIGH/MEDIUM.

If the new `notifyLPTransfer` callback path adds a reentrancy-benign warning, it's expected — verify it's labeled benign (the callback only writes one storage slot conditionally, no external calls).

- [ ] **Step 4: Branch state summary**

Run:
```bash
git log --oneline main..HEAD
git diff main --stat
```
Expected: 8 commits on branch (Task 2 + Task 3 + Task 4 + Task 5 + Task 6 + Task 7 + Task 11 + final cleanup if any).

- [ ] **Step 5: STOP. Hand back to operator for PR creation and merge.**

The plan does not push or open the PR. Operator reviews the branch, then opens PR using the template suggested in Task 11's commit body.

---

## Rollback

Each task ships as its own commit. Reverting individual changes via `git revert <sha>` is straightforward. The on-chain governance migration is harder to roll back: ownership is now held by Timelock, so reversing requires a 48h-delayed proposal. For a true emergency, the Pause Guardian can pause the pool (instant), halting user activity while the operator coordinates a recovery proposal.

For the planning-stage rollback (before broadcast), simply discard the local branch and the testnet stays at the P1 V2 state.
