# Fresh Key Ceremony + Public-Testnet Redeploy (Arc) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Regenerate every governance / pause / keeper / treasury / deployer key under a fresh, fully-controlled key ceremony and redeploy the complete ArcoraDEX public testnet on Arc (chainId 5042002) under that fresh governance, replacing the lost 2026-06-06 deploy — then rewire the SDK, keeper, and dApp to the new address book.

**Architecture:** The `DeployPublicTestnet` orchestrator already supports a FRESH governance mode (M-1 remediation): given `GOV_SAFE_OWNERS` / `PG_SAFE_OWNERS` / thresholds it deploys a brand-new Gov Safe + Pause-Guardian Safe + Timelock via `GovernanceFactory`, wires the fresh oracle layer to the new Gov Safe, and hands Pool/Registry to the new Timelock. The work here is therefore **mostly operational**: (0) audit which keys survive, (1) run a fresh key ceremony + regenerate the launch pack, (2) fund the fresh deployer + keepers, (3) dry-run, (4) broadcast, (5) hand off + lock down governance, (6) record the new address book + repoint the SDK, (7) rewire keeper + dApp, (8) verify with smoke + pause drills.

**Tech Stack:** Foundry (`forge`/`cast`), Solidity 0.8.26, OpenZeppelin `TimelockController` + `Ownable2Step`, Safe (`@safe-global/safe-contracts` v1.4.1), pnpm workspace TypeScript SDK + Next.js app, VPS keeper (Node) on `194.163.136.1`.

**Scope & target (read before starting):**
- **Redeploy target is Arc testnet.** `DeployPublicTestnet.run()` hard-guards `block.chainid == 5042002`. The existing orchestrator, token set, and oracle layer are Arc-only. "Redeploy everything" = re-run this orchestrator under fresh keys.
- **The Base-first V2 design (`docs/superpowers/specs/2026-06-08-base-first-v2-design.md`) is a separate, later plan.** It needs new immutable `ArcoraDexPoolV2` + Registry-v2 + Chainlink/Pyth `OracleAdapter` contracts and a new Base orchestrator that do not exist yet. Do not conflate the two. This plan restores a controllable Arc testnet; the V2 build follows.
- This is one rollout runbook, not independent subsystems. Phase 7 (keeper/app rewire) may be split into its own plan if desired.

**On-chain facts captured 2026-06-09 (verified via `cast` against `https://rpc.testnet.arc.network`):**
- All 7 tokens (`USDC 0x3BFa…`, `USDT 0x342B…`, `PYUSD 0xfdB2…`, `DAI 0xFf7d…`, `EURC 0xe08E…`, `TRYC 0xD564…`, `BRLC 0xa13c…`) have `owner() == 0xA400dBafeEb4e14B2836B5D7D040DbB4DcA164E4` — an **EOA**, the sole minter. Bootstrap-token minting requires this key.
- 2026-06-06 `Pool 0x532505501B1D789A724E9341B95aD9037aA1a3bf` and `Registry 0xc6D0FB58Bf2d529021A4E679F36Fe31842A97c97` are still owned by deployer `0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b` (governance handoff was never executed); `Pool.paused() == false`.
- Gas (native USDC) balances: old deployer `0xe8E5…754b` ≈ 8.07; launch-pack deployer `0x5Af7…7b13` = 20.0.
- Old deployer token balances: USDC `1043502716` (1043.5), TRYC `0`.
- `0xA400…64E4` is the `FAUCET_EOA` (ownership transferred via `TransferTokenOwnershipToFaucet.s.sol`); the faucet API (`app/app/api/faucet/route.ts`) mints with this key. It is the sole minter of all 7 tokens.

**DECISION (2026-06-09, confirmed by key-holder): BOTH the token minter `0xA400…64E4` AND the old deployer `0xe8E5…754b` are LOST (Branch C).** Consequence: the existing 7 tokens' mint authority is permanently frozen — no new mints, the faucet is dead, and the fresh deployer cannot be seeded from them. Therefore this plan takes **Branch C(b): deploy 7 fresh `MintableERC20` tokens + a fresh faucet**, which changes all token addresses everywhere (SDK, app, keeper, orchestrator). The orchestrator (`_cfg()` hardcodes the old token addresses) must be parameterized to accept the fresh token addresses. See Phase 2.

