# Key separation cutover — 2026-05-10

**Network:** Arc testnet (chainId `5042002`)
**Audit group:** B (Key separation + VPS LPU)
**Spec:** `docs/superpowers/specs/2026-05-09-key-separation-design.md`
**Plan:** `docs/superpowers/plans/2026-05-09-key-separation.md`

## What changed

Before the cutover a single deployer EOA owned all three roles
(protocol owner, oracle writer, faucet minter) and its private key
lived in plaintext on the VPS. The cutover splits the roles across
three EOAs, removes the deployer key from the VPS entirely, and fetches
the keeper key on-demand from HashiCorp Vault.

### Role map (post-cutover)

| Role     | EOA                                          | Location of private key                |
|----------|----------------------------------------------|-----------------------------------------|
| Deployer | `0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b` | Operator laptop only (`contracts/.env`) |
| Keeper   | `0xe8fe70433779359C4ae72CF3b801Ed569Ba9b8C3` | Vault `kv/arcora/keeper-arcoradex`      |
| Faucet   | `0xA400dBafeEb4e14B2836B5D7D040DbB4DcA164E4` | Vercel project env (`FAUCET_PRIVATE_KEY`) |

### On-chain artifacts

All 7 mock feeds were redeployed as `MockChainlinkFeedV2` with
role-separated owner (Ownable2Step) + writer slots. `setOracle` was
called on the registry per token; the NAV invariant held (±1 wei).

| Symbol | New V2 feed                                  |
|--------|----------------------------------------------|
| USDC   | `0x2E6B862E1Ac74328238494B22317262004534B39` |
| USDT   | `0x741af784a1d4C69843A1764099433160088a1c70` |
| PYUSD  | `0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896` |
| DAI    | `0xAAC5a5855deF9414f7330f350c2E00119C2097c8` |
| EURC   | `0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170` |
| TRYC   | `0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C` |
| BRLC   | `0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d` |

For each feed: `owner = deployer EOA` (Ownable2Step), `writer = keeper EOA`.

Token ownership for all 7 `MintableERC20` tokens was transferred from
the deployer to the faucet EOA via `TransferTokenOwnershipToFaucet.s.sol`
(OZ Ownable v5 single-step). After the transfer the deployer can no
longer mint test stables; the faucet route is the sole minter.

### Off-chain artifacts

* **VPS** (`194.163.136.1`)
  * Keeper unit runs as the unprivileged `arcora` user
    (`/etc/systemd/system/arcoradex-feeds.{service,timer}`).
  * Working dir: `/home/arcora/arcoradex-feeds/`.
  * `ExecStartPre=/home/arcora/bin/fetch-keeper-secret.sh` performs an
    AppRole login against Vault on `127.0.0.1:8200`, pulls the keeper
    key from `kv/arcora/keeper-arcoradex`, and writes it to a tmpfs
    `EnvironmentFile` (`/run/arcora/keeper.env`, mode 600).
  * `ExecStopPost` removes the tmpfs file; `RuntimeDirectory=arcora`
    tears down `/run/arcora` between invocations.
  * `EnvironmentFile=-/run/arcora/keeper.env` uses systemd's `-` prefix
    so the unit can be re-evaluated even before `ExecStartPre` runs.
  * AppRole creds live in `/home/arcora/.vault-creds/{role_id,secret_id}`,
    each `chmod 400` owned by `arcora`.
  * v0.7 keeper (`arcora-v07-feeds.{service,timer}`) was disabled,
    archived to `/root/_archive/arcora-v07-feeds.2026-05-10.tar.gz`
    (without `.env` or `node_modules`), and removed. Its `.env`
    containing the old deployer key was `shred -u`'d.
  * Old staging dir `/root/arcoradex-feeds/` was archived and shredded
    the same way.
  * SSH lockdown: ed25519 key added to `/root/.ssh/authorized_keys`;
    `/etc/ssh/sshd_config.d/01-arcora-lockdown.conf` sets
    `PasswordAuthentication no` and `KbdInteractiveAuthentication no`.
    Verified: password attempt rejected with
    `Permission denied (publickey)`; key auth works.

* **Vercel** (project `arcoradex`)
  * `FAUCET_PRIVATE_KEY` production env replaced with the faucet EOA
    key. Production redeployed (~5 min downtime during the swap).
  * Smoke test: `POST /api/faucet` to a fresh recipient returned 7 tx
    hashes; USDT on-chain balance = `1e9` (1000 USDT, 6 decimals).

## Cutover timeline (2026-05-10, all times CEST)

| Step | Time | Action |
|------|------|--------|
| T-3  | ~10:30 | `MigrateFeedsToV2` broadcast — 7 V2 feeds deployed, oracles rewired |
| T-3.5 | ~10:45 | Keeper first-fire under new EOA; 5 force-bumps for unchanged feeds |
| T-4–T-6 | 10:50–10:57 | systemd cutover; `/run/arcora` runtime-dir; timer re-enabled |
| T-7  | ~20:24 | `TransferTokenOwnershipToFaucet` broadcast — 7/7 tokens to faucet EOA |
| T-8  | ~20:28 | Vercel `FAUCET_PRIVATE_KEY` swap + production redeploy + smoke |
| T-9  | ~21:00 | v0.7 keeper disabled + key sweep; SSH key-only auth |
| T-10 | ~21:10 | End-to-end sanity; rollout doc; commit |

## Verification snapshot

```
keeper nonce       128
keeper balance     1.91 ETH
USDT feed writer   0xe8fe...b8c3  (keeper EOA)
USDT feed owner    0xe8E5...754b  (deployer EOA, Ownable2Step)
USDT latestAnswer  99976100  (~$0.99976)
USDT lastUpdatedAt 1778439385  (2026-05-10 18:56 UTC)
USDC token owner   0xA400...64E4  (faucet EOA)
EURC token owner   0xA400...64E4  (faucet EOA)
last 5 auto-fires  errored=0, last at 20:56 CEST
```

## Rollback notes

* On-chain feeds are immutable; rolling back means rewiring the
  registry to a different feed via `setOracle`. The pre-cutover feeds
  are still deployed but no longer wired in.
* Token ownership is reversible only by the faucet EOA calling
  `transferOwnership(deployer)`. The faucet key is in Vercel env.
* VPS rollback: `arcora-v07-feeds.tar.gz` archive holds the prior
  keeper config (sans secrets); SSH password auth re-enabled by
  removing `01-arcora-lockdown.conf` and `systemctl reload ssh`.
