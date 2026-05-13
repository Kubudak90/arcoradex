# Post-Cutover Audit Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three P2/P3 footguns surfaced in the 2026-05-12 post-cutover audit: decommission the legacy v07 keeper systemd unit, rename `DEPLOYER_PRIVATE_KEY` → `KEEPER_PRIVATE_KEY` end-to-end in keeper ops, and add a zero-address guard to `MigrateFeedsToV2.s.sol`.

**Architecture:** Five repo-local tasks (one per change category plus memory + final verification), then one VPS rollout task. All repo work is on branch `audit/2026-05-12-post-cutover-cleanup` (already created; spec at `docs/superpowers/specs/2026-05-12-audit-cleanup-design.md`). The rename is shipped as a single commit because the fetch script writes the env var name and the keeper script reads it — they must move together to avoid a partial-deploy footgun.

**Tech Stack:** Bash + Node.js (keeper scripts), systemd (units), Solidity 0.8.26 (Foundry script), Markdown (docs/memory).

---

## File Structure

**Deleted from repo:**
- `ops/keepalive/arcora-v07-feeds.service`

**Modified in repo:**
- `ops/keepalive/fetch-keeper-secret.sh` — lines 13 (comment), 34 (heredoc body)
- `ops/keepalive/multi-feed-push.mjs` — lines 120 (env read), 122 (error message)
- `ops/keepalive/.env.example` — remove line 6, update header comment
- `contracts/script/MigrateFeedsToV2.s.sol` — insert guard after line 23

**Modified outside repo (operator memory):**
- `~/.claude/projects/-Users-huseyinarslan-Desktop-arcora-v0-7-shared-vault-pool/memory/v07_testnet_deploy.md` — append a status line noting the systemd unit was removed from the repo

**Not touched (deliberately):**
- `ops/keepalive/arcoradex-feeds.service` — already correct after the cutover; EnvironmentFile order remains as-is since the rename eliminates the name collision.
- `ops/keepalive/arcoradex-feeds.timer` — unchanged.
- `contracts/src/testnet/MockChainlinkFeedV2.sol` — script-level guard is sufficient per the spec.

---

### Task 1: Decommission v07 keeper systemd unit

**Files:**
- Delete: `ops/keepalive/arcora-v07-feeds.service`

- [ ] **Step 1: Confirm starting state**

Run:
```bash
git branch --show-current
```
Expected: `audit/2026-05-12-post-cutover-cleanup`

Run:
```bash
ls ops/keepalive/arcora-v07-feeds.service
```
Expected: file exists.

- [ ] **Step 2: Confirm no other repo file references the legacy unit name**

Run:
```bash
grep -rn "arcora-v07-feeds" --include="*.sh" --include="*.mjs" --include="*.service" --include="*.timer" --include="*.json" --include="*.example" ops/ contracts/ apps/ sdk/ 2>/dev/null
```
Expected: zero matches. If any non-doc reference appears, STOP and flag — the deletion would break a live linkage.

(Doc references in `docs/`, `README.md`, the spec, and the auto-memory remain as historical record and are out of scope for this task.)

- [ ] **Step 3: Delete the file**

Run:
```bash
git rm ops/keepalive/arcora-v07-feeds.service
```
Expected: `rm 'ops/keepalive/arcora-v07-feeds.service'`

- [ ] **Step 4: Verify staged deletion**

Run:
```bash
git status -s
```
Expected: a line of the form `D  ops/keepalive/arcora-v07-feeds.service` (and nothing else staged yet for this branch).

- [ ] **Step 5: Commit**