**Execution mode:** subagent-driven (superpowers:subagent-driven-development), and per the key-holder's instruction subagents use **only the `opus` or `fable` models** (never `sonnet`/`haiku`).

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `arcora-key-ceremony-launch-pack/00-control-audit.md` | Records which keys survived vs are lost; the decision matrix that branches Phases 1–2 | Create (outside repo, on Desktop) |
| `arcora-key-ceremony-launch-pack/01-addresses-to-send.env` | Blank collection form the key-holder fills with fresh addresses | Overwrite (reset to blanks) |
| `arcora-key-ceremony-launch-pack/03-deploy-env.template.env` | `DeployPublicTestnet` runtime config with the fresh addresses | Overwrite |
| `arcora-key-ceremony-launch-pack/05-vps-keeper-env.template.env` | Keeper VPS config (registry/guard/feeds filled post-deploy) | Overwrite post-deploy |
| `arcora-key-ceremony-launch-pack/06-address-map.md` | Role placement of the fresh addresses | Overwrite |
| `arcora-key-ceremony-launch-pack/07-deployed-addresses.env` | New deployed address ledger (post-broadcast) | Overwrite |
| `~/arcora-secrets/deploy.fresh.env` | Operator runtime env incl. `DEPLOYER_PRIVATE_KEY` (NEVER in repo or launch pack) | Create (secret, chmod 600) |
| `contracts/script/DeployPublicTestnet.s.sol` | Orchestrator (already FRESH-mode capable) | No change expected; verify only |
| `contracts/script/GovernanceFactory.sol` | Fresh Safe + Timelock factory (already done) | No change |
| `packages/sdk/src/addresses.ts` | SDK canonical address map | Modify → new deploy |
| `packages/sdk/test/unit/addresses.test.ts` | SDK address assertions | Modify → new deploy |
| `app/.env.example` | App env example with contract addresses | Modify → new deploy |
| `memory/arcoradex_role_eoas.md`, `MEMORY.md` | Project memory: role EOAs + live contracts | Modify → new deploy |
| `docs/rollouts/2026-06-09-fresh-redeploy.md` | Rollout record | Create |

**Secrets rule (non-negotiable, from `02-key-ceremony-checklist.md`):** no private key, mnemonic, seed phrase, or keystore password is ever written into the repo, the launch pack, or any `.env.template`. Keys live in a hardware wallet or a `chmod 600` file under `~/arcora-secrets/` and are passed to `forge`/`cast` via shell-only `export` or `--account`/`--ledger`.

---

## Phase 0 — Control audit (what survived)

### Task 0.1: Confirm which keys the key-holder still controls

**Files:**
- Create: `arcora-key-ceremony-launch-pack/00-control-audit.md`

This is the load-bearing decision. The funding path (Phase 2) and whether any existing EOA can be reused branch entirely on it. The key-holder must state, for each address, whether they hold the signing key:

- [ ] **Step 1: Fill the control matrix.** For each address below, mark `CONTROLLED` / `LOST`:

```text
| Address                                      | Role (as deployed)                     | Controlled? |
|----------------------------------------------|----------------------------------------|-------------|
| 0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b   | old deployer; owns live Pool+Registry  |   ?         |
| 0x5Af7A051592997A3992Cc9Db88fc6c02B7e97b13   | launch-pack intended deployer          |   ?         |
| 0xA400dBafeEb4e14B2836B5D7D040DbB4DcA164E4   | minter/owner of ALL 7 tokens           |   ?         |
| 0x36f4F380c72825c691f52e9E2264533B897D8DBA   | 2026-06-06 Gov Safe (3/5)              |   ?         |
| 0xf0ef92c20d64ff37bd49E55DFcF489627306D201   | 2026-06-06 Pause-Guardian Safe (2/3)   |   ?         |
| 8 hardware owners (06-address-map.md 1–8)    | Gov/PG Safe signers                    |   ?         |
| 0xB28B7208a2A03973907eeFA9baa4AAcA6d1654c0   | keeper primary                         |   ?         |
| 0xe4F317baCf62e4121aE77914629927F756a03B31   | keeper secondary                       |   ?         |
```

- [ ] **Step 2: Record the branch decision.** Write one of:
  - **Branch A (token minter retained):** `0xA400…64E4` is CONTROLLED → mint fresh bootstrap seed to the new deployer (Task 2.1A).
  - **Branch B (token minter lost, old deployer retained):** `0xA400…64E4` LOST but `0xe8E5…754b` CONTROLLED → re-use `0xe8E5…754b` token balances as seed, top up by transfer, or accept reduced bootstrap (Task 2.1B).
  - **Branch C (both lost):** mint authority gone → redeploy fresh tokens too (extends scope; see Task 2.1C note) OR launch with zero bootstrap and rely on the faucet for liquidity.

- [ ] **Step 3: Commit the audit file** (it lives outside the repo on the Desktop; no git commit — just save).

### Task 0.2: Snapshot the chain state the redeploy supersedes

**Files:** none (read-only)

- [ ] **Step 1: Re-verify the supersession facts** so the rollout record is accurate.

Run:
```bash
cd contracts && export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC=https://rpc.testnet.arc.network
cast call 0x532505501B1D789A724E9341B95aD9037aA1a3bf 'owner()(address)' --rpc-url $RPC
cast call 0x532505501B1D789A724E9341B95aD9037aA1a3bf 'paused()(bool)' --rpc-url $RPC
```
Expected: owner `0xe8E5…754b`, paused `false` (matches the captured facts; if changed, update `00-control-audit.md`).

### Task 0.3: Create the working branch

**Files:** none (git)

- [ ] **Step 1: Branch off main.**

Run:
```bash
git checkout -b ops/2026-06-09-fresh-redeploy
git status
```
Expected: `On branch ops/2026-06-09-fresh-redeploy`, clean tree.

---

## Phase 1 — Fresh key ceremony + launch-pack regeneration

### Task 1.1: Reset the address-collection form

