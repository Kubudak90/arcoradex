# Audit Group B — Key Separation + VPS LPU Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate ArcoraDEX testnet from a single deployer EOA controlling everything to a 3-role split (deployer governance / keeper / faucet), with the keeper key stored in HashiCorp Vault and its systemd unit running as an unprivileged `arcora` user on the shared VPS.

**Architecture:** Hybrid migration — deploy a new `MockChainlinkFeedV2` per token (writer-role separated from owner) and re-point each registry slot via `setOracle`; transfer existing `MintableERC20` ownership to a new faucet EOA via OZ Ownable. Tokens stay at their current addresses (SDK/app unchanged); only feed addresses rotate. Keeper EOA's private key is fetched at systemd start from Vault into a tmpfs `EnvironmentFile`, deleted on stop.

**Tech Stack:** Solidity 0.8.26 (Foundry), TypeScript/Node (keeper, Vercel API), HashiCorp Vault (KV-v2 + AppRole), systemd, viem.

**Spec:** [`docs/superpowers/specs/2026-05-09-key-separation-design.md`](../specs/2026-05-09-key-separation-design.md)

---

## Pre-flight

- [ ] **Step 0.1: Confirm clean working tree on `main`**

```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool
git status --short
git rev-parse --abbrev-ref HEAD
```

Expected:
```
(empty)
main
```

If dirty, stop. Resolve before starting.

- [ ] **Step 0.2: Create feature branch**

```bash
git checkout -b audit/group-b-key-separation
```

- [ ] **Step 0.3: Verify forge baseline**

```bash
cd contracts && forge test 2>&1 | tail -3
```

Expected: `68 tests passed, 0 failed, 0 skipped`

If different, note baseline number — all later tasks must keep it ≥ this.

---

## Phase 1 — Smart contract code (TDD, no chain interaction)

### Task 1: `MockChainlinkFeedV2` contract

**Files:**
- Create: `contracts/src/testnet/MockChainlinkFeedV2.sol`

- [ ] **Step 1.1: Write the contract**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable }      from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IChainlinkAggregator } from "../interfaces/IChainlinkAggregator.sol";

/// @title MockChainlinkFeedV2
/// @notice Testnet-only Chainlink-shaped price feed with role-separated owner
/// (admin) and writer (price-pusher). Drop-in replacement for MockChainlinkFeed
/// at the registry's oracle slot.
contract MockChainlinkFeedV2 is IChainlinkAggregator, Ownable2Step {
    address public writer;
    int256  public latestAnswer;
    uint256 public latestUpdatedAt;
    uint8   public immutable decimalsValue;

    error NotWriter();
    event WriterUpdated(address indexed prev, address indexed next);
    event AnswerUpdated(int256 answer, uint256 updatedAt);

    constructor(
        uint8   _decimals,
        int256  initialAnswer,
        address initialWriter,
        address initialOwner
    ) Ownable(initialOwner) {
        decimalsValue   = _decimals;
        latestAnswer    = initialAnswer;
        latestUpdatedAt = block.timestamp;
        writer          = initialWriter;
        emit WriterUpdated(address(0), initialWriter);
        emit AnswerUpdated(initialAnswer, block.timestamp);
    }

    function setWriter(address newWriter) external onlyOwner {
        emit WriterUpdated(writer, newWriter);
        writer = newWriter;
    }

    function setAnswer(int256 newAnswer) external {
        if (msg.sender != writer) revert NotWriter();
        latestAnswer    = newAnswer;
        latestUpdatedAt = block.timestamp;
        emit AnswerUpdated(newAnswer, block.timestamp);
    }

    function decimals() external view returns (uint8) { return decimalsValue; }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, latestAnswer, latestUpdatedAt, latestUpdatedAt, 1);
    }
}
```

- [ ] **Step 1.2: Compile**

```bash
cd contracts && forge build 2>&1 | tail -5
```

Expected: `Compiler run successful` (warnings about unsafe-typecast in unrelated test files are OK; no errors).

- [ ] **Step 1.3: Commit**

```bash
git add contracts/src/testnet/MockChainlinkFeedV2.sol
git commit -m "$(cat <<'EOF'
feat(contracts): MockChainlinkFeedV2 with writer-role separated from owner

Drop-in replacement for MockChainlinkFeed: same IChainlinkAggregator
shape, but setAnswer is now restricted to a writer address (settable
by owner), separate from the ownership transfer (Ownable2Step).
Enables splitting feed-write capability from feed-admin capability
during the testnet key-separation migration.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Tests for `MockChainlinkFeedV2`

**Files:**
- Create: `contracts/test/MockChainlinkFeedV2.t.sol`

- [ ] **Step 2.1: Write the test file (full scenarios — TDD-style: write all tests, watch them fail wholesale, fix is "the contract from Task 1 already exists" so they pass)**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockChainlinkFeedV2 } from "../src/testnet/MockChainlinkFeedV2.sol";