Run:
```bash
git commit -m "$(cat <<'EOF'
chore(ops): decommission legacy arcora-v07-feeds systemd unit

v07 keeper was disabled on 2026-05-10 during the key-separation cutover.
VPS audit on 2026-05-12 confirmed the unit is not loaded in systemd
(arcora-v07-feeds.timer reports not-found) and /home/arcora/v07-feeds/
does not exist. Removing the unit file from the repo eliminates the
latent /run/arcora/keeper.env collision risk if both units were ever
re-enabled.

Spec: docs/superpowers/specs/2026-05-12-audit-cleanup-design.md §3.1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: `1 file changed, NN deletions(-)`.

---

### Task 2: Rename `DEPLOYER_PRIVATE_KEY` → `KEEPER_PRIVATE_KEY` in keeper ops

**Files:**
- Modify: `ops/keepalive/fetch-keeper-secret.sh` (lines 13 + 34)
- Modify: `ops/keepalive/multi-feed-push.mjs` (lines 120 + 122)
- Modify: `ops/keepalive/.env.example` (remove line 6, update header)

This is a single logical change shipped as one commit. The fetch script's output variable name and the keeper script's input variable name MUST stay in sync — if either lands without the other, the VPS timer breaks on the next tick.

- [ ] **Step 1: Edit `fetch-keeper-secret.sh` comment**

In `ops/keepalive/fetch-keeper-secret.sh`, find:
```bash
#     containing: DEPLOYER_PRIVATE_KEY=0x...
```
Replace with:
```bash
#     containing: KEEPER_PRIVATE_KEY=0x...
```

- [ ] **Step 2: Edit `fetch-keeper-secret.sh` heredoc body**

In `ops/keepalive/fetch-keeper-secret.sh`, find:
```bash
cat > /run/arcora/keeper.env <<EOF
DEPLOYER_PRIVATE_KEY=$KEEPER_KEY
EOF
```
Replace with:
```bash
cat > /run/arcora/keeper.env <<EOF
KEEPER_PRIVATE_KEY=$KEEPER_KEY
EOF
```

- [ ] **Step 3: Bash syntax check the fetch script**

Run:
```bash
bash -n ops/keepalive/fetch-keeper-secret.sh
```
Expected: no output, exit 0.

- [ ] **Step 4: Edit `multi-feed-push.mjs` env read**

In `ops/keepalive/multi-feed-push.mjs`, find:
```js
    const pk = process.env.DEPLOYER_PRIVATE_KEY;
    if (!pk) {
        log("DEPLOYER_PRIVATE_KEY missing — abort");
        process.exit(2);
    }
```
Replace with:
```js
    const pk = process.env.KEEPER_PRIVATE_KEY;
    if (!pk) {
        log("KEEPER_PRIVATE_KEY missing — abort");
        process.exit(2);
    }
```

- [ ] **Step 5: Node syntax check the keeper script**

Run:
```bash
node --check ops/keepalive/multi-feed-push.mjs
```
Expected: no output, exit 0.

- [ ] **Step 6: Edit `.env.example` — remove the deployer-key line and refresh the header**

The current file (8 keys, 20 lines) starts with:
```bash
# Arcora v0.7 multi-feed keeper — required env vars.
#
# Copy to .env on the VPS and fill in real values. Never commit the .env.

ARC_TESTNET_RPC=https://rpc.testnet.arc.network
DEPLOYER_PRIVATE_KEY=0x...