**Files:**
- Modify: `arcora-key-ceremony-launch-pack/01-addresses-to-send.env`

- [ ] **Step 1: Overwrite `01-addresses-to-send.env` with a blank, fresh form.**

```env
# Fresh key ceremony 2026-06-09 — fill with NEWLY generated addresses ONLY.
# No private keys / mnemonics / seed phrases in this file. Distinctness rules enforced in Task 1.2.

# Gov Safe (3-of-5) owners — 5 distinct addresses:
GOV_SAFE_OWNERS=
GOV_SAFE_THRESHOLD=3

# Pause-Guardian Safe (2-of-3) owners — 3 distinct addresses:
PG_SAFE_OWNERS=
PG_SAFE_THRESHOLD=2

# Oracle writers — MUST differ from each other (H-2):
KEEPER_EOA=
KEEPER_SECONDARY=

# Fee sweep destination:
TREASURY=

# Faucet minter — sole owner/minter of the fresh tokens post-launch (Branch C(b)).
# MUST differ from DEPLOYER_EOA; its key signs faucet mints in the app API.
FAUCET_EOA=

# Deploy broadcaster (gas + holds bootstrap token seed; initial owner of fresh tokens):
DEPLOYER_EOA=
```

- [ ] **Step 2: Hand the form to the key-holder.** They generate all addresses on hardware wallet / password-protected keystore (per `02-key-ceremony-checklist.md`), fill the values, and return the file. Keys never leave their device.

### Task 1.2: Validate the collected fresh addresses

**Files:**
- Create (temporary): `arcora-key-ceremony-launch-pack/check-addresses.sh`

- [ ] **Step 1: Write the validation script** (mirrors `GovernanceFactory._validate` + the H-2 distinct-writer rule, so a bad set is caught before any gas is spent):

```bash
#!/usr/bin/env bash
set -euo pipefail
source ./01-addresses-to-send.env
fail() { echo "FAIL: $1"; exit 1; }
norm() { tr 'A-Z' 'a-z'; }
IFS=',' read -ra GOV <<< "$GOV_SAFE_OWNERS"
IFS=',' read -ra PG  <<< "$PG_SAFE_OWNERS"
[ "${#GOV[@]}" -eq 5 ] || fail "expected 5 GOV owners, got ${#GOV[@]}"
[ "${#PG[@]}"  -eq 3 ] || fail "expected 3 PG owners, got ${#PG[@]}"
[ "$GOV_SAFE_THRESHOLD" -ge 1 ] && [ "$GOV_SAFE_THRESHOLD" -le 5 ] || fail "bad GOV threshold"
[ "$PG_SAFE_THRESHOLD"  -ge 1 ] && [ "$PG_SAFE_THRESHOLD"  -le 3 ] || fail "bad PG threshold"
ALL=("${GOV[@]}" "${PG[@]}" "$KEEPER_EOA" "$KEEPER_SECONDARY" "$TREASURY" "$DEPLOYER_EOA")
for a in "${ALL[@]}"; do [[ "$a" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "not an address: $a"; done
[ "$(echo "$KEEPER_EOA" | norm)" != "$(echo "$KEEPER_SECONDARY" | norm)" ] || fail "H-2: keeper primary == secondary"
# Uniqueness within each Safe owner set:
dupes() { printf '%s\n' "$@" | norm | sort | uniq -d; }
[ -z "$(dupes "${GOV[@]}")" ] || fail "duplicate GOV owner"
[ -z "$(dupes "${PG[@]}")" ]  || fail "duplicate PG owner"
echo "OK: address set valid (5 gov, 3 pg, distinct keepers, well-formed)."
```

- [ ] **Step 2: Run it.**

Run:
```bash
cd arcora-key-ceremony-launch-pack && chmod +x check-addresses.sh && ./check-addresses.sh
```
Expected: `OK: address set valid (...)`. Any `FAIL:` line means re-collect before proceeding.

- [ ] **Step 3: Delete the temporary script** (`rm check-addresses.sh`) — keep the launch pack clean.

### Task 1.3: Regenerate the deploy + address-map files

**Files:**
- Modify: `arcora-key-ceremony-launch-pack/03-deploy-env.template.env`
- Modify: `arcora-key-ceremony-launch-pack/06-address-map.md`
- Modify: `arcora-key-ceremony-launch-pack/07-deployed-addresses.env`