contract MockChainlinkFeedV2Test is Test {
    MockChainlinkFeedV2 feed;

    address owner   = address(0xA11CE);
    address writer  = address(0xBEEF);
    address other   = address(0xCAFE);

    function setUp() public {
        feed = new MockChainlinkFeedV2(8, 1.0e8, writer, owner);
    }

    function test_constructor_setsState() public view {
        assertEq(feed.owner(), owner);
        assertEq(feed.writer(), writer);
        assertEq(feed.latestAnswer(), 1.0e8);
        assertEq(feed.latestUpdatedAt(), block.timestamp);
        assertEq(feed.decimals(), 8);
    }

    function test_setAnswer_revertsIfNotWriter() public {
        vm.prank(other);
        vm.expectRevert(MockChainlinkFeedV2.NotWriter.selector);
        feed.setAnswer(1.01e8);

        vm.prank(owner); // owner is NOT writer
        vm.expectRevert(MockChainlinkFeedV2.NotWriter.selector);
        feed.setAnswer(1.01e8);
    }

    function test_setAnswer_succeedsIfWriter() public {
        vm.warp(block.timestamp + 600);
        vm.prank(writer);
        feed.setAnswer(1.05e8);
        assertEq(feed.latestAnswer(), 1.05e8);
        assertEq(feed.latestUpdatedAt(), block.timestamp);
    }

    function test_setWriter_revertsIfNotOwner() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        feed.setWriter(other);

        vm.prank(writer); // writer is NOT owner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, writer));
        feed.setWriter(other);
    }

    function test_setWriter_updatesWriterAndOldWriterLosesAccess() public {
        address newWriter = address(0xD00D);
        vm.prank(owner);
        feed.setWriter(newWriter);
        assertEq(feed.writer(), newWriter);

        // Old writer can no longer write
        vm.prank(writer);
        vm.expectRevert(MockChainlinkFeedV2.NotWriter.selector);
        feed.setAnswer(1.10e8);

        // New writer can
        vm.prank(newWriter);
        feed.setAnswer(1.10e8);
        assertEq(feed.latestAnswer(), 1.10e8);
    }

    function test_transferOwnership_isTwoStep() public {
        address newOwner = address(0xE0F);

        vm.prank(owner);
        feed.transferOwnership(newOwner);

        // Until accepted, old owner still in control
        assertEq(feed.owner(), owner);
        assertEq(feed.pendingOwner(), newOwner);

        // Old owner can still setWriter at this point
        vm.prank(owner);
        feed.setWriter(other);
        assertEq(feed.writer(), other);

        // New owner accepts
        vm.prank(newOwner);
        feed.acceptOwnership();
        assertEq(feed.owner(), newOwner);
        assertEq(feed.pendingOwner(), address(0));

        // Old owner no longer admin
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        feed.setWriter(writer);
    }

    function test_latestRoundData_shape() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, 1.0e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }
}
```

- [ ] **Step 2.2: Run tests — expect all pass since contract from Task 1 already exists**

```bash
cd contracts && forge test --match-contract MockChainlinkFeedV2Test -vv 2>&1 | tail -15
```

Expected: `6 passed; 0 failed; 0 skipped`

- [ ] **Step 2.3: Run full suite to confirm baseline holds**

```bash
forge test 2>&1 | tail -3
```

Expected: `74 tests passed, 0 failed, 0 skipped` (68 baseline + 6 new).

- [ ] **Step 2.4: Commit**

```bash
git add contracts/test/MockChainlinkFeedV2.t.sol
git commit -m "$(cat <<'EOF'
test(contracts): MockChainlinkFeedV2 — writer/owner separation invariants

Covers: constructor state, NotWriter revert from non-writer (incl.
owner), setAnswer success path, setWriter onlyOwner gate, old-writer
loses access after rotation, transferOwnership 2-step semantics
(pending acceptance), latestRoundData shape parity with v1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `MigrateFeedsToV2` deployment script

**Files:**
- Create: `contracts/script/MigrateFeedsToV2.s.sol`

- [ ] **Step 3.1: Write the script**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 }   from "forge-std/Script.sol";
import { ArcoraDexRegistry }  from "../src/ArcoraDexRegistry.sol";
import { ArcoraDexPool }      from "../src/ArcoraDexPool.sol";
import { MockChainlinkFeedV2 } from "../src/testnet/MockChainlinkFeedV2.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";

/// @notice Deploys MockChainlinkFeedV2 instances for every active token in the
/// registry, copies the current oracle's latestAnswer as initialAnswer, sets
/// the writer to KEEPER_EOA + the owner to DEPLOYER (= broadcaster), then
/// re-points the registry via setOracle. Asserts NAV invariant pre/post.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY  — broadcasts (must be current registry/pool owner)
///   REGISTRY_ADDR         — ArcoraDexRegistry
///   POOL_ADDR             — ArcoraDexPool (for NAV invariant check)
///   KEEPER_EOA            — address (NOT key) of the new keeper EOA
contract MigrateFeedsToV2 is Script {
    function run() external {
        uint256 pk        = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address registry  = vm.envAddress("REGISTRY_ADDR");
        address poolAddr  = vm.envAddress("POOL_ADDR");
        address keeperEOA = vm.envAddress("KEEPER_EOA");
        address deployer  = vm.addr(pk);

        ArcoraDexRegistry reg = ArcoraDexRegistry(registry);
        ArcoraDexPool     pool = ArcoraDexPool(poolAddr);

        uint256 navBefore = pool.totalReservesUSD();
        console2.log("NAV before:", navBefore);

        uint256 n = reg.tokensLength();

        // Snapshot active token + current oracle list (read-only, no broadcast yet)
        address[] memory tokensActive = new address[](n);
        IChainlinkAggregator[] memory oraclesOld = new IChainlinkAggregator[](n);
        uint8[]   memory decsList   = new uint8[](n);
        uint256 activeCount = 0;
        for (uint256 i = 0; i < n; i++) {
            address t = reg.tokens(i);
            if (!reg.isActive(t)) continue;
            tokensActive[activeCount] = t;
            oraclesOld[activeCount]  = reg.tokenInfo(t).usdOracle;
            decsList[activeCount]    = reg.tokenInfo(t).decimals;
            activeCount++;
        }

        vm.startBroadcast(pk);

        for (uint256 i = 0; i < activeCount; i++) {
            address t = tokensActive[i];
            (, int256 currentAnswer, , , ) = oraclesOld[i].latestRoundData();
            uint8 oracleDec = oraclesOld[i].decimals();

            // initialAnswer at the same oracle decimals as v1 (8 here for MockChainlinkFeed)
            MockChainlinkFeedV2 newFeed = new MockChainlinkFeedV2(
                oracleDec,
                currentAnswer,
                keeperEOA,
                deployer
            );

            reg.setOracle(t, IChainlinkAggregator(address(newFeed)));

            console2.log("Migrated token:", t);
            console2.log("  old oracle:", address(oraclesOld[i]));
            console2.log("  new oracle:", address(newFeed));
            console2.log("  answer    :", uint256(currentAnswer));

            // Invariants per token
            require(MockChainlinkFeedV2(address(newFeed)).writer() == keeperEOA, "writer != keeper");
            require(MockChainlinkFeedV2(address(newFeed)).owner()  == deployer, "owner != deployer");
            require(address(reg.tokenInfo(t).usdOracle) == address(newFeed), "registry not updated");
        }

        vm.stopBroadcast();

        uint256 navAfter = pool.totalReservesUSD();
        console2.log("NAV after :", navAfter);

        // ±1 wei tolerance for rounding (should be exactly equal in practice — answers copied 1:1)
        uint256 navDiff = navAfter > navBefore ? navAfter - navBefore : navBefore - navAfter;
        require(navDiff <= 1, "NAV invariant broken");
    }
}
```

- [ ] **Step 3.2: Compile**

```bash
cd contracts && forge build 2>&1 | grep -E 'Error|error\[' | head -5
```

Expected: no output (no errors).

- [ ] **Step 3.3: Commit**

```bash
git add contracts/script/MigrateFeedsToV2.s.sol
git commit -m "$(cat <<'EOF'
feat(scripts): MigrateFeedsToV2 — broadcast feed redeploy + setOracle