# Optional: only needed if you have a CoinGecko Pro API key. ...
```

Make two edits:

(a) Replace the header block (lines 1–3):
```bash
# Arcora v0.7 multi-feed keeper — required env vars.
#
# Copy to .env on the VPS and fill in real values. Never commit the .env.
```
With:
```bash
# ArcoraDEX multi-feed keeper — required env vars for /home/arcora/arcoradex-feeds/.env.
#
# Copy to .env on the VPS and fill in real values. Never commit the .env.
#
# NOTE: The keeper private key is NOT listed here. It is fetched from Vault
# at unit start by ops/keepalive/fetch-keeper-secret.sh and exposed as
# KEEPER_PRIVATE_KEY in /run/arcora/keeper.env (tmpfs, deleted on stop).
# Do not add KEEPER_PRIVATE_KEY or DEPLOYER_PRIVATE_KEY to this file.
```

(b) Delete the existing `DEPLOYER_PRIVATE_KEY=0x...` line entirely (was line 6).

- [ ] **Step 7: Verify rename is complete across `ops/keepalive/`**

Run:
```bash
grep -rn "DEPLOYER_PRIVATE_KEY" ops/keepalive/
```
Expected: zero matches.

Run:
```bash
grep -rn "KEEPER_PRIVATE_KEY" ops/keepalive/
```
Expected: three matches — `fetch-keeper-secret.sh` comment, `fetch-keeper-secret.sh` heredoc body, `multi-feed-push.mjs` env read. (`.env.example` mentions `KEEPER_PRIVATE_KEY` in the note from Step 6, so this may show four — that's also fine, the count is a sanity check, not a hard assertion.)

- [ ] **Step 8: Stage and commit**

Run:
```bash
git add ops/keepalive/fetch-keeper-secret.sh ops/keepalive/multi-feed-push.mjs ops/keepalive/.env.example
git status -s
```
Expected: three `M` lines for those three files.

Run:
```bash
git commit -m "$(cat <<'EOF'
refactor(ops): rename DEPLOYER_PRIVATE_KEY → KEEPER_PRIVATE_KEY in keeper

The keeper EOA was separated from the deployer EOA in the 2026-05-10
cutover, but both fetch-keeper-secret.sh and multi-feed-push.mjs kept
using the legacy env var name. Combined with EnvironmentFile= load
order in arcoradex-feeds.service (Vault keeper.env first, persistent
.env second), any leftover DEPLOYER_PRIVATE_KEY in .env would silently
override the Vault-fetched keeper key. Renaming end-to-end removes the
collision and matches the role separation semantically.

Also drops the DEPLOYER_PRIVATE_KEY sample from .env.example so new
operators are not invited to repopulate the trap, and notes in the
header that the keeper key comes from Vault.

Spec: docs/superpowers/specs/2026-05-12-audit-cleanup-design.md §3.2

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: `3 files changed, ...`.

---

### Task 3: Add zero-address guard to `MigrateFeedsToV2.s.sol`

**Files:**
- Modify: `contracts/script/MigrateFeedsToV2.s.sol` (insert after line 23)

- [ ] **Step 1: Insert the require**

In `contracts/script/MigrateFeedsToV2.s.sol`, find:
```solidity
    function run() external {
        uint256 pk        = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeperEOA = vm.envAddress("KEEPER_EOA");
        address deployer  = vm.addr(pk);
```
Replace with:
```solidity
    function run() external {
        uint256 pk        = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeperEOA = vm.envAddress("KEEPER_EOA");
        require(keeperEOA != address(0), "zero keeper EOA");
        address deployer  = vm.addr(pk);
```

(Note: this script still reads `DEPLOYER_PRIVATE_KEY` because it is a deploy/migration script run by the deployer EOA from a local laptop, not the keeper. The rename in Task 2 only affects the keeper context. This is intentional and documented in the spec §3.2 "Backwards-compat" note.)

- [ ] **Step 2: Compile**

Run:
```bash
cd contracts && forge build
```
Expected: `Compiler run successful` (warnings OK, no errors).

- [ ] **Step 3: Smoke test the unchanged suite**

Run:
```bash
cd contracts && forge test
```
Expected: `Test result: ok. 77 passed; 0 failed; 0 skipped` (or whatever the prior baseline was — must match Task 0 baseline, must not regress).

- [ ] **Step 4: Stage and commit**

