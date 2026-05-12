# Post-Cutover Audit Cleanup Design Spec

**Date:** 2026-05-12
**Status:** Brainstorming complete — pending user review, then implementation plan
**Authors:** Hüseyin Arslan + Claude
**Audit context:** ArcoraDEX testnet post-cutover audit (2026-05-12). Builds on the key-separation cutover landed 2026-05-10 (`docs/superpowers/specs/2026-05-09-key-separation-design.md`).

---

## 1. Context & Motivation

The 2026-05-10 key-separation cutover successfully split the deployer EOA into Deployer / Keeper / Faucet, moved the keeper key into Vault, and migrated all 7 mock feeds to `MockChainlinkFeedV2`. Post-cutover smoke tests pass (77/77 forge tests, live pool unpaused, feeds fresh).

A 2026-05-12 audit pass surfaced three residual footguns — all P2/P3, none currently triggered, but each is a tripwire for a future operator. This spec covers all three in a single PR.

**VPS state verified 2026-05-12 (`194.163.136.1`):**
- Only `arcoradex-feeds.{service,timer}` enabled. `arcora-v07-feeds.timer` is `not-found`.
- Only `/home/arcora/arcoradex-feeds/` exists. No `v07-feeds/` directory.
- `/home/arcora/arcoradex-feeds/.env` does NOT contain `DEPLOYER_PRIVATE_KEY` (cutover Step 16.4 was executed).