For every active token in ArcoraDexRegistry: deploy a fresh
MockChainlinkFeedV2 (initialAnswer = current oracle latestAnswer,
writer = KEEPER_EOA, owner = deployer), then registry.setOracle to
re-point the slot. Asserts pool.totalReservesUSD() invariant and
per-feed writer/owner state.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `TransferTokenOwnershipToFaucet` script

**Files:**
- Create: `contracts/script/TransferTokenOwnershipToFaucet.s.sol`

- [ ] **Step 4.1: Write the script**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 }  from "forge-std/Script.sol";
import { ArcoraDexRegistry } from "../src/ArcoraDexRegistry.sol";
import { MintableERC20 }     from "../src/testnet/MintableERC20.sol";

/// @notice For each active token in the registry, transfer MintableERC20
/// ownership from the deployer to FAUCET_EOA. After this runs, the deployer
/// can no longer mint; the faucet EOA is the sole minter.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY  — broadcasts (must be current token owner)
///   REGISTRY_ADDR         — ArcoraDexRegistry (token list source)
///   FAUCET_EOA            — address of the new faucet EOA
contract TransferTokenOwnershipToFaucet is Script {
    function run() external {
        uint256 pk        = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address registry  = vm.envAddress("REGISTRY_ADDR");
        address faucetEOA = vm.envAddress("FAUCET_EOA");
        address deployer  = vm.addr(pk);

        ArcoraDexRegistry reg = ArcoraDexRegistry(registry);
        uint256 n = reg.tokensLength();

        vm.startBroadcast(pk);

        for (uint256 i = 0; i < n; i++) {
            address t = reg.tokens(i);
            if (!reg.isActive(t)) continue;

            MintableERC20 token = MintableERC20(t);
            require(token.owner() == deployer, "not current owner of token");

            token.transferOwnership(faucetEOA);
            require(token.owner() == faucetEOA, "transferOwnership did not land");

            console2.log("Token ownership transferred:", t);
            console2.log("  from:", deployer);
            console2.log("  to  :", faucetEOA);
        }

        vm.stopBroadcast();
    }
}
```

- [ ] **Step 4.2: Compile**

```bash
cd contracts && forge build 2>&1 | grep -E 'Error|error\[' | head -5
```

Expected: no output.

- [ ] **Step 4.3: Commit**

```bash
git add contracts/script/TransferTokenOwnershipToFaucet.s.sol
git commit -m "$(cat <<'EOF'
feat(scripts): TransferTokenOwnershipToFaucet — single-tx ownership move

For every active token in the registry, transferOwnership(deployer →
FAUCET_EOA). OZ Ownable v5 single-step (atomic, irreversible without
a follow-up call from FAUCET_EOA). Asserts current and post-state
owners.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Vault secret-fetch wrapper script

**Files:**
- Create: `ops/keepalive/fetch-keeper-secret.sh`

- [ ] **Step 5.1: Write the script**

```bash
#!/bin/bash
# fetch-keeper-secret.sh
# systemd ExecStartPre: pull keeper key from Vault into a tmpfs EnvironmentFile
# for the multi-feed-push.mjs run. Cleaned up by ExecStopPost in the unit file.
#
# Inputs:
#   /home/arcora/.vault/role_id     (chmod 400)
#   /home/arcora/.vault/secret_id   (chmod 400)
# Env:
#   KEEPER_TENANT  — "arcoradex" or "v07" (set per systemd unit via Environment=)
# Output:
#   /run/arcora/keeper.env  (mode 600, owned arcora:arcora)
#     containing: DEPLOYER_PRIVATE_KEY=0x...

set -euo pipefail
export VAULT_ADDR="http://127.0.0.1:8200"

ROLE_ID="$(cat /home/arcora/.vault/role_id)"
SECRET_ID="$(cat /home/arcora/.vault/secret_id)"

VAULT_TOKEN="$(vault write -field=token auth/approle/login \
    role_id="$ROLE_ID" secret_id="$SECRET_ID")"
export VAULT_TOKEN

TENANT="${KEEPER_TENANT:-arcoradex}"
KEEPER_KEY="$(vault kv get -field=KEEPER_PRIVATE_KEY "kv/arcora/keeper-${TENANT}")"

mkdir -p /run/arcora
chown arcora:arcora /run/arcora
chmod 700 /run/arcora

umask 077
cat > /run/arcora/keeper.env <<EOF
DEPLOYER_PRIVATE_KEY=$KEEPER_KEY
EOF
chown arcora:arcora /run/arcora/keeper.env
chmod 600 /run/arcora/keeper.env

unset VAULT_TOKEN KEEPER_KEY
```

- [ ] **Step 5.2: Mark executable**

```bash
chmod +x ops/keepalive/fetch-keeper-secret.sh
```