- [ ] **Step 1: Overwrite `03-deploy-env.template.env`** with the fresh addresses (paste from the validated `01` file). Keep `GOV_USE_TEST_MNEMONIC=false`. Set `TIMELOCK_MIN_DELAY=0` for the launch window (we lock it to 48h in Phase 5 — see the orchestrator's 48h-accept timing note). Leave `HANDOFF_GOVERNANCE=` empty (handoff is a deliberate, separately-driven Phase 5 step).

```env
# DeployPublicTestnet — FRESH redeploy 2026-06-09. No private keys here.
ARC_TESTNET_RPC=https://rpc.testnet.arc.network
# DEPLOYER_PRIVATE_KEY supplied at runtime via ~/arcora-secrets/deploy.fresh.env (shell export only)
DEPLOYER_EOA=<fresh DEPLOYER_EOA>
GOV_SAFE_OWNERS=<fresh 5, comma-separated>
GOV_SAFE_THRESHOLD=3
PG_SAFE_OWNERS=<fresh 3, comma-separated>
PG_SAFE_THRESHOLD=2
TIMELOCK_MIN_DELAY=0
GOV_USE_TEST_MNEMONIC=false
KEEPER_EOA=<fresh keeper primary>
KEEPER_SECONDARY=<fresh keeper secondary>
HANDOFF_GOVERNANCE=
TREASURY=<fresh treasury>
# Post-broadcast ledger captured into 07-deployed-addresses.env, not here.
```

- [ ] **Step 2: Overwrite `06-address-map.md`** with the fresh role placement (the 5 gov owners, 3 pg owners, keeper primary/secondary, treasury, deployer), thresholds 3 and 2.

- [ ] **Step 3: Reset `07-deployed-addresses.env`** to a header marking the old ledger superseded and the new one pending:

```env
# SUPERSEDED 2026-06-09: the 2026-06-06 ledger lost its governance keys.
# New ledger written after the fresh broadcast (Phase 4). DO NOT use the 2026-06-06 addresses.
```

---

## Phase 2 — Fresh tokens + parameterized orchestrator + funding (Branch C(b))

> Both the minter and old deployer are lost, so we deploy **7 fresh `MintableERC20` tokens** owned by the fresh deployer, parameterize the orchestrator to consume them, mint bootstrap seed, and fund gas. `DEPLOYER_EOA` / `FAUCET_EOA` are the fresh addresses from Task 1.1.
>
> **Prereq:** create the secret runtime env `~/arcora-secrets/deploy.fresh.env` (template in Task 3.1, Step 1) BEFORE the first `source` here — it holds `DEPLOYER_PRIVATE_KEY` + the governance/keeper/treasury vars; the `TOKEN_*` vars get appended in Task 2.2, Step 2.

### Task 2.1: Parameterize the orchestrator + token config to accept fresh token addresses (TDD)

**Files:**
- Modify: `contracts/script/DeployPublicTestnet.s.sol` (the 7 hardcoded `token` fields in `_cfg()`)
- Create: `contracts/script/DeployTokensFresh.s.sol`
- Test: `contracts/test/DeployPublicTestnetTokenParam.t.sol` (new), plus keep the existing gap/coupling tests green

**Design constraint:** `_cfg()` is `internal pure` and is coupled to the gap/coupling tests via `_aggWiring`/`_repointTarget`. Do **not** break that coupling. Introduce token-address parameterization as a *separate* env-driven override that leaves the per-token economic config (decimals, bands, seeds, deviation caps) intact and the existing tests green. Default (no env) must resolve to the existing hardcoded addresses so legacy behavior is unchanged.

- [ ] **Step 1: Write the failing test.** Assert that when `TOKEN_USDC`…`TOKEN_BRLC` env vars are set, the orchestrator's resolved token set uses those addresses; when unset, it falls back to the historical constants.

```solidity
// contracts/test/DeployPublicTestnetTokenParam.t.sol
function test_tokenAddressesOverrideFromEnv() public {
    address fresh = address(0xBEEF);
    vm.setEnv("TOKEN_USDC", vm.toString(fresh));
    DeployPublicTestnet d = new DeployPublicTestnet();
    assertEq(d.resolvedTokens()[0], fresh);          // USDC slot now the fresh address
}
function test_tokenAddressesDefaultToConstants() public {
    DeployPublicTestnet d = new DeployPublicTestnet();
    assertEq(d.resolvedTokens()[0], 0x3BFa09fF6467639f0981948385bA1018Ac07d22C);
}
```

- [ ] **Step 2: Run it to confirm it fails.**

Run: `cd contracts && forge test --match-contract DeployPublicTestnetTokenParam -vvv`
Expected: FAIL — `resolvedTokens()` does not exist yet.

- [ ] **Step 3: Implement the override.** Add a `view` helper `resolvedTokens()` that reads `vm.envOr("TOKEN_<SYM>", <constant>)` per token and have `run()` apply it over `_cfg()[i].token` before any use. Keep `_cfg()` pure (it keeps the constants as defaults); the env override is layered in `run()`/the new helper only.

- [ ] **Step 4: Run the new test + the full existing suite to confirm green.**

Run: `cd contracts && forge test --match-contract "DeployPublicTestnetTokenParam|DeployPublicTestnet" -vvv && forge test`
Expected: new tests PASS; all pre-existing gap/coupling tests still PASS.

- [ ] **Step 5: Write `DeployTokensFresh.s.sol`** — deploys 7 fresh `MintableERC20(name, symbol, decimals, deployer)` (decimals per `_cfg`: USDC/USDT/PYUSD/EURC/TRYC/BRLC = 6, DAI = 18), mints each token's `targetSeed` to the deployer, and logs `TOKEN_<SYM>=` lines for the env. Guard `block.chainid == 5042002`.

- [ ] **Step 6: Commit.**

```bash
git add contracts/script/DeployPublicTestnet.s.sol contracts/script/DeployTokensFresh.s.sol contracts/test/DeployPublicTestnetTokenParam.t.sol
git commit -m "feat(deploy): env-parameterized token addresses + fresh-token deploy script (Branch C redeploy)"
```

### Task 2.2: Deploy the fresh tokens + mint bootstrap seed

**Files:** none (broadcast)

- [ ] **Step 1: Broadcast `DeployTokensFresh`** (deployer is the fresh broadcaster + token owner; can mint).

Run:
```bash
cd contracts && source ~/arcora-secrets/deploy.fresh.env
forge script script/DeployTokensFresh.s.sol --rpc-url "$ARC_TESTNET_RPC" --broadcast -vvv | tee /tmp/arcora-tokens-2026-06-09.log
```
Expected: 7 token deploys land; `TOKEN_USDC=` … `TOKEN_BRLC=` printed; deployer holds each `targetSeed`.

- [ ] **Step 2: Append the `TOKEN_*` addresses** to `~/arcora-secrets/deploy.fresh.env` (as `export TOKEN_USDC=…` etc.) so the orchestrator (Phase 3/4) picks up the fresh tokens.

### Task 2.3: Fund the fresh deployer + keepers with gas

**Files:** none

- [ ] **Step 1: Send native (USDC-gas)** to the fresh deployer (≥3), keeper primary (≥1), keeper secondary (≥1), and faucet EOA (≥1). The deployer needs gas for ~30+ contract deploys (7 tokens already spent in Task 2.2, plus core + 7 primaries + 7 secondaries + 14 aggregators + guard + governance).

Run:
```bash
RPC=https://rpc.testnet.arc.network
cast send <fresh DEPLOYER_EOA>     --value 3ether --account arcora-funder --rpc-url $RPC
cast send <fresh KEEPER_EOA>       --value 1ether --account arcora-funder --rpc-url $RPC
cast send <fresh KEEPER_SECONDARY> --value 1ether --account arcora-funder --rpc-url $RPC
cast send <fresh FAUCET_EOA>       --value 1ether --account arcora-funder --rpc-url $RPC
```
Expected: four `status 1` tx hashes. (`arcora-funder` = any controllable Arc-testnet-funded wallet; the lost `0x5Af7…`/`0xe8E5…` cannot be used.)

### Task 2.4: Verify funding meets the orchestrator's needs

**Files:** none

- [ ] **Step 1: Assert deployer gas + fresh-token seed balances.**

Run:
```bash
source ~/arcora-secrets/deploy.fresh.env; RPC=$ARC_TESTNET_RPC; D=$DEPLOYER_EOA
cast balance $D --rpc-url $RPC
for t in $TOKEN_USDC $TOKEN_USDT $TOKEN_PYUSD $TOKEN_DAI $TOKEN_EURC $TOKEN_TRYC $TOKEN_BRLC; do
  cast call $t 'balanceOf(address)(uint256)' $D --rpc-url $RPC
done
```
Expected: deployer gas ≥ ~2 ether; each fresh-token balance == its `targetSeed` (USDC/USDT/PYUSD `100000000`, DAI `100000000000000000000`, EURC `86000000`, TRYC `1800000000`, BRLC `516000000`).

---

## Phase 3 — Dry-run (simulation, no broadcast)

### Task 3.1: Simulate the orchestrator against the live Arc fork

**Files:**
- Create (secret): `~/arcora-secrets/deploy.fresh.env`

- [ ] **Step 1: Create the secret runtime env** (chmod 600; holds the private key, never committed):

```bash
mkdir -p ~/arcora-secrets && chmod 700 ~/arcora-secrets
cat > ~/arcora-secrets/deploy.fresh.env <<'EOF'
export DEPLOYER_PRIVATE_KEY=0x<fresh deployer private key>
export ARC_TESTNET_RPC=https://rpc.testnet.arc.network
export GOV_SAFE_OWNERS=<fresh 5, comma-separated>
export GOV_SAFE_THRESHOLD=3
export PG_SAFE_OWNERS=<fresh 3, comma-separated>
export PG_SAFE_THRESHOLD=2
export TIMELOCK_MIN_DELAY=0
export GOV_USE_TEST_MNEMONIC=false
export KEEPER_EOA=<fresh keeper primary>
export KEEPER_SECONDARY=<fresh keeper secondary>
export TREASURY=<fresh treasury>
EOF
chmod 600 ~/arcora-secrets/deploy.fresh.env
```

- [ ] **Step 2: Run the simulation WITHOUT `--broadcast`.** This exercises `GovernanceFactory._validate` (reverts on any bad owner/threshold), runs all 8 steps in-memory, and asserts every deployed-state invariant.

Run:
```bash
cd contracts && source ~/arcora-secrets/deploy.fresh.env
forge script script/DeployPublicTestnet.s.sol:DeployPublicTestnet --rpc-url "$ARC_TESTNET_RPC" -vvv
```
Expected (key lines):
- `Governance mode:  FRESH (new Gov Safe/Timelock)`
- `Oracle layer owner == resolved Gov Safe (M-1): ok`
- `Writers separated: primary == KEEPER_EOA, secondary == KEEPER_SECONDARY (H-2): ok`
- `All 7 registry oracles resolve via P3.5 agg whose PRIMARY == bounded feed: ok (GAP#5)`
- a `=== ADDRESS LEDGER ===` block, and `Script ran successfully.`
- Any `revert`/`FAIL` → fix the env (usually a malformed owner list or insufficient seed) before Phase 4.

---

## Phase 4 — Broadcast the fresh redeploy

### Task 4.1: Execute the orchestrator on Arc and capture the ledger

**Files:**
- Modify: `arcora-key-ceremony-launch-pack/07-deployed-addresses.env`

- [ ] **Step 1: Broadcast.**

Run:
```bash
cd contracts && source ~/arcora-secrets/deploy.fresh.env
forge script script/DeployPublicTestnet.s.sol:DeployPublicTestnet \
  --rpc-url "$ARC_TESTNET_RPC" --broadcast --slow -vvv | tee /tmp/arcora-redeploy-2026-06-09.log
```
Expected: on-chain txs land; the final `=== ADDRESS LEDGER ===` block prints `REGISTRY_V3=`, `POOL_V3=`, `LP_V3=`, `GUARD=`, `GOVERNANCE_SAFE=`, `TIMELOCK=`, `PAUSE_GUARDIAN_SAFE=`, and per-token `FEED_*` / `P3_SECONDARY_*` / `P3_5_AGG_*`.

- [ ] **Step 2: Write the captured ledger** into `07-deployed-addresses.env` (replace the superseded header), tagged `# DEPLOYED 2026-06-09 — fresh governance, chainid 5042002`.

- [ ] **Step 3: Sanity-check the live deploy.**

Run:
```bash
RPC=https://rpc.testnet.arc.network
cast call <new REGISTRY_V3> 'pool()(address)' --rpc-url $RPC          # == <new POOL_V3>
cast call <new POOL_V3> 'paused()(bool)' --rpc-url $RPC               # false
cast call <new GOVERNANCE_SAFE> 'getThreshold()(uint256)' --rpc-url $RPC  # 3
cast call <new PAUSE_GUARDIAN_SAFE> 'getThreshold()(uint256)' --rpc-url $RPC  # 2
```

---

## Phase 5 — Governance handoff + lockdown

> At this point Pool/Registry are still **deployer-owned** (orchestrator ran with `HANDOFF_GOVERNANCE` empty). The bounded PRIMARY feeds are also deployer-owned (the orchestrator never transfers them). We now move all of it to the fresh governance and lock the Timelock delay to 48h.

### Task 5.1: Transfer Pool + Registry + primary feeds to the fresh Timelock / Gov Safe

**Files:** none

- [ ] **Step 1: Transfer Pool + Registry ownership to the new Timelock** (Ownable2Step → pending).

Run:
```bash
cd contracts && source ~/arcora-secrets/deploy.fresh.env
cast send <new POOL_V3>     'transferOwnership(address)' <new TIMELOCK> --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$ARC_TESTNET_RPC"
cast send <new REGISTRY_V3> 'transferOwnership(address)' <new TIMELOCK> --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$ARC_TESTNET_RPC"
```
Expected: two `status 1`. `Pool.pendingOwner() == <new TIMELOCK>`.

- [ ] **Step 2: Transfer the 7 bounded PRIMARY feeds to the Gov Safe** (so the deployer retains no oracle authority). Use the `FEED_*` addresses from the ledger.

Run (per feed):
```bash
cast send <FEED_USDC> 'transferOwnership(address)' <new GOVERNANCE_SAFE> --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$ARC_TESTNET_RPC"
# repeat for FEED_USDT, FEED_PYUSD, FEED_DAI, FEED_EURC, FEED_TRYC, FEED_BRLC
```
Expected: 7 × `status 1` (each feed `pendingOwner() == Gov Safe`).

### Task 5.2: Gov Safe accepts ownership of Pool/Registry and lowers no delay

**Files:** none (Safe Transaction Service / Safe UI; requires 3-of-5 signatures)

The Timelock executes `Pool.acceptOwnership()` / `Registry.acceptOwnership()`. Because `TIMELOCK_MIN_DELAY` was deployed at **0**, schedule+execute run back-to-back with no wait.

- [ ] **Step 1: Gov Safe schedules + executes a Timelock batch** calling, in order:
  1. `Pool.acceptOwnership()`
  2. `Registry.acceptOwnership()`
  3. `Timelock.updateDelay(172800)` (lock to 48h going forward)

  Use `cast calldata` to build each inner call, then the Gov Safe submits `TimelockController.scheduleBatch(...)` followed by `executeBatch(...)` (delay 0 ⇒ immediate). Collect 3 owner signatures via the Safe UI/CLI.

- [ ] **Step 2: Verify the handoff + lockdown.**

Run:
```bash
RPC=https://rpc.testnet.arc.network
cast call <new POOL_V3> 'owner()(address)' --rpc-url $RPC          # == <new TIMELOCK>
cast call <new REGISTRY_V3> 'owner()(address)' --rpc-url $RPC      # == <new TIMELOCK>
cast call <new TIMELOCK> 'getMinDelay()(uint256)' --rpc-url $RPC   # 172800
```

### Task 5.3: Gov Safe accepts the pending oracle-layer ownerships

**Files:** none (Safe UI, 3-of-5)

The orchestrator left `transferOwnership → Gov Safe` pending (Ownable2Step) on: the `CumulativeDeviationGuard`, the 7 secondary feeds, the 7 V1 aggregators, and (from Task 5.1 Step 2) the 7 primary feeds. The P3.5 V2 aggregators were constructed owned by the Gov Safe directly (no accept needed).

- [ ] **Step 1: Gov Safe calls `acceptOwnership()`** on the guard, the 7 secondaries, the 7 V1 aggregators, and the 7 primaries (one batched Safe tx is fine).

- [ ] **Step 2: Verify no contract in the oracle layer is still deployer-owned.**

Run:
```bash
RPC=https://rpc.testnet.arc.network
cast call <GUARD> 'owner()(address)' --rpc-url $RPC               # == Gov Safe
cast call <FEED_USDC> 'owner()(address)' --rpc-url $RPC           # == Gov Safe
cast call <P3_5_AGG_USDC> 'owner()(address)' --rpc-url $RPC       # == Gov Safe (already)
```
Expected: every queried `owner()` is the new Gov Safe.

---

## Phase 6 — Record the new address book + repoint the SDK

### Task 6.1: Update project memory

**Files:**
- Modify: `memory/arcoradex_role_eoas.md`
- Modify: `MEMORY.md`

- [ ] **Step 1: Replace the Protocol EOAs + Live contracts + token-oracle tables** in `memory/arcoradex_role_eoas.md` with the fresh deployer, Gov Safe, PG Safe, Timelock, and the new Registry/Pool/LP/guard/feed/aggregator addresses. Remove the public-Foundry-mnemonic test-signer table (no longer the governance).
- [ ] **Step 2: Update `MEMORY.md`** "Key EOAs" + "Live contracts (V3, current)" + deployment-history with a `2026-06-09 fresh redeploy` line.

### Task 6.2: Repoint the SDK address map + token addresses (TDD)

**Files:**
- Modify: `packages/sdk/src/addresses.ts`
- Test: `packages/sdk/test/unit/addresses.test.ts`
- Modify: `app/lib/faucet-tokens.ts` (the 7 FRESH token addresses the faucet dispenses)
- Test: `app/lib/__tests__/faucet-tokens.test.ts`

> Branch C(b): the 7 token addresses ALSO changed. Update them in the SDK map, the app faucet token list, and `app/.env.example` alongside the contract addresses.

- [ ] **Step 1: Update the test first** to assert the NEW Arc addresses (Registry/Pool/LP **and the 7 fresh `TOKEN_*`**) the SDK must export.

```ts
// in packages/sdk/test/unit/addresses.test.ts — replace the 2026-06-06 expectations
expect(addresses[5042002].registry).toBe('<new REGISTRY_V3>')
expect(addresses[5042002].pool).toBe('<new POOL_V3>')
expect(addresses[5042002].lp).toBe('<new LP_V3>')
```

- [ ] **Step 2: Run the test to confirm it fails** (still pointing at old addresses).

Run: `pnpm --filter @arcoradex/sdk test addresses`
Expected: FAIL — received `0x5325…` / `0xc6D0…`, expected the new addresses.

- [ ] **Step 3: Update `packages/sdk/src/addresses.ts`** with the new Registry/Pool/LP, the 7 fresh token addresses, and any feed/aggregator exports the file carries. Update `app/lib/faucet-tokens.ts` + its test to the 7 fresh token addresses.

- [ ] **Step 4: Run the test to confirm it passes.**

Run: `pnpm --filter @arcoradex/sdk test addresses`
Expected: PASS.

- [ ] **Step 5: Update `app/.env.example`** with the new contract addresses (mirror of the SDK map).

- [ ] **Step 6: Rebuild the SDK** so `dist/` matches `src/`.

Run: `pnpm --filter @arcoradex/sdk build`
Expected: build succeeds; `dist/` no longer contains `0x5325…`/`0xc6D0…`.

- [ ] **Step 7: Commit.**

```bash
git add packages/sdk/src/addresses.ts packages/sdk/test/unit/addresses.test.ts app/lib/faucet-tokens.ts app/lib/__tests__/faucet-tokens.test.ts app/.env.example memory/ MEMORY.md
git commit -m "chore(redeploy): point SDK/app/faucet/memory at 2026-06-09 fresh Arc deploy"
```

### Task 6.3: Write the rollout record

**Files:**
- Create: `docs/rollouts/2026-06-09-fresh-redeploy.md`

- [ ] **Step 1: Document** the supersession (lost 2026-06-06 keys), the fresh governance set, the new ledger, the handoff txs, and the verification results. Commit it.

---

## Phase 7 — Rewire faucet + keeper VPS + dApp

### Task 7.0: Hand fresh-token mint authority to the faucet EOA

**Files:** none (`script/TransferTokenOwnershipToFaucet.s.sol`, reused)

After bootstrap seeding, the fresh deployer transfers each fresh token's ownership to `FAUCET_EOA` so the faucet (and only the faucet) can mint to users — mirroring the original launch posture. Do this AFTER Task 2.2 seeding and the Phase 4 broadcast (the orchestrator does not need to mint; it only `deposit`s the already-seeded balance).

- [ ] **Step 1: Run the transfer** with `FAUCET_EOA` = the fresh faucet address and the fresh `TOKEN_*` set.

Run:
```bash
cd contracts && source ~/arcora-secrets/deploy.fresh.env
export FAUCET_EOA=<fresh FAUCET_EOA>
forge script script/TransferTokenOwnershipToFaucet.s.sol --rpc-url "$ARC_TESTNET_RPC" --broadcast -vvv
```
Expected: 7 × ownership transfer; each fresh token `owner() == FAUCET_EOA`. (Confirm `TransferTokenOwnershipToFaucet.s.sol` iterates the fresh `TOKEN_*` set, not the old constants — adjust it to read the env token list if needed.)

- [ ] **Step 2: Wire the faucet signer.** Put `FAUCET_PRIVATE_KEY` (the fresh faucet key) into the app's secret manager (Vercel env / Upstash-adjacent secret) — never the repo. The faucet API (`app/app/api/faucet/route.ts`) signs mints with it.

### Task 7.1: Regenerate keeper config + redeploy on the VPS

**Files:**
- Modify: `arcora-key-ceremony-launch-pack/05-vps-keeper-env.template.env`

- [ ] **Step 1: Fill `05-vps-keeper-env.template.env`** `REGISTRY_ADDRESS`, `GUARD_ADDRESS`, and all `FEED_*` / `P3_SECONDARY_*` with the new ledger values.
- [ ] **Step 2: Deploy to the VPS.** SSH `root@194.163.136.1` (credentials in CLAUDE.md). Place the env (secrets — keeper primary/secondary keys — from the secret manager, NOT the template), point the keeper at the new registry/feeds, restart the keeper service.
- [ ] **Step 3: Verify** the keeper pushes both legs: confirm a fresh `latestRoundData` update on a primary feed (writer == new keeper primary) and a secondary feed (writer == new keeper secondary) within one cadence.

```bash
RPC=https://rpc.testnet.arc.network
cast call <FEED_USDC> 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $RPC          # updatedAt recent
cast call <P3_SECONDARY_USDC> 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $RPC  # updatedAt recent
```

### Task 7.2: Redeploy the dApp with the new addresses

**Files:** none (Vercel env)

- [ ] **Step 1: Update Vercel env** (`04-app-vercel-env.template.env` values + the new contract addresses) and trigger a production deploy of `app/`.
- [ ] **Step 2: Verify** the app loads pool state, a quote, and a faucet claim against the new deploy.

---

## Phase 8 — Verification (smoke + pause drill)

### Task 8.1: Smoke test the live deploy

**Files:** none (`script/SmokeArcoraDex.s.sol`)

- [ ] **Step 1: Run the smoke script** against the new addresses (deposit, swap, quote, oracle read).

Run:
```bash
cd contracts && source ~/arcora-secrets/deploy.fresh.env
forge script script/SmokeArcoraDex.s.sol --rpc-url "$ARC_TESTNET_RPC" -vvv
```
Expected: deposit + swap succeed; NAV non-zero; no `NoValidPrice` reverts.

### Task 8.2: Pause drill

**Files:** none

- [ ] **Step 1: Pause Guardian (2/3) pauses the Pool**, confirm `paused() == true`, swaps revert.
- [ ] **Step 2: Gov Safe (3/5) unpauses via the Timelock** (now 48h delay — for the drill, schedule and note the ETA; or run the drill before the Phase 5 `updateDelay(172800)` so the unpause is immediate, then re-pause/unpause is documented). Record the drill in the rollout doc.

---

## Self-Review notes

- **Spec coverage:** This plan covers the user's two asks — "start with deploy infrastructure" (Phases 1, 3–7) and "fresh key ceremony now" (Phases 1–2, 5). It does **not** implement the Base-first V2 design; that is explicitly a separate plan (see Scope).
- **Branch points are explicit, not placeholders:** Task 0.1 records control facts that select Task 2.1A/B/C — these are runtime decisions, not "TBD".
- **`<...>` markers** are runtime-captured on-chain addresses / freshly-generated keys, by definition unknowable at plan-time; each has an explicit capture step (Task 4.1 Step 1, Task 1.1). They are not skipped implementation detail.
- **Type/name consistency:** env var names match the orchestrator (`GOV_SAFE_OWNERS`, `KEEPER_EOA`, `KEEPER_SECONDARY`, `TIMELOCK_MIN_DELAY`, `HANDOFF_GOVERNANCE`) and `GovernanceFactory.resolveConfig()` exactly.
- **Known orchestrator quirks surfaced:** (1) bounded PRIMARY feeds stay deployer-owned post-run → Task 5.1 Step 2 transfers them; (2) Timelock constructed at the env delay → deploy at 0, lock to 48h in Task 5.2 Step 1.3; (3) zero-balance tokens are SKIPped, not fatal → Branch B/C rely on this.