So no live override or collision is happening today. The repo, however, still contains:
- `ops/keepalive/arcora-v07-feeds.service` (legacy unit; can't bind to anything live)
- `ops/keepalive/.env.example:6` (`DEPLOYER_PRIVATE_KEY=0x...`) — teaches new operators to repopulate the override trap
- Two units sharing `RuntimeDirectory=arcora` and `/run/arcora/keeper.env` (latent race if both were ever re-enabled)
- `contracts/script/MigrateFeedsToV2.s.sol` accepts `KEEPER_EOA = address(0)` silently

Each is cheap to fix. Doing so makes the cutover semantically complete and removes ammunition for future misconfiguration.

---

## 2. Goals & Non-Goals

**Goals**
- Decommission the legacy v07 keeper unit from the repo (live system is already free of it).
- Rename the keeper-side private key env var from `DEPLOYER_PRIVATE_KEY` to `KEEPER_PRIVATE_KEY` end-to-end (fetch script, keeper script, `.env.example`). Removes the semantic confusion that lets `.env` accidentally override the Vault-fetched key.
- Add a `KEEPER_EOA != address(0)` guard to `MigrateFeedsToV2.s.sol`.
- Ship as a single PR; coordinate a brief VPS swap window since the rename touches two files that must move together.

**Non-Goals**
- Re-running the feed migration (V2 feeds are already deployed and authoritative).
- Changing the keeper's on-chain identity, the Vault schema, or the AppRole policy.
- Investigating the 2026-05-12 22:33 UTC `txpool is full` failure on Arc testnet (separate operational issue; tracked but out of this spec's scope).
- Mainnet-readiness work (multisig, hardware wallets, KMS) — already deferred per the 2026-05-09 spec.
- Adding deployment-time validation to `MockChainlinkFeedV2` itself (mock contract, testnet-only; script-level guard is sufficient).

---

## 3. Changes

### 3.1 v07 keeper unit decommission (P2 #2)

**Repo deletions:**
- `ops/keepalive/arcora-v07-feeds.service` — remove file.

**Repo edits:**
- `ops/keepalive/.env.example` — already ArcoraDEX-only after the rename in §3.2; no v07-specific lines to strip beyond the rename itself.
- Auto-memory `v07_testnet_deploy.md` — update status note to reflect that the keeper unit is decommissioned (on-chain artifact remains frozen).

**VPS state (already true, no action needed):**
- No `arcora-v07-feeds.timer` registered.
- No `/home/arcora/v07-feeds/` directory.
- No symlinks in `/etc/systemd/system/*.wants/` referencing the legacy unit.

This change eliminates the shared `RuntimeDirectory=arcora` / `/run/arcora/keeper.env` collision risk by removing the second tenant entirely. No tenant-prefixed paths needed.

### 3.2 `DEPLOYER_PRIVATE_KEY` → `KEEPER_PRIVATE_KEY` rename (P2 #1)

**`ops/keepalive/fetch-keeper-secret.sh`:**
- Line 13 (doc comment): `containing: KEEPER_PRIVATE_KEY=0x...`
- Line 34 (heredoc body): `KEEPER_PRIVATE_KEY=$KEEPER_KEY`

**`ops/keepalive/multi-feed-push.mjs`:**
- Line 120: `const pk = process.env.KEEPER_PRIVATE_KEY;`
- Line 122: `log("KEEPER_PRIVATE_KEY missing — abort");`

**`ops/keepalive/.env.example`:**
- Remove line 6 entirely (`DEPLOYER_PRIVATE_KEY=0x...`). Vault provides the key now; `.env` should not invite operators to repopulate it. Update header comment to note that the keeper key comes from Vault via `fetch-keeper-secret.sh`.

**`ops/keepalive/arcoradex-feeds.service`:**
- No structural change. Both `EnvironmentFile=` lines remain in their current order. The override risk evaporates because the two files no longer share a key name.

**Why a key-name change, not an EnvironmentFile reorder?**
- Order swap would work but preserves the underlying confusion: two distinct keys masquerading under the same name. The next operator who edits `.env` without reading the unit file resets the trap.
- The 2026-05-09 cutover spec explicitly listed this rename as a 1-line follow-up (`design.md:347`). This is that follow-up.

**Backwards-compat:** None. The Vercel/SDK paths read the *deployer* key under different env names (`FAUCET_PRIVATE_KEY` for Vercel, deploy scripts read `DEPLOYER_PRIVATE_KEY` for migrations). Only the keeper script touches the renamed var. No other consumer breaks.

### 3.3 `KEEPER_EOA` zero-address guard (P3)

**`contracts/script/MigrateFeedsToV2.s.sol`:**
- After line 23 (`address keeperEOA = vm.envAddress("KEEPER_EOA");`), insert:
  ```solidity
  require(keeperEOA != address(0), "zero keeper EOA");
  ```

**Rationale:**
- `MockChainlinkFeedV2` constructor (`contracts/src/testnet/MockChainlinkFeedV2.sol:22-34`) accepts `initialWriter = address(0)` silently.
- Script's existing `require(newFeed.writer() == keeperEOA, ...)` (line 73) passes with `0 == 0`.
- Failure mode: feeds deploy with `writer = 0x0`, keeper's `setAnswer` reverts `NotWriter` forever, oracle age exceeds `MAX_STALE_SECONDS = 3600s`, pool reverts all swaps.

**Test coverage:** Script is not part of `forge test`; the guard is verified by a successful `forge build` + manual env-flip check during code review. No new test file.

---

## 4. Rollout Sequence

The repo changes land together in one PR. The VPS does NOT run from a git checkout — both scripts live as standalone files copied via `scp` (verified 2026-05-12: no `.git/` under `/home/arcora`). Layout:
- `/home/arcora/bin/fetch-keeper-secret.sh` (owned `arcora:arcora`, mode `0750`)
- `/home/arcora/arcoradex-feeds/multi-feed-push.mjs` (owned `arcora:arcora`, mode `0644`)

Operator runs from local repo checkout:

1. `ssh root@194.163.136.1 'systemctl stop arcoradex-feeds.timer'` — prevent a partial-state run mid-deploy.
2. `scp ops/keepalive/fetch-keeper-secret.sh root@194.163.136.1:/home/arcora/bin/fetch-keeper-secret.sh`
3. `scp ops/keepalive/multi-feed-push.mjs root@194.163.136.1:/home/arcora/arcoradex-feeds/multi-feed-push.mjs`
4. `ssh root@194.163.136.1 'chown arcora:arcora /home/arcora/bin/fetch-keeper-secret.sh /home/arcora/arcoradex-feeds/multi-feed-push.mjs && chmod 0750 /home/arcora/bin/fetch-keeper-secret.sh && chmod 0644 /home/arcora/arcoradex-feeds/multi-feed-push.mjs'` — restore ownership/perms after `scp` (which runs as `root`).
5. `ssh root@194.163.136.1 "sed -i '/^DEPLOYER_PRIVATE_KEY=/d' /home/arcora/arcoradex-feeds/.env"` — idempotent safety check; already a no-op per the 2026-05-12 VPS audit, kept for defense.
6. `ssh root@194.163.136.1 'systemctl daemon-reload && systemctl start arcoradex-feeds.timer && systemctl start arcoradex-feeds.service'` — `daemon-reload` is cosmetic (no unit file on disk changed); manual `start arcoradex-feeds.service` triggers an immediate keeper tick.
7. `ssh root@194.163.136.1 'journalctl -u arcoradex-feeds -n 50 --no-pager'` — confirm the most recent run ends with `done updated=N skipped=M errored=…`. Expect `errored=0` unless the unrelated Arc testnet `txpool is full` condition recurs.

**Window:** ≤ 2 minutes. Keeper timer fires every 30 min; we just have to be done before the next scheduled tick.

**Rollback:** Restore the previous two scripts from git history, restart timer. Vault key, .env, and on-chain state are untouched.

---

## 5. Risks & Mitigations

| Risk | Probability | Mitigation |
|---|---|---|
| Partial script swap (only one of fetch/keeper updated) → timer breaks | Medium | Step 1 stops the timer; Step 3 swaps both files before Step 6 restarts. |
| Hidden consumer of `DEPLOYER_PRIVATE_KEY` in the keeper context | Low | `grep -r DEPLOYER_PRIVATE_KEY ops/keepalive` must return empty after the rename. CI/pre-commit can enforce. |
| v07 unit deletion breaks something nobody told us about | Very low | VPS audit confirms no live binding. Auto-memory says v07 is "superseded / frozen on-chain artifact". |
| Guard rejects a legitimate `KEEPER_EOA` | Effectively zero | `address(0)` is the only rejected value. |

---

## 6. Verification

**Local (pre-PR):**
- `cd contracts && forge build` — compile clean.
- `cd contracts && forge test` — 77/77 still green (script is not in the suite, but the build must not break it).
- `node --check ops/keepalive/multi-feed-push.mjs` — syntax OK.
- `bash -n ops/keepalive/fetch-keeper-secret.sh` — syntax OK.
- `grep -rn DEPLOYER_PRIVATE_KEY ops/keepalive` — returns empty.
- `grep -rn KEEPER_PRIVATE_KEY ops/keepalive` — returns three hits (fetch script comment, fetch script heredoc, keeper script env read; comment count may vary).

**VPS (post-deploy):**
- `journalctl -u arcoradex-feeds.service -n 100 --no-pager` — most recent run shows `done updated=N skipped=M errored=0` (or `errored>0` only with non-auth root causes such as the known `txpool is full`). A working keeper signing tx ≡ proof the rename worked (wrong env name would surface as `KEEPER_PRIVATE_KEY missing — abort` and `exit 2`).
- `grep DEPLOYER_PRIVATE_KEY /home/arcora/arcoradex-feeds/.env` — empty.
- `grep DEPLOYER_PRIVATE_KEY /home/arcora/bin/fetch-keeper-secret.sh /home/arcora/arcoradex-feeds/multi-feed-push.mjs` — empty.

---

## 7. Out of Scope (Tracked Elsewhere)

- **Arc testnet `txpool is full` failures** observed 2026-05-12 22:33 UTC on DAI `setAnswer`. Keeper auth is correct (sender = keeper EOA `0xe8fe70...`); the failure is a network mempool condition. If the next 1–2 ticks don't clear it, feeds will go stale and pool swaps will revert on freshness check. Separate operational ticket.
- Per-tenant runtime path scheme (`/run/arcora/<tenant>/keeper.env`) — moot once v07 is decommissioned. Reintroduce only if a second tenant comes back.
- `MockChainlinkFeedV2` constructor-level zero-address guard — testnet-only mock; script-level guard suffices.