Run:
```bash
git add contracts/script/MigrateFeedsToV2.s.sol
git commit -m "$(cat <<'EOF'
fix(contracts): guard MigrateFeedsToV2 against zero KEEPER_EOA

vm.envAddress accepts 0x0000...0000 as a valid address. Without an
explicit require, the script would deploy MockChainlinkFeedV2 instances
with writer=address(0), the keeper's setAnswer would revert NotWriter
forever, and the pool would brick after MAX_STALE_SECONDS=1h.

The existing post-deploy `require(newFeed.writer() == keeperEOA, ...)`
assertion passes trivially when both sides are zero, so the check has
to happen at env-load time.

Spec: docs/superpowers/specs/2026-05-12-audit-cleanup-design.md §3.3

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: `1 file changed, 1 insertion(+)`.

---

### Task 4: Update auto-memory v07 status note

**Files:**
- Modify: `~/.claude/projects/-Users-huseyinarslan-Desktop-arcora-v0-7-shared-vault-pool/memory/v07_testnet_deploy.md`

The repo branch is irrelevant for this task — the memory file lives outside the repo and is not committed to git. No `git add`/`git commit` here.

- [ ] **Step 1: Append the decommission note**

In `~/.claude/projects/-Users-huseyinarslan-Desktop-arcora-v0-7-shared-vault-pool/memory/v07_testnet_deploy.md`, find the last paragraph:
```
- The v0.7 keeper archive at `/root/_archive/arcora-v07-feeds.2026-05-10.tar.gz`
  on the VPS is recoverable but the `.env` was shredded — old deployer
  key is in the operator's laptop only.
```

Append immediately after it (before the trailing blank line):
```