- [ ] **Step 5.3: Sanity-check script syntax (locally, won't actually run Vault)**

```bash
bash -n ops/keepalive/fetch-keeper-secret.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 5.4: Commit**

```bash
git add ops/keepalive/fetch-keeper-secret.sh
git commit -m "$(cat <<'EOF'
feat(ops): fetch-keeper-secret.sh — Vault AppRole → tmpfs EnvironmentFile

systemd ExecStartPre wrapper: logs into Vault via AppRole using
role_id + secret_id files in /home/arcora/.vault/, fetches the
KEEPER_PRIVATE_KEY for the configured tenant ("arcoradex" or "v07"),
and writes /run/arcora/keeper.env (mode 600, tmpfs) for the keeper
unit's EnvironmentFile=. ExecStopPost in the unit deletes the file.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: New systemd unit files (in repo)

**Files:**
- Modify: `ops/keepalive/arcoradex-feeds.service`
- Modify: `ops/keepalive/arcora-v07-feeds.service`

- [ ] **Step 6.1: Read current `arcoradex-feeds.service` to preserve unrelated bits**

```bash
cat ops/keepalive/arcoradex-feeds.service 2>/dev/null || echo "MISSING — check VPS path"
```

Note: this file may not exist locally if it was VPS-only. If missing, create it. If present, keep `Description=` and `Documentation=`.

- [ ] **Step 6.2: Write new arcoradex-feeds.service**

```ini
[Unit]
Description=ArcoraDEX — push CoinGecko prices to MockChainlinkFeedV2 contracts (Arc testnet)
Documentation=https://github.com/Kubudak90/arcoradex
After=network-online.target vault.service
Wants=network-online.target

[Service]
Type=oneshot
User=arcora
Group=arcora
WorkingDirectory=/home/arcora/arcoradex-feeds
Environment=KEEPER_TENANT=arcoradex
ExecStartPre=/home/arcora/bin/fetch-keeper-secret.sh
EnvironmentFile=/run/arcora/keeper.env
EnvironmentFile=/home/arcora/arcoradex-feeds/.env
ExecStart=/usr/bin/node /home/arcora/arcoradex-feeds/multi-feed-push.mjs
ExecStopPost=/bin/rm -f /run/arcora/keeper.env
Nice=10
StandardOutput=journal
StandardError=journal
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/run/arcora
NoNewPrivileges=true
```

- [ ] **Step 6.3: Write new arcora-v07-feeds.service (parallel structure, different tenant + paths + log prefix preserved by .env)**

```ini
[Unit]
Description=Arcora v0.7 — push CoinGecko prices to MockChainlinkFeed contracts (Arc testnet, legacy)
Documentation=https://github.com/Kubudak90/arcoradex
After=network-online.target vault.service
Wants=network-online.target

[Service]
Type=oneshot
User=arcora
Group=arcora
WorkingDirectory=/home/arcora/v07-feeds
Environment=KEEPER_TENANT=v07
ExecStartPre=/home/arcora/bin/fetch-keeper-secret.sh
EnvironmentFile=/run/arcora/keeper.env
EnvironmentFile=/home/arcora/v07-feeds/.env
ExecStart=/usr/bin/node /home/arcora/v07-feeds/multi-feed-push.mjs
ExecStopPost=/bin/rm -f /run/arcora/keeper.env
Nice=10
StandardOutput=journal
StandardError=journal
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/run/arcora
NoNewPrivileges=true
```

Note: `EnvironmentFile=` directives load in order — Vault-fetched `keeper.env` first (provides `DEPLOYER_PRIVATE_KEY`), then per-tenant `.env` (provides `FEED_*`, `POOL_ADDR`, `COINGECKO_API_KEY`, etc.). Both files are required.

- [ ] **Step 6.4: Lint (basic)**

```bash
grep -E '^(User|Group|EnvironmentFile|ExecStart)=' ops/keepalive/arcoradex-feeds.service
grep -E '^(User|Group|EnvironmentFile|ExecStart)=' ops/keepalive/arcora-v07-feeds.service
```

Expected: each file shows the four directives with the `arcora` user and the two EnvironmentFile lines.

- [ ] **Step 6.5: Commit**

```bash
git add ops/keepalive/arcoradex-feeds.service ops/keepalive/arcora-v07-feeds.service
git commit -m "$(cat <<'EOF'
feat(ops): keeper systemd units run as arcora user with Vault fetched key

Both keepers now:
- run as User=arcora (non-root LPU)
- fetch keeper key via ExecStartPre=/home/arcora/bin/fetch-keeper-secret.sh
- load /run/arcora/keeper.env (Vault-provided) plus the local
  per-tenant .env (feed addresses, RPC, etc.)
- delete /run/arcora/keeper.env on ExecStopPost
- enable PrivateTmp, ProtectSystem=strict, NoNewPrivileges

WorkingDirectory moved from /root/* to /home/arcora/* (filesystem
move handled in cutover task, not this commit).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Push branch + open PR for code review

- [ ] **Step 7.1: Push**

```bash
git push -u origin audit/group-b-key-separation
```

- [ ] **Step 7.2: Open PR**

```bash
gh pr create --title "audit(group-b): key separation — feed v2 + scripts + LPU systemd units" --body "$(cat <<'EOF'
## Summary

Phase 1 (code-only) of audit Group B from the 2026-05-09 hardening pass.
Adds the building blocks for splitting the single-deployer-EOA control of
testnet ArcoraDEX into 3 roles (governance / keeper / faucet).

- New `MockChainlinkFeedV2` (Ownable2Step + writer-role separated from owner)
- Migration scripts: `MigrateFeedsToV2`, `TransferTokenOwnershipToFaucet`
- Vault secret-fetch wrapper (`fetch-keeper-secret.sh`)
- Updated systemd units: `User=arcora`, Vault-backed EnvironmentFile, hardening directives

This PR is **code-only**. The live cutover (broadcasting migration scripts,
moving VPS dirs to /home/arcora, switching to Vault, Vercel env rotation,
SSH lockdown) happens in Phase 2 against testnet, ordered per the spec's
T-0 → T-10 sequence.

Spec: `docs/superpowers/specs/2026-05-09-key-separation-design.md`
Plan: `docs/superpowers/plans/2026-05-09-key-separation.md`

## Test plan

- [x] `forge test` — 74 tests pass (68 baseline + 6 new for MockChainlinkFeedV2)
- [x] `forge build` clean
- [x] `bash -n` on `fetch-keeper-secret.sh`
- [ ] Phase 2 cutover (separate operational PR/rollout doc)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 7.3: Wait for PR merge before proceeding to Phase 2**

Phase 2 (live cutover) operates against the merged code on `main`. Do not start Phase 2 until reviewer approves and merges the PR. Track the PR URL.

---

## Phase 2 — Live cutover (ops)

> **Important:** Phase 2 produces no commits to source code. It executes on testnet + VPS + Vercel and writes a single rollout-status doc at the end. The plan target is one operator, one terminal session, ~6 hours.

### Task 8: T-0.5 — VPS Vault prep + key generation + AppRole

**Pre-condition:** Phase 1 PR merged to `main`. Local checkout on `main` and clean.

- [ ] **Step 8.1: Generate keeper EOA**

```bash
cast wallet new --json > /tmp/keeper-eoa.json
chmod 600 /tmp/keeper-eoa.json
KEEPER_ADDR=$(jq -r '.[0].address' /tmp/keeper-eoa.json)
KEEPER_PK=$(jq -r '.[0].private_key' /tmp/keeper-eoa.json)
echo "KEEPER_ADDR=$KEEPER_ADDR"
```

Expected: 0x-prefixed 40-hex address. Save `/tmp/keeper-eoa.json` to your local password manager / encrypted vault file.

- [ ] **Step 8.2: Generate faucet EOA**

```bash
cast wallet new --json > /tmp/faucet-eoa.json
chmod 600 /tmp/faucet-eoa.json
FAUCET_ADDR=$(jq -r '.[0].address' /tmp/faucet-eoa.json)
FAUCET_PK=$(jq -r '.[0].private_key' /tmp/faucet-eoa.json)
echo "FAUCET_ADDR=$FAUCET_ADDR"
```

- [ ] **Step 8.3: SSH to VPS and verify Vault state**

```bash
ssh root@194.163.136.1 "
export VAULT_ADDR=http://127.0.0.1:8200
vault status
"
```

Expected: `Initialized: true`, `Sealed: false`. If `Sealed: true`, abort and bring up Vault first (out of scope here — coordinate with whoever set up Vault). If `vault: command not found`, install: `apt-get install -y vault` then re-check.

- [ ] **Step 8.4: SSH to VPS and create LPU + dirs (idempotent)**

```bash
ssh root@194.163.136.1 "
id arcora >/dev/null 2>&1 || useradd -m -s /bin/bash arcora
mkdir -p /home/arcora/{arcoradex-feeds,v07-feeds,bin,.vault}
chown -R arcora:arcora /home/arcora/
"
```

- [ ] **Step 8.5: Copy fetch-keeper-secret.sh to VPS**

```bash
scp ops/keepalive/fetch-keeper-secret.sh root@194.163.136.1:/home/arcora/bin/fetch-keeper-secret.sh
ssh root@194.163.136.1 "chown arcora:arcora /home/arcora/bin/fetch-keeper-secret.sh && chmod 750 /home/arcora/bin/fetch-keeper-secret.sh"
```

- [ ] **Step 8.6: Set up Vault KV-v2 + AppRole on VPS**

```bash
ssh root@194.163.136.1 "
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=\$(cat /root/.vault-token 2>/dev/null || echo '')
# If VAULT_TOKEN is empty, you'll need to log in: 'vault login -method=token' first.
# Idempotent steps (re-runnable):
vault secrets list | grep -q '^kv/' || vault secrets enable -path=kv -version=2 kv
vault kv put kv/arcora/keeper-arcoradex KEEPER_PRIVATE_KEY=$KEEPER_PK
vault kv put kv/arcora/keeper-v07       KEEPER_PRIVATE_KEY=$KEEPER_PK
vault auth list | grep -q '^approle/' || vault auth enable approle
cat <<'POL' | vault policy write keeper-feeds -
path \"kv/data/arcora/keeper-arcoradex\" { capabilities = [\"read\"] }
path \"kv/data/arcora/keeper-v07\"       { capabilities = [\"read\"] }
POL
vault write auth/approle/role/keeper-feeds \
    token_policies=keeper-feeds \
    token_ttl=10m \
    token_max_ttl=20m \
    secret_id_ttl=720h \
    secret_id_num_uses=0
vault read -field=role_id auth/approle/role/keeper-feeds/role-id > /home/arcora/.vault/role_id
vault write -force -field=secret_id auth/approle/role/keeper-feeds/secret-id > /home/arcora/.vault/secret_id
chown -R arcora:arcora /home/arcora/.vault
chmod 400 /home/arcora/.vault/role_id /home/arcora/.vault/secret_id
"
```

- [ ] **Step 8.7: Verify Vault flow end-to-end (as `arcora` user)**

```bash
ssh root@194.163.136.1 "sudo -u arcora /home/arcora/bin/fetch-keeper-secret.sh && cat /run/arcora/keeper.env && rm /run/arcora/keeper.env"
```

Expected: `DEPLOYER_PRIVATE_KEY=0x<KEEPER_PK_HEX>` printed. `keeper.env` removed by the explicit rm.

- [ ] **Step 8.8: Cleanup local key files (keep encrypted backup elsewhere)**

```bash
# Keys now in: VPS Vault (keeper) + your password manager / local encrypted vault (both)
# Local /tmp/ files still hold them — encrypt or move:
mv /tmp/keeper-eoa.json /tmp/faucet-eoa.json ~/.arcora-secrets/
chmod 600 ~/.arcora-secrets/*.json
```

(Adjust `~/.arcora-secrets/` to your preferred local secrets dir. The point: clear `/tmp/`.)

---

### Task 9: T-1 — Fund keeper + faucet EOAs

- [ ] **Step 9.1: Send 2 ETH from deployer to keeper**

```bash
export DEPLOYER_PK=<deployer key from local secure storage>
export ARC_TESTNET_RPC=https://rpc.testnet.arc.network
cast send "$KEEPER_ADDR" --value 2ether --rpc-url $ARC_TESTNET_RPC --private-key "$DEPLOYER_PK"
```

- [ ] **Step 9.2: Send 2 ETH from deployer to faucet**

```bash
cast send "$FAUCET_ADDR" --value 2ether --rpc-url $ARC_TESTNET_RPC --private-key "$DEPLOYER_PK"
```

- [ ] **Step 9.3: Verify balances**

```bash
cast balance "$KEEPER_ADDR" --rpc-url $ARC_TESTNET_RPC --ether
cast balance "$FAUCET_ADDR" --rpc-url $ARC_TESTNET_RPC --ether
```

Expected: ≥ 1.99 ETH each.

---

### Task 10: T-2 + T-3 — Stop existing timers, run feed migration

- [ ] **Step 10.1: Stop both keeper timers on VPS**

```bash
ssh root@194.163.136.1 "
systemctl stop arcora-v07-feeds.timer arcoradex-feeds.timer
systemctl is-active arcora-v07-feeds.timer
systemctl is-active arcoradex-feeds.timer
"
```

Expected: both `inactive`.

- [ ] **Step 10.2: Capture pool NAV pre-migration (sanity)**

```bash
export REGISTRY_ADDR=0x920E3E59DD37Be3D9D3750D7B912A9dd08db0D29
export POOL_ADDR=0x3051d24D771bAF44031571544a9159578035D0c5
NAV_PRE=$(cast call "$POOL_ADDR" "totalReservesUSD()(uint256)" --rpc-url "$ARC_TESTNET_RPC" | awk '{print $1}')
echo "NAV pre: $NAV_PRE"
```

- [ ] **Step 10.3: Broadcast MigrateFeedsToV2**

```bash
cd contracts
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PK" \
REGISTRY_ADDR="$REGISTRY_ADDR" \
POOL_ADDR="$POOL_ADDR" \
KEEPER_EOA="$KEEPER_ADDR" \
forge script script/MigrateFeedsToV2.s.sol --rpc-url "$ARC_TESTNET_RPC" --broadcast --slow 2>&1 | tee /tmp/migrate-feeds.log
```

Expected log contains 7 "Migrated token:" lines and `NAV after :` line. Script reverts if any invariant fails — re-run after diagnosing.

- [ ] **Step 10.4: Verify migration on-chain**

```bash
NAV_POST=$(cast call "$POOL_ADDR" "totalReservesUSD()(uint256)" --rpc-url "$ARC_TESTNET_RPC" | awk '{print $1}')
echo "NAV post: $NAV_POST (was $NAV_PRE)"

# For each of the 7 tokens, fetch the new oracle from registry and confirm writer
for i in $(seq 0 6); do
  TOKEN=$(cast call "$REGISTRY_ADDR" "tokens(uint256)(address)" $i --rpc-url "$ARC_TESTNET_RPC")
  ORACLE=$(cast call "$REGISTRY_ADDR" "tokenInfo(address)(uint8,bool,address,uint16)" "$TOKEN" --rpc-url "$ARC_TESTNET_RPC" | awk 'NR==3{print $1}')
  WRITER=$(cast call "$ORACLE" "writer()(address)" --rpc-url "$ARC_TESTNET_RPC")
  echo "slot $i token=$TOKEN oracle=$ORACLE writer=$WRITER"
done
```

Expected: NAV diff ≤ 1 wei. Each oracle's `writer` matches `$KEEPER_ADDR`.

If `writer()` reverts on a slot — that slot is still pointing at the old v1 feed (script partial-applied). Re-run `MigrateFeedsToV2` (idempotent for already-migrated slots? — no, it'd deploy a second v2 feed for already-migrated ones. Instead: rollback partial via `setOracle(token, oldOracle)` for affected tokens, fix the issue, re-run).

---

### Task 11: T-3.5 — CRITICAL keeper first-fire (60-min hard deadline from T-3)

- [ ] **Step 11.1: From local laptop, fire the keeper script with the keeper EOA's key**

The keeper script currently lives in `ops/keepalive/multi-feed-push.mjs` in the repo. We can run it locally — it needs the same env vars the VPS unit uses.

```bash
cd ops/keepalive
[ -f node_modules/.package-lock.json ] || npm install

# Build env from the VPS arcoradex-feeds .env (FEED_* + POOL_ADDR + COINGECKO_API_KEY)
# plus the keeper EOA private key.
ssh root@194.163.136.1 "cat /home/arcora/arcoradex-feeds/.env" > /tmp/arcoradex.env
DEPLOYER_PRIVATE_KEY="$KEEPER_PK" \
$(grep -v '^DEPLOYER_PRIVATE_KEY=' /tmp/arcoradex.env | xargs) \
node multi-feed-push.mjs 2>&1 | tee /tmp/keeper-first-fire.log
rm /tmp/arcoradex.env
```

Expected log: `done updated=N skipped=M errored=0`. `N + M = 7`.

- [ ] **Step 11.2: Verify all 7 feeds fresh on-chain**

```bash
NOW=$(cast block latest --rpc-url "$ARC_TESTNET_RPC" --field timestamp)
for i in $(seq 0 6); do
  TOKEN=$(cast call "$REGISTRY_ADDR" "tokens(uint256)(address)" $i --rpc-url "$ARC_TESTNET_RPC")
  ORACLE=$(cast call "$REGISTRY_ADDR" "tokenInfo(address)(uint8,bool,address,uint16)" "$TOKEN" --rpc-url "$ARC_TESTNET_RPC" | awk 'NR==3{print $1}')
  TS=$(cast call "$ORACLE" "latestUpdatedAt()(uint256)" --rpc-url "$ARC_TESTNET_RPC" | awk '{print $1}')
  AGE=$(( NOW - TS ))
  echo "slot $i age=${AGE}s"
done
```

Expected: each age < 600s (10 min) — well below the 1-hour MAX_STALE_SECONDS.

If any `errored > 0` from Step 11.1, fix the cause (RPC issue, env issue, CoinGecko 429) and re-run before the 60-min hard deadline expires. Worst case, the new feeds were deployed at T-3 with constructor timestamps — that grace window is also 60 min.

---

### Task 12: T-4 — Move dirs to /home/arcora + reload systemd

- [ ] **Step 12.1: Move existing keeper dirs from /root to /home/arcora**

```bash
ssh root@194.163.136.1 "
rsync -a /root/arcoradex-feeds/ /home/arcora/arcoradex-feeds/
rsync -a /root/arcora-v07-feeds/ /home/arcora/v07-feeds/
chown -R arcora:arcora /home/arcora/arcoradex-feeds /home/arcora/v07-feeds
chmod 700 /home/arcora/arcoradex-feeds /home/arcora/v07-feeds
chmod 600 /home/arcora/arcoradex-feeds/.env /home/arcora/v07-feeds/.env

# Strip DEPLOYER_PRIVATE_KEY from .env files — Vault provides it now.
for f in /home/arcora/arcoradex-feeds/.env /home/arcora/v07-feeds/.env; do
  sed -i '/^DEPLOYER_PRIVATE_KEY=/d' \$f
done
"
```

- [ ] **Step 12.2: Copy new systemd unit files to VPS**

```bash
scp ops/keepalive/arcoradex-feeds.service root@194.163.136.1:/etc/systemd/system/arcoradex-feeds.service
scp ops/keepalive/arcora-v07-feeds.service root@194.163.136.1:/etc/systemd/system/arcora-v07-feeds.service
```

- [ ] **Step 12.3: Reload systemd**

```bash
ssh root@194.163.136.1 "systemctl daemon-reload && systemctl status arcoradex-feeds.service --no-pager | head -10"
```

Expected: Loaded line shows `arcora` user via WorkingDirectory; no enable/start yet (`inactive`).

---

### Task 13: T-5 + T-6 — Switch keeper to systemd-Vault flow + re-enable timers

- [ ] **Step 13.1: Manual one-shot of arcoradex-feeds (verify Vault flow end-to-end)**

```bash
ssh root@194.163.136.1 "
systemctl start arcoradex-feeds.service
journalctl -u arcoradex-feeds.service --no-pager -n 25 --since '2 min ago' | tail -20
systemctl show arcoradex-feeds.service -p Result,ExecMainStatus --no-pager
"
```

Expected: journal shows `[arcoradex-feeds] ... done updated=N skipped=M errored=0` and service `Result=success`. If `errored > 0`, diagnose (most likely Vault auth or feed env mismatch). The `errored > 0` guard from PR #1 will make this fail loudly.

- [ ] **Step 13.2: Manual one-shot of arcora-v07-feeds**

```bash
ssh root@194.163.136.1 "
systemctl start arcora-v07-feeds.service
journalctl -u arcora-v07-feeds.service --no-pager -n 25 --since '2 min ago' | tail -20
systemctl show arcora-v07-feeds.service -p Result,ExecMainStatus --no-pager
"
```

Expected: same as 13.1 but for v07 tenant.

- [ ] **Step 13.3: Verify on-chain that the writer was indeed keeper EOA**

Pick one tx hash from the journal in Step 13.1. Check sender:

```bash
TX=<hash from journal>
cast tx "$TX" --rpc-url "$ARC_TESTNET_RPC" --json | jq -r '.from'
```

Expected: matches `$KEEPER_ADDR` (lower-cased).

- [ ] **Step 13.4: Re-enable both timers**

```bash
ssh root@194.163.136.1 "
systemctl enable --now arcora-v07-feeds.timer
systemctl enable --now arcoradex-feeds.timer
systemctl status arcora-v07-feeds.timer arcoradex-feeds.timer --no-pager | grep -E 'Active|Trigger'
"
```

Expected: both `Active: active (waiting)`, next `Trigger:` 30 min in the future.

---

### Task 14: T-7 — Token ownership transfer

- [ ] **Step 14.1: Broadcast TransferTokenOwnershipToFaucet**

```bash
cd contracts
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PK" \
REGISTRY_ADDR="$REGISTRY_ADDR" \
FAUCET_EOA="$FAUCET_ADDR" \
forge script script/TransferTokenOwnershipToFaucet.s.sol --rpc-url "$ARC_TESTNET_RPC" --broadcast --slow 2>&1 | tee /tmp/transfer-token-ownership.log
```

Expected log: 7 "Token ownership transferred:" lines.

- [ ] **Step 14.2: Verify ownership on-chain**

```bash
for i in $(seq 0 6); do
  TOKEN=$(cast call "$REGISTRY_ADDR" "tokens(uint256)(address)" $i --rpc-url "$ARC_TESTNET_RPC")
  OWNER=$(cast call "$TOKEN" "owner()(address)" --rpc-url "$ARC_TESTNET_RPC")
  echo "token=$TOKEN owner=$OWNER"
done
```

Expected: all 7 owners equal `$FAUCET_ADDR` (case-insensitive).

- [ ] **Step 14.3: Verify deployer can no longer mint**

```bash
ANY_TOKEN=$(cast call "$REGISTRY_ADDR" "tokens(uint256)(address)" 0 --rpc-url "$ARC_TESTNET_RPC")
cast send "$ANY_TOKEN" "mint(address,uint256)" "$DEPLOYER_PK_ADDR" 1000000 --rpc-url "$ARC_TESTNET_RPC" --private-key "$DEPLOYER_PK" 2>&1 | head -5
```

Expected: revert with `OwnableUnauthorizedAccount(...)`.

(`$DEPLOYER_PK_ADDR` = `cast wallet address $DEPLOYER_PK` — set before this step.)

---

### Task 15: T-8 — Vercel faucet env cutover

- [ ] **Step 15.1: Find the linked Vercel project**

```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool
vercel link --yes 2>&1 | tail -5  # only if not already linked
```

- [ ] **Step 15.2: Replace FAUCET_PRIVATE_KEY in production env**

Use the dashboard or CLI. Dashboard is easier (no shell quoting) — go to Project → Settings → Environment Variables, edit `FAUCET_PRIVATE_KEY` for the `Production` and `Preview` envs, paste the new faucet EOA key (`$FAUCET_PK`), save.

CLI alternative:

```bash
vercel env rm FAUCET_PRIVATE_KEY production --yes
vercel env rm FAUCET_PRIVATE_KEY preview --yes
# Add via stdin (Vercel CLI prompts for value):
printf "%s\n" "$FAUCET_PK" | vercel env add FAUCET_PRIVATE_KEY production
printf "%s\n" "$FAUCET_PK" | vercel env add FAUCET_PRIVATE_KEY preview
```

- [ ] **Step 15.3: Trigger production redeploy**

```bash
vercel --prod 2>&1 | tail -5
```

Wait for deploy to ready (~2-5 min). The deploy URL output → check it's `Ready`.

- [ ] **Step 15.4: Smoke-test faucet**

```bash
TEST_RECIPIENT=$(cast wallet new --json | jq -r '.[0].address')
curl -X POST https://swap.arcorapay.xyz/api/faucet \
  -H "Content-Type: application/json" \
  -d "{\"address\":\"$TEST_RECIPIENT\"}" 2>&1 | jq .
```

Expected: `{"ok":true, "recipient":"0x...", "txHashes":{...}}` with 7 hashes.

- [ ] **Step 15.5: Verify a faucet mint tx was signed by faucet EOA, not deployer**

```bash
ANY_HASH=<one tx hash from response>
cast tx "$ANY_HASH" --rpc-url "$ARC_TESTNET_RPC" --json | jq -r '.from'
```

Expected: matches `$FAUCET_ADDR`.

---

### Task 16: T-9 — SSH lockdown + key cleanup

- [ ] **Step 16.1: Verify your key-based SSH still works**

```bash
ssh -o PubkeyAuthentication=yes -o PasswordAuthentication=no root@194.163.136.1 "whoami"
```

Expected: `root`. **DO NOT proceed to next step if this fails** — you'd lock yourself out.

- [ ] **Step 16.2: Disable SSH password auth**

```bash
ssh root@194.163.136.1 "
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sshd -t && systemctl reload ssh
grep ^PasswordAuthentication /etc/ssh/sshd_config
"
```

Expected: `PasswordAuthentication no`.

- [ ] **Step 16.3: Verify password SSH is rejected (from your machine, expect failure)**

```bash
ssh -o PubkeyAuthentication=no -o PasswordAuthentication=yes -o NumberOfPasswordPrompts=1 root@194.163.136.1 "whoami" 2>&1 | head -5
```

Expected: `Permission denied (publickey).` or similar — NO password prompt accepted.

- [ ] **Step 16.4: Remove DEPLOYER_PRIVATE_KEY remnants from VPS**

```bash
ssh root@194.163.136.1 "
grep -rl 'DEPLOYER_PRIVATE_KEY' /home/arcora /root 2>/dev/null
"
```

Expected: empty (we already stripped in 12.1; this is a final sweep). If any matches appear, inspect and remove the line(s) — they may be backups or staging.

- [ ] **Step 16.5: Ensure deployer key is no longer used by Vercel env**

(Already handled in Step 15.2; this is a sanity verify.)

```bash
vercel env ls production 2>&1 | grep FAUCET_PRIVATE_KEY
```

Expected: shows the env exists with timestamp from Step 15.2 (recent).

---

### Task 17: T-10 — End-to-end smoke + write rollout doc

- [ ] **Step 17.1: Wait for one auto-fire of each timer**

Trigger time was set in Step 13.4. Wait until both fire (≤ 30 min from now). Watch:

```bash
ssh root@194.163.136.1 "
journalctl -u arcoradex-feeds.service --since '30 min ago' --no-pager | grep -E 'Starting|done|errored|Failed|Finished'
journalctl -u arcora-v07-feeds.service --since '30 min ago' --no-pager | grep -E 'Starting|done|errored|Failed|Finished'
"
```

Expected: each unit has at least one `Starting` → `done updated=N skipped=M errored=0` → `Finished` triplet from the last 30 min.

- [ ] **Step 17.2: Pool quote sanity**

```bash
USDC=0x3BFa09fF6467639f0981948385bA1018Ac07d22C
EURC=0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD
cast call "$POOL_ADDR" "totalReservesUSD()(uint256)" --rpc-url "$ARC_TESTNET_RPC"
```

Expected: non-zero (matches NAV from earlier ±dust + any swap activity in window).

- [ ] **Step 17.3: Write rollout doc**

Create `docs/rollouts/2026-05-09-key-separation.md`:

```markdown
# Key separation cutover — 2026-05-09

**Branch / spec / plan**
- Spec: `docs/superpowers/specs/2026-05-09-key-separation-design.md`
- Plan: `docs/superpowers/plans/2026-05-09-key-separation.md`
- Code PR: <URL of merged audit/group-b-key-separation PR>

## EOAs (post-cutover)

| Role | Address |
|---|---|
| Deployer / governance (unchanged) | `0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b` |
| Keeper (new) | `<KEEPER_ADDR>` |
| Faucet (new) | `<FAUCET_ADDR>` |

## New feed contracts (per token slot)

| Slot | Token | New oracle (V2) | Constructor block |
|------|-------|-----------------|-------------------|
| 0 | USDC | `0x...` | `<block #>` |
| ... | ... | ... | ... |

(7 rows, fill from Step 10.4 output.)

## Migration tx hashes

- MigrateFeedsToV2 broadcast: `<broadcast file path>` or first tx hash
- Keeper first-fire (T-3.5): see `/tmp/keeper-first-fire.log`
- TransferTokenOwnershipToFaucet broadcast: `<...>`

## Verification snapshot

- Pool NAV pre/post: `<NAV_PRE>` / `<NAV_POST>` (delta wei: `<diff>`)
- All 7 feeds aged < 60s post-cutover
- All 7 token owners == `<FAUCET_ADDR>`
- VPS systemd both timers `active (waiting)`, running as `arcora`
- `/run/arcora/keeper.env` only exists during oneshot execution
- SSH password auth disabled

## Rollback inventory (if needed)

- Old MockChainlinkFeed addresses: `<list>` (pre-migration `setOracle` targets)
- Pre-migration token owner: `0xe8E5...754b` (deployer)
- Pre-migration `FAUCET_PRIVATE_KEY` value: stored in offline backup as `deployer-key-2026-05-09.bak`
```

- [ ] **Step 17.4: Commit rollout doc to main (post-cutover, on a small branch)**

```bash
cd /Users/huseyinarslan/Desktop/arcora-v0.7-shared-vault-pool
git checkout -b docs/key-separation-rollout-2026-05-09
git add docs/rollouts/2026-05-09-key-separation.md
git commit -m "$(cat <<'EOF'
docs(rollouts): 2026-05-09 key separation cutover record

Records EOAs, migration tx hashes, post-cutover verification
snapshot, and rollback inventory for the audit Group B cutover.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin docs/key-separation-rollout-2026-05-09
gh pr create --title "docs: 2026-05-09 key separation cutover record" --body "Post-cutover snapshot per the audit Group B plan."
```

- [ ] **Step 17.5: Final: archive deployer key offline**

Move local deployer key from any disk-resident `.env` / encrypted file to a USB / hardware wallet / 1Password vault. Delete plaintext copies from `/tmp/`, shell history, etc.

```bash
# Audit shell history for the deployer key value (replace 0x... with first 8 chars)
grep -r '0x<first 8 chars>' ~/.zsh_history ~/.bash_history 2>/dev/null
```

If matches: clear history (`history -c && history -w`), or rotate the deployer key if it was visible to others.

---

## Done

After Task 17, audit Group B is complete. The remaining audit groups (A — FoT guard, C — oracle resilience, D — faucet abuse mitigation, E — hygiene) are independent and queued for separate brainstorming → spec → plan cycles.

**Verification of "done":**
- All 17 tasks above checked off.
- `forge test` passes (74+ tests).
- Both keeper systemd units green for ≥ 1 auto-fire cycle.
- Faucet smoke claim succeeds; tx signed by faucet EOA.
- Deployer key not present anywhere on VPS or in Vercel env.
- Rollout doc committed.
