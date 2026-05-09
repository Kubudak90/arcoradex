# Audit Group B — Key Separation + VPS Least-Privilege Design Spec

**Date:** 2026-05-09
**Status:** Brainstorming complete — pending user review, then implementation plan
**Authors:** Hüseyin Arslan + Claude
**Audit context:** ArcoraDEX testnet hardening pass (2026-05-09 audit, finding P1 #1)
**Scope:** Group B of a 5-group rollout (Groups A/C/D/E queued separately)

---

## 1. Context & Motivation

ArcoraDEX is live on Arc testnet (chainId `5042002`) with three protocol contracts (`ArcoraDexRegistry`, `ArcoraDexPool`, `ArcoraDexLP`), 7 mock stables (`MintableERC20`), and 7 mock Chainlink feeds (`MockChainlinkFeed`). A 2026-05-09 audit pass flagged that **a single deployer EOA (`0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b`) controls all of it**:

- `ArcoraDexRegistry.owner` — list/deactivate tokens, change deviation, set oracles
- `ArcoraDexPool.owner` — pause/unpause, set fees, withdraw protocol fees, sweep
- `MintableERC20.owner` (×7) — unlimited mint
- `MockChainlinkFeed.owner` (×7) — `setAnswer` (effectively price control)

The same private key sits on:
- VPS `194.163.136.1` at `/root/arcoradex-feeds/.env` and `/root/arcora-v07-feeds/.env` (under `/root/`, plaintext, root-owned)
- Vercel production env as `FAUCET_PRIVATE_KEY`

Compromise of either VPS root or Vercel env (or the local laptop holding the deployer key) gives an attacker mint-arbitrary-tokens, set-arbitrary-feed-prices, drain-pool-via-NAV-manipulation, and pause-protocol — all in one go.

**Mainnet-impact note:** This spec touches only the testnet stack. On mainnet ArcoraDEX will use real USDC / USDT / Chainlink contracts (which we don't own and can't redeploy). Mock-token / mock-feed migration here changes nothing on the mainnet path. The reusable pieces for mainnet will be the *operational* ones: VPS LPU, Vault-stored signing keys, role-based EOA discipline, multisig governance pattern (out of scope here, queued for mainnet readiness).

---

## 2. Goals & Non-Goals

**Goals**
- Split the single deployer EOA into 3 EOAs with disjoint capabilities. A compromise of any one bounds the blast radius to that role's surface.
- Move the keeper key off VPS disk and into HashiCorp Vault (already running on the host at `127.0.0.1:8200`). Plaintext key never touches `/home/*` or `/root/*` at rest.
- Run the keeper as a non-root unprivileged user. SSH key-only auth, no password fallback.
- Live-system migration with explicit rollback at every step. Zero NAV jitter, zero swap downtime > 60s.

**Non-Goals**
- Multisig / timelock for governance (testnet doesn't justify the ceremony; queued for mainnet readiness).
- KMS / hardware-wallet integration for the deployer key (deployer is rare-use, manual signing is fine).
- Real Chainlink feeds — testnet stays on mock feeds.
- Faucet abuse mitigation, oracle alerting, FoT guard, dependency updates — separate audit groups.

---

## 3. Threat Model & Role Map

| EOA (post-migration) | Capabilities | Storage | Touch frequency |
|---|---|---|---|
| **Deployer / Governance** — existing `0xe8E5...754b` | `ArcoraDexRegistry`/`ArcoraDexPool`/`ArcoraDexLP` owner: pause, listToken, setOracle, withdrawProtocolFees, sweep, fee adjustments. After migration: NOT a token owner, NOT a feed writer. | Local laptop only. Removed from VPS and Vercel. Future: hardware wallet. | Rare (deploys, emergencies, governance ops). |
| **Keeper** — new EOA | Single capability: call `setAnswer` on the 7 `MockChainlinkFeedV2` instances (writer role). Cannot mint, cannot admin. | HashiCorp Vault on VPS. Fetched via AppRole into a tmpfs-backed `EnvironmentFile` for the keeper's systemd unit, deleted on stop. | Every 30 min (timer). |
| **Faucet** — new EOA | Single capability: call `mint` on the 7 `MintableERC20` instances (token owner). Cannot pause, cannot list, cannot write feeds. | Vercel encrypted env (production + preview). Function-execution-context only. | Per faucet claim (user-initiated). |

**Compromise scenarios (post-migration):**
- VPS root popped → keeper key extracted from Vault (still possible if attacker reads vault token / role_id) → attacker can drift feed prices within the registry's per-token deviation cap (50 / 150 / 5000 bps). NAV manipulation possible but bounded; cannot mint, cannot pause, cannot drain. Deployer can rotate writer via `MockChainlinkFeedV2.setWriter` in one tx.
- Vercel env leak → faucet key extracted → attacker can mint arbitrary mock tokens. Mock tokens have $0 economic value; only impact is faucet-token spam. Deployer can rotate token owner back via `transferOwnership`.
- Deployer laptop popped → full blast radius (governance + ability to rotate keeper/faucet writer/owner). This is the irreducible single point of failure. Mitigation is operational (laptop disk encryption, hardware wallet for prod) and out of scope for testnet.

---

## 4. On-Chain Changes

### 4.1 New `MockChainlinkFeedV2` contract
Path: `contracts/src/testnet/MockChainlinkFeedV2.sol`

```solidity
contract MockChainlinkFeedV2 is IChainlinkAggregator, Ownable2Step {
    address public writer;
    int256  public latestAnswer;
    uint256 public latestUpdatedAt;
    uint8   public immutable decimalsValue;

    error NotWriter();
    event WriterUpdated(address indexed prev, address indexed next);
    event AnswerUpdated(int256 answer, uint256 updatedAt);

    constructor(uint8 _decimals, int256 initialAnswer, address initialWriter, address initialOwner)
        Ownable(initialOwner)
    {
        decimalsValue = _decimals;
        latestAnswer = initialAnswer;
        latestUpdatedAt = block.timestamp;
        writer = initialWriter;
        emit WriterUpdated(address(0), initialWriter);
    }

    function setWriter(address newWriter) external onlyOwner {
        emit WriterUpdated(writer, newWriter);
        writer = newWriter;
    }

    function setAnswer(int256 newAnswer) external {
        if (msg.sender != writer) revert NotWriter();
        latestAnswer = newAnswer;
        latestUpdatedAt = block.timestamp;
        emit AnswerUpdated(newAnswer, block.timestamp);
    }

    function decimals() external view returns (uint8) { return decimalsValue; }

    function latestRoundData() external view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, latestAnswer, latestUpdatedAt, latestUpdatedAt, 1);
    }
}
```

**Why `Ownable2Step` here, single-step `Ownable` for `MintableERC20`?** Feeds are higher-leverage (mid-migration writer-fat-finger is recoverable but visible); 2-step gives a pending-acceptance window for transfers. Token ownership is a one-shot admin operation; single-step is fine and matches the existing OZ default in `MintableERC20`.

### 4.2 Migration script — feeds
Path: `contracts/script/MigrateFeedsToV2.s.sol`

Iterates the registry's active token list, deploys a fresh `MockChainlinkFeedV2` per token (initialAnswer = current v1 feed's `latestAnswer`, initialWriter = keeper EOA, initialOwner = deployer), then calls `registry.setOracle(token, address(newFeed))`.

Invariant assertions in-script:
- `pool.totalReservesUSD()` measured before and after the loop must match within ±1 wei (oracle prices identical, only feed contract address changed).
- For each token: `MockChainlinkFeedV2(newFeed).writer == KEEPER_EOA`.
- For each token: `MockChainlinkFeedV2(newFeed).owner == DEPLOYER_EOA`.

### 4.3 Migration script — token ownership
Path: `contracts/script/TransferTokenOwnershipToFaucet.s.sol`

For each of 7 active tokens: `MintableERC20(token).transferOwnership(FAUCET_EOA)`.

OZ Ownable v5 `transferOwnership` is single-tx irreversible. After this, deployer cannot mint. Faucet EOA can hand ownership back via the same call if needed.

Invariant assertions in-script:
- For each token: `MintableERC20(token).owner() == FAUCET_EOA`.

### 4.4 Pool / Registry / LP — UNCHANGED

These keep deployer as owner. No migration. Anything outside this spec touching them (e.g. fee adjustments) is governance and uses deployer key manually.

---

## 5. Off-Chain Changes

### 5.1 VPS LPU setup (host: `194.163.136.1`)

```bash
# As root, one-time prep:
useradd -m -s /bin/bash arcora
mkdir -p /home/arcora/arcoradex-feeds /home/arcora/v07-feeds
mv /root/arcoradex-feeds/* /home/arcora/arcoradex-feeds/
mv /root/arcora-v07-feeds/* /home/arcora/v07-feeds/
chown -R arcora:arcora /home/arcora/
chmod 700 /home/arcora/{arcoradex,v07}-feeds
chmod 600 /home/arcora/{arcoradex,v07}-feeds/.env  # transitional — replaced by Vault in 5.3

# SSH hardening (after key auth verified working):
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl reload ssh
```

The `arcora` user owns nothing else on the host. Other tenants (`/root/video-api/`, `/opt/bounty-hunter/`, etc.) untouched.

### 5.2 systemd unit migration
Existing units (`arcora-v07-feeds.service`, `arcoradex-feeds.service`) updated:

```ini
[Service]
Type=oneshot
User=arcora
Group=arcora
WorkingDirectory=/home/arcora/arcoradex-feeds
ExecStartPre=/home/arcora/bin/fetch-keeper-secret.sh   # NEW, see 5.3
EnvironmentFile=/run/arcora/keeper.env                 # NEW, tmpfs-backed
ExecStart=/usr/bin/node /home/arcora/arcoradex-feeds/multi-feed-push.mjs
ExecStopPost=/bin/rm -f /run/arcora/keeper.env         # NEW, cleanup
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/run/arcora
```

`PrivateTmp` + `ProtectSystem=strict` are systemd hardening directives that cost nothing and reduce a compromised process's reach.

### 5.3 Vault setup (KV-v2 + AppRole)

**Prerequisites verified during T-0:** Vault is running on `127.0.0.1:8200`. We need to confirm: is it initialized + unsealed? Is there an admin token / root token accessible? Is a KV-v2 mount enabled?

Setup commands (idempotent — re-runnable):

```bash
# Enable KV-v2 (no-op if already enabled)
vault secrets enable -path=kv -version=2 kv || true

# Write keeper secret
vault kv put kv/arcora/keeper-arcoradex KEEPER_PRIVATE_KEY=0x<KEEPER_KEY_HEX>
vault kv put kv/arcora/keeper-v07       KEEPER_PRIVATE_KEY=0x<KEEPER_KEY_HEX>  # same key for both tenants

# Enable AppRole auth method
vault auth enable approle || true

# Policy — read-only on the two paths
cat <<'EOF' | vault policy write keeper-feeds -
path "kv/data/arcora/keeper-arcoradex" { capabilities = ["read"] }
path "kv/data/arcora/keeper-v07"       { capabilities = ["read"] }
EOF

# Create AppRole, bind to policy
vault write auth/approle/role/keeper-feeds \
    token_policies=keeper-feeds \
    token_ttl=10m \
    token_max_ttl=20m \
    secret_id_ttl=720h \
    secret_id_num_uses=0

# Pull role_id (long-lived) and a secret_id (rotated weekly)
vault read -field=role_id auth/approle/role/keeper-feeds/role-id  > /home/arcora/.vault/role_id
vault write -field=secret_id -force auth/approle/role/keeper-feeds/secret-id > /home/arcora/.vault/secret_id
chown -R arcora:arcora /home/arcora/.vault
chmod 400 /home/arcora/.vault/role_id /home/arcora/.vault/secret_id
```

Token TTL of 10 min is generous for a sub-second fetch. `secret_id_ttl=720h` (30d) gives buffer for rotation; we'll add a weekly cron later (out of scope here, acceptable risk for testnet).

### 5.4 Keeper secret-fetch wrapper
Path: `/home/arcora/bin/fetch-keeper-secret.sh` (also versioned at `ops/keepalive/fetch-keeper-secret.sh` in the repo)

```bash
#!/bin/bash
set -euo pipefail
export VAULT_ADDR=http://127.0.0.1:8200

ROLE_ID="$(cat /home/arcora/.vault/role_id)"
SECRET_ID="$(cat /home/arcora/.vault/secret_id)"

VAULT_TOKEN="$(vault write -field=token auth/approle/login \
    role_id=$ROLE_ID secret_id=$SECRET_ID)"
export VAULT_TOKEN

# Pick which secret based on which systemd unit invoked us
TENANT="${KEEPER_TENANT:-arcoradex}"   # set per unit via Environment=
KEEPER_KEY="$(vault kv get -field=KEEPER_PRIVATE_KEY kv/arcora/keeper-$TENANT)"

mkdir -p /run/arcora
chmod 700 /run/arcora
chown arcora:arcora /run/arcora

cat > /run/arcora/keeper.env <<EOF
DEPLOYER_PRIVATE_KEY=$KEEPER_KEY
EOF
chmod 600 /run/arcora/keeper.env
chown arcora:arcora /run/arcora/keeper.env

unset VAULT_TOKEN KEEPER_KEY
```

Note: keeper script reads `process.env.DEPLOYER_PRIVATE_KEY` today; we keep that variable name (no script change) but the value is now a different key (keeper EOA, not deployer EOA). Renaming to `KEEPER_PRIVATE_KEY` in the keeper code is a 1-line follow-up out of scope here.

### 5.5 Vercel env update

```bash
# Locally:
vercel env rm FAUCET_PRIVATE_KEY production
vercel env rm FAUCET_PRIVATE_KEY preview
echo "0x<FAUCET_KEY_HEX>" | vercel env add FAUCET_PRIVATE_KEY production
echo "0x<FAUCET_KEY_HEX>" | vercel env add FAUCET_PRIVATE_KEY preview
vercel deploy --prod  # picks up new env
```

Done from the operator's laptop (deployer key still loaded). After this, `swap.arcorapay.xyz` faucet route uses faucet EOA exclusively.

---

## 6. Single-Day Cutover Sequence

Plan target: ~6 hours of focused work, one operator, one terminal session.

| Phase | Wall-clock | Action | Verify |
|---|---|---|---|
| **T-0** prep (local, no chain) | 09:00–11:00 | Generate keeper + faucet EOAs (`cast wallet new --json`, save outputs to encrypted vault file). Write `MockChainlinkFeedV2.sol` + tests + 2 migration scripts. Run `forge test` green. | 165+ tests pass; 2 new fork-tests for migration scripts. |
| **T-0.5** infra (VPS) | 11:00–12:00 | SSH in. Install Vault CLI on host if missing. Verify Vault unsealed (`vault status`). Run §5.3 commands. Verify AppRole login works manually. Stage `fetch-keeper-secret.sh` at `/home/arcora/bin/`. | `vault kv get kv/arcora/keeper-arcoradex` returns key. Wrapper script exits 0 and writes `/run/arcora/keeper.env`. |
| **T-1** fund new EOAs | 12:00–12:15 | From deployer key, send 2 ETH each to keeper EOA and faucet EOA. | `cast balance` shows ≥ 2 ETH on both. |
| **T-2** disable existing keepers | 12:15–12:20 | `systemctl stop arcora-v07-feeds.timer arcoradex-feeds.timer`. Confirm no in-flight fire. | Both timers `inactive`. |
| **T-3** feed migration | 12:20–13:00 | `forge script MigrateFeedsToV2 --rpc-url $ARC_TESTNET_RPC --broadcast --slow`. Watch console for invariant asserts. | NAV pre/post diff = 0. All 7 new feeds have correct writer + owner. `cast call $REGISTRY tokenInfo(...)` returns new feed addresses. |
| **T-3.5** keeper first-fire (CRITICAL) | 13:00–13:15 | From local laptop, with the freshly-generated keeper EOA key in hand: `KEEPER_PK=0x... node ops/keepalive/multi-feed-push.mjs` against the prod feed addresses. This bumps each new feed's `latestUpdatedAt` while we still have time before the 1-hour `MAX_STALE_SECONDS` clock (which started ticking from each feed's constructor block) expires. **Hard deadline: must complete within 60 min of T-3 end.** | All 7 new feeds' `latestUpdatedAt` advanced to within last few minutes. Sample swap quote works. |
| **T-4** create LPU + move dirs | 13:15–14:15 | Run §5.1 commands. Update both systemd unit files per §5.2. `systemctl daemon-reload`. | `ls -la /home/arcora/` shows correct ownership. SSH still works via key. |
| **T-5** keeper switch (systemd) | 14:15–14:45 | `systemctl start arcoradex-feeds.service` (manual one-shot of the new LPU-running unit). `systemctl start arcora-v07-feeds.service`. Watch journal. | Both services exit 0 as `User=arcora`. New keeper EOA tx sender on every `setAnswer`. RPC: `latestUpdatedAt` advanced again. |
| **T-6** re-enable timers | 14:45–14:50 | `systemctl start arcora-v07-feeds.timer arcoradex-feeds.timer`. | Both timers `active (waiting)`, next-fire scheduled. |
| **T-7** token ownership | 14:50–15:15 | `forge script TransferTokenOwnershipToFaucet --rpc-url $ARC_TESTNET_RPC --broadcast --slow`. | All 7 `MintableERC20.owner() == FAUCET_EOA`. |
| **T-8** Vercel cutover | 15:15–15:45 | Run §5.5. Wait for prod deploy. Test `POST /api/faucet` from a fresh address; verify mint success and tx sender = faucet EOA. | Faucet claim returns 200, on-chain mint tx signed by faucet EOA. |
| **T-9** SSH lockdown + cleanup | 15:45–16:15 | `sed -i ... PasswordAuthentication no`; `systemctl reload ssh`. Remove deployer key from VPS .env files (now stale anyway). Remove from Vercel env (already replaced in T-8). Move local deployer key to offline storage. | `ssh -o PasswordAuthentication=yes ...` rejected. `grep DEPLOYER_PRIVATE_KEY /home/arcora/` empty. |
| **T-10** smoke | 16:15–16:45 | Watch one auto-fire of each keeper timer (~30 min wait). Test `cast call $POOL totalReservesUSD()`. Test small swap via app. | Both keepers green. NAV non-zero. Swap succeeds. |