**Repo cleanup (2026-05-12):** The systemd unit file
`ops/keepalive/arcora-v07-feeds.service` was deleted from the repo on
branch `audit/2026-05-12-post-cutover-cleanup`. Re-enabling the v0.7
keeper would now require restoring the unit file from git history AND
the migration to V2 feeds + role-separated keys noted above.
```

- [ ] **Step 2: Verify the file still parses as valid memory frontmatter**

Run:
```bash
head -6 ~/.claude/projects/-Users-huseyinarslan-Desktop-arcora-v0-7-shared-vault-pool/memory/v07_testnet_deploy.md
```
Expected: the `---` frontmatter block at the top is unchanged (`name`, `description`, `type`, `originSessionId`).

(No commit — auto-memory is not under git.)

---

### Task 5: Final pre-merge verification

**Files:** none modified. This task confirms all three changes coexist cleanly.

- [ ] **Step 1: Recompile and re-test contracts**

Run:
```bash
cd contracts && forge build && forge test
```
Expected: build clean, all tests pass (same baseline as Task 3 Step 3).

- [ ] **Step 2: Lint keeper scripts**

Run:
```bash
node --check ops/keepalive/multi-feed-push.mjs
bash -n ops/keepalive/fetch-keeper-secret.sh
```
Expected: both exit 0, no output.

- [ ] **Step 3: Final grep audit**

Run:
```bash
grep -rn "DEPLOYER_PRIVATE_KEY" ops/keepalive/
```
Expected: zero matches.

Run:
```bash
grep -rn "arcora-v07-feeds" ops/
```
Expected: zero matches (docs/, root, and the auto-memory may still reference the name historically — those are out of scope).

- [ ] **Step 4: Inspect the branch's commit graph**

Run:
```bash
git log --oneline main..HEAD
```
Expected: four commits in this order (top is most recent):
```
<sha> fix(contracts): guard MigrateFeedsToV2 against zero KEEPER_EOA
<sha> refactor(ops): rename DEPLOYER_PRIVATE_KEY → KEEPER_PRIVATE_KEY in keeper
<sha> chore(ops): decommission legacy arcora-v07-feeds systemd unit
<sha> docs(audit): post-cutover cleanup design spec (2026-05-12)
```

- [ ] **Step 5: STOP. Hand back to operator for review before push / PR.**

The plan does not push to remote or open a PR — that is an explicit operator decision after reviewing the branch.

---

### Task 6: VPS rollout (post-merge — operator-driven, NOT part of the PR)

**Files:** none in this repo. This task is the operational sequence that runs after the PR merges to `main`.

The VPS does NOT run from a git checkout (verified 2026-05-12: no `.git/` under `/home/arcora`). Both scripts are standalone files copied via `scp`:
- `/home/arcora/bin/fetch-keeper-secret.sh` (owned `arcora:arcora`, mode `0750`)
- `/home/arcora/arcoradex-feeds/multi-feed-push.mjs` (owned `arcora:arcora`, mode `0644`)

Local working directory for these commands: a checkout of `main` after the PR merges, so `ops/keepalive/*` reflects the new files.

- [ ] **Step 1: Stop the keeper timer**

Run:
```bash
ssh root@194.163.136.1 'systemctl stop arcoradex-feeds.timer'
```
Expected: silent success.

- [ ] **Step 2: Copy the new fetch script**

Run:
```bash
scp ops/keepalive/fetch-keeper-secret.sh root@194.163.136.1:/home/arcora/bin/fetch-keeper-secret.sh
```
Expected: `fetch-keeper-secret.sh   100% ...`.

- [ ] **Step 3: Copy the new keeper script**

Run:
```bash
scp ops/keepalive/multi-feed-push.mjs root@194.163.136.1:/home/arcora/arcoradex-feeds/multi-feed-push.mjs
```
Expected: `multi-feed-push.mjs   100% ...`.

- [ ] **Step 4: Restore ownership and permissions**

`scp` runs as `root`, so both files land owned by `root:root`. Restore:
```bash
ssh root@194.163.136.1 'chown arcora:arcora /home/arcora/bin/fetch-keeper-secret.sh /home/arcora/arcoradex-feeds/multi-feed-push.mjs && chmod 0750 /home/arcora/bin/fetch-keeper-secret.sh && chmod 0644 /home/arcora/arcoradex-feeds/multi-feed-push.mjs'
```
Expected: silent success.

- [ ] **Step 5: Idempotent `.env` safety check**

Run:
```bash
ssh root@194.163.136.1 "sed -i '/^DEPLOYER_PRIVATE_KEY=/d' /home/arcora/arcoradex-feeds/.env"
```
Expected: silent success. This is a no-op on the 2026-05-12 VPS state — kept for defense in case `.env` was edited between audit and rollout.

- [ ] **Step 6: Reload and restart**

Run:
```bash
ssh root@194.163.136.1 'systemctl daemon-reload && systemctl start arcoradex-feeds.timer'
```
Expected: silent success.

- [ ] **Step 7: Manually trigger one keeper tick**

Run:
```bash
ssh root@194.163.136.1 'systemctl start arcoradex-feeds.service'
```
Expected: silent success (`Type=oneshot` unit completes before the SSH call returns).

- [ ] **Step 8: Inspect the journal**

Run:
```bash
ssh root@194.163.136.1 'journalctl -u arcoradex-feeds.service -n 50 --no-pager'
```
Expected: most recent run ends with `done updated=N skipped=M errored=…`. Acceptable end states:
- `errored=0` — clean.
- `errored>0` ONLY when the per-feed log lines show non-auth root causes (e.g. the known Arc testnet `txpool is full`).

If the journal shows `KEEPER_PRIVATE_KEY missing — abort` and `exit code 2`, the rename did not propagate — STOP and check that both files in Steps 2–3 are the new versions.

- [ ] **Step 9: Confirm `.env` and scripts are clean**

Run:
```bash
ssh root@194.163.136.1 'grep DEPLOYER_PRIVATE_KEY /home/arcora/arcoradex-feeds/.env /home/arcora/bin/fetch-keeper-secret.sh /home/arcora/arcoradex-feeds/multi-feed-push.mjs 2>&1 | grep -v "No such file"'
```
Expected: empty output (`grep` exit 1 is fine — means no matches).

Rollout complete.

---

## Rollback

Repo: `git revert <commit>` on any of the four commits. They are mutually independent in code (the rename and the guard touch different files); revert in any order.

VPS: re-copy the prior versions of `fetch-keeper-secret.sh` and `multi-feed-push.mjs` from `git show <prev-sha>:ops/keepalive/<file>` and re-run Steps 4–7 of Task 6. Vault contents, on-chain state, and `.env` are untouched by this rollout.