**Hard rollback points:**
- After **T-3**: `forge script ... --sig 'rollback()'` re-runs `registry.setOracle(token, oldFeed)` for all 7. Pool resumes reading old feeds (which still have keeper-pushed values from before T-2). 1 tx per token, ~5 min.
- After **T-7**: faucet EOA executes `transferOwnership(deployer)` for all 7 tokens. Single signed broadcast, faucet still has keys via Vercel env until T-8.
- After **T-8**: rollback to old `FAUCET_PRIVATE_KEY` value via `vercel env rm` + add. Deploy. Old key resumes (and was never removed from on-chain state because we transferred ownership in T-7, so to fully roll back we'd need both T-7 and T-8 reversals).
- After **T-9**: re-enable password SSH locally if absolutely needed (not recommended). Restore `.env` keeper plaintext from backup.

---

## 7. Testing Strategy

### 7.1 Foundry tests for `MockChainlinkFeedV2`

`contracts/test/MockChainlinkFeedV2.t.sol` — minimum:
- `setAnswer` reverts `NotWriter` if caller != writer.
- `setAnswer` succeeds if caller == writer; `latestAnswer` and `latestUpdatedAt` updated.
- `setWriter` reverts `OwnableUnauthorizedAccount` if caller != owner.
- `setWriter` updates writer; old writer's `setAnswer` then reverts.
- `transferOwnership` is 2-step (Ownable2Step): pending owner must `acceptOwnership`; until then old owner retains rights.
- `latestRoundData` returns the same shape as v1 (drop-in compatibility).

### 7.2 Foundry fork test for migration

`contracts/test/MigrateFeedsToV2.fork.t.sol` (mainnet-fork-style, but on Arc testnet RPC):
- Load live registry/pool state.
- Run the migration script's logic against the fork.
- Assert: each token's oracle slot now points at a v2 feed. NAV ±1 wei stable. Keeper EOA can `setAnswer` on each new feed; deployer cannot.

### 7.3 Live-system smoke (post-T-5)

- Trigger one tick of each keeper systemd unit. Verify journal `done updated=N skipped=M errored=0`.
- `cast call` each `MockChainlinkFeedV2.latestUpdatedAt` — must be < 60s old.
- One small swap (`cast send pool.swap(...)`) on the app — must succeed.

### 7.4 Live-system smoke (post-T-8)

- `POST /api/faucet {"address":"0x<test EOA>"}` — must return 200, tx hashes signed by faucet EOA.
- `cast call MintableERC20(USDC).owner()` — returns faucet EOA.
- Old deployer key signs `mint(...)` via cast — must revert `OwnableUnauthorizedAccount`.

---

## 8. Migration Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Vault not initialized / unsealed when we get there | Medium | T-0.5 verifies before any chain action. If found unsealed, queue Vault init/unseal as a sub-task; if Vault entirely unconfigured by another tenant, fall back to systemd `LoadCredential=` from `/etc/arcora-secrets/` (root-owned, 0400). Decision deferred to T-0.5 evidence. |
| New feed deployed but `setOracle` tx fails mid-loop | Low | Migration script uses `--slow` (sequential txs). On revert, partial migration: some tokens point at v2, others at v1. Both work. Re-run script (idempotent skip on already-migrated tokens) or rollback. |
| Pool reverts mid-migration because new v2 feeds' constructor-set `updatedAt` ages past `MAX_STALE_SECONDS = 1 hour` before the keeper writes them | Medium → Low (with T-3.5 in place) | Each new feed's `latestUpdatedAt` is set in its constructor (live block timestamp). Pool reverts when `block.timestamp - updatedAt > 1 hour`. The cutover puts T-3.5 (manual keeper first-fire from local laptop) immediately after T-3, with a hard 60-min deadline. If T-3.5 fails or runs late, pool will revert quote/deposit/withdraw until any keeper run lands. Mitigation if missed: rerun T-3.5 manually; old feeds (still fresh at that point) can also be re-pointed via `registry.setOracle(...)` rollback in §6. |
| Keeper EOA underfunded mid-tick | Low | T-1 funds 2 ETH; one tick costs ≪ 0.01 ETH. Add monitoring (Group C scope). |
| Faucet redeploys before token ownership transfer (T-7 ordering) | Medium | Sequence above keeps T-7 *before* T-8. If reversed accidentally, faucet would 502 on mint (token still owned by deployer). T-8 inverts only after T-7 confirmation. |
| `arcora` user can't access Vault socket due to permissions | Medium | Vault binds to `127.0.0.1:8200` (TCP, not unix socket); no special permission needed. AppRole auth is the gate. |
| Rolled-back state diverges from documentation | Low | After every phase: commit a tiny status note to `docs/rollouts/2026-05-09-key-separation.md` with on-chain addresses of new feeds, EOA addresses, and which phase succeeded. Single source of truth. |

---

## 9. Out of Scope

- **Multisig / timelock for governance owner.** Adds 1–2 days. Justified for mainnet, not testnet. Tracked as future work.
- **Hardware wallet for deployer.** Operational improvement (laptop encryption + offline backup is the testnet-acceptable substitute).
- **Faucet abuse mitigation, oracle alerting, FoT guard, dependency hygiene, SDK approval default.** Audit groups A/C/D/E.
- **Renaming `DEPLOYER_PRIVATE_KEY` env to `KEEPER_PRIVATE_KEY` in keeper script.** Cosmetic; do later as a one-line PR (would require code change + Vercel/VPS env coordination).
- **Vault secret_id rotation cron.** Manual rotate every 30d via the same `vault write -force ... secret-id` command. Cron-ifying is a follow-up.

---

## 10. Open Questions Resolved During Brainstorming

- Q: Hibrit (feed redeploy + token transferOwnership) vs full v2 redeploy? → **Hibrit** (tokens stay, feeds redeploy). Mainnet uses real USDC anyway.
- Q: Vault setup in scope? → **Yes**, §5.3 is part of the cutover.
- Q: Single-day cutover or multi-day? → **Single day**, ~6 hours, §6.

---

## 11. Success Criteria

A migration is successful when **all** of the following hold:

1. `MockChainlinkFeedV2` contract on each of the 7 token slots in `ArcoraDexRegistry`. Each has `writer == KEEPER_EOA`, `owner == DEPLOYER_EOA`.
2. Each `MintableERC20.owner() == FAUCET_EOA`. Deployer key fails `mint(...)` with `OwnableUnauthorizedAccount`.
3. Both keeper systemd units (`arcoradex-feeds`, `arcora-v07-feeds`) running as `User=arcora`. `EnvironmentFile=/run/arcora/keeper.env` populated by `fetch-keeper-secret.sh` from Vault. Plaintext keeper key not present in any file under `/home/` or `/root/` at rest.
4. SSH password auth disabled. Only key auth works.
5. `swap.arcorapay.xyz` faucet successfully mints from faucet EOA.
6. `cast call $POOL totalReservesUSD()` returns same value (±dust) before vs. after migration.
7. `forge test` 165+ tests still pass on the new contract suite.
