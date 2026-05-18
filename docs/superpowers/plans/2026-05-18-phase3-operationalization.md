# Phase 3 Operationalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Operationalize the deployed Phase 3 oracle layer — migrate the secondary feeds' writer to the keeper EOA, make the keeper drive both primary and secondary feeds, and add an off-chain monitor that feeds the `CumulativeDeviationGuard`.

**Architecture:** One Forge governance script migrates the 7 secondary feeds' `writer` role to the keeper EOA via the Governance Safe. The in-repo keeper (`ops/keepalive/multi-feed-push.mjs`) is refactored so its per-feed push logic runs against both the primary and secondary feed. A new `ops/keepalive/guard-record.mjs` + systemd timer reads each aggregator and calls `CumulativeDeviationGuard.record`. The governance broadcast and the VPS deployment are operator steps.

**Tech Stack:** Solidity 0.8.26 / Foundry, Node.js (ESM) + viem, systemd.

**Spec:** `docs/superpowers/specs/2026-05-18-phase3-operationalization-design.md`

---

## File Structure

### Files created
| File | Purpose |
|------|---------|
| `contracts/script/MigrateSecondaryWriters.s.sol` | Governance script: `setWriter(keeperEOA)` on the 7 secondary feeds |
| `ops/keepalive/guard-record.mjs` | Off-chain monitor: reads aggregators, calls `CumulativeDeviationGuard.record` |
| `ops/keepalive/arcoradex-guard-record.service` | systemd oneshot unit for the monitor |
| `ops/keepalive/arcoradex-guard-record.timer` | systemd timer (every 30 min, offset from the keeper) |
| `docs/rollouts/2026-05-18-phase3-operationalization.md` | Rollout record for this phase |

### Files modified
| File | Changes |
|------|---------|
| `ops/keepalive/multi-feed-push.mjs` | Refactor per-feed push into a helper; push to both primary and secondary |
| `docs/rollouts/2026-05-14-phase3-oracle.md` | Fix the guard description; add `maxStaleSeconds` to the config table |
| auto-memory `arcoradex_role_eoas.md` + `MEMORY.md` | Add the 15 P3 addresses |

### Branches
- `phase3-ops/operationalization` (already exists with the spec; this plan is committed here)
- After the planning PR merges, implementation proceeds on `phase3-ops/rollout`

### Canonical addresses (verified — P2/P3 rollout docs)
- Governance Safe: `0x715f669D79Cc72d6685F8724c0B86f7B53d7e624`
- `CumulativeDeviationGuard` (P3_GUARD): `0x035447f8d97A23fFfC32aa8bFb8ffDbC7B94E608`
- Tokens / aggregators / secondary feeds — the 7-row table in `docs/rollouts/2026-05-14-phase3-oracle.md`.

---

### Task 1: Branch setup and baseline

**Files:** none modified.

- [ ] **Step 1: Confirm the planning PR merged to main**

```bash
git checkout main && git pull --ff-only origin main
git log -1 --format='%h %s'
```
Expected: HEAD is the P3-operationalization planning merge.

- [ ] **Step 2: Create the implementation branch**

```bash
git checkout -b phase3-ops/rollout
```

- [ ] **Step 3: Verify the contracts build**

```bash
cd contracts && forge build 2>&1 | tail -3
```
Expected: clean build (pre-existing lint notes are OK).

- [ ] **Step 4: Read the keeper and confirm its structure**

Read `ops/keepalive/multi-feed-push.mjs` and `ops/keepalive/package.json`. Confirm: it is ESM, imports `viem`, has a `FEEDS` array of 7 entries each with a `feed` env-var address, a `FEED_ABI`, and a per-feed loop in `main()` that band-checks, deviation-caps vs the on-chain `prev`, skips-if-current, and `setAnswer`s. This is the structure Task 3 refactors.

No commit — Task 1 is verification only.

---

### Task 2: `MigrateSecondaryWriters.s.sol` governance script

**Files:**
- Create: `contracts/script/MigrateSecondaryWriters.s.sol`

- [ ] **Step 1: Create the script**

Create `contracts/script/MigrateSecondaryWriters.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { MockChainlinkFeedV2 } from "../src/testnet/MockChainlinkFeedV2.sol";
import { SafeSigHelpers } from "../test/governance/SafeSigHelpers.sol";

/// @notice Migrates the `writer` role of the 7 P3 secondary MockChainlinkFeedV2
/// feeds from the deployer EOA to the keeper EOA, so the keeper can push prices
/// to the secondary feeds (enabling healthy two-source aggregation).
///
/// The Governance Safe owns the secondary feeds; `setWriter` is `onlyOwner`, so
/// each call is a Safe transaction executed via SafeSigHelpers.
///
/// Required env: DEPLOYER_PRIVATE_KEY (relays the Safe txs, pays gas),
/// KEEPER_ADDRESS (the new writer), P3_SECONDARY_<SYM> x7.
contract MigrateSecondaryWriters is Script {
    using SafeSigHelpers for Safe;

    string constant MNEMONIC =
        "test test test test test test test test test test test junk";
    Safe constant GOV_SAFE = Safe(payable(0x715f669D79Cc72d6685F8724c0B86f7B53d7e624));

    function run() external {
        require(block.chainid == 5042002, "Arc testnet only");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        require(keeper != address(0), "KEEPER_ADDRESS is zero");

        address[7] memory secondaries = [
            vm.envAddress("P3_SECONDARY_USDC"),
            vm.envAddress("P3_SECONDARY_USDT"),
            vm.envAddress("P3_SECONDARY_PYUSD"),
            vm.envAddress("P3_SECONDARY_DAI"),
            vm.envAddress("P3_SECONDARY_EURC"),
            vm.envAddress("P3_SECONDARY_TRYC"),
            vm.envAddress("P3_SECONDARY_BRLC")
        ];

        uint256[5] memory govKeys;
        for (uint256 i = 0; i < 5; i++) {
            govKeys[i] = vm.deriveKey(MNEMONIC, uint32(i));
        }
        uint256[] memory keys3 = new uint256[](3);
        keys3[0] = govKeys[0];
        keys3[1] = govKeys[1];
        keys3[2] = govKeys[2];

        vm.startBroadcast(deployerKey);

        for (uint256 i = 0; i < 7; i++) {
            address feed = secondaries[i];
            require(feed != address(0), "secondary feed address is zero");

            if (MockChainlinkFeedV2(feed).writer() == keeper) {
                console2.log("skip (writer already keeper):", feed);
                continue;
            }

            require(
                GOV_SAFE.execCall(
                    feed,
                    abi.encodeCall(MockChainlinkFeedV2.setWriter, (keeper)),
                    keys3
                ),
                "setWriter Safe exec failed"
            );
            require(MockChainlinkFeedV2(feed).writer() == keeper, "writer not migrated");
            console2.log("setWriter -> keeper:", feed);
        }

        vm.stopBroadcast();
        console2.log("Secondary-feed writer migration complete (keeper):", keeper);
    }
}
```

Notes for the implementer:
- Verify `MockChainlinkFeedV2` exposes `writer()` (public state var) and `setWriter(address)` — it does (`contracts/src/testnet/MockChainlinkFeedV2.sol`). If `setWriter` has a different signature, adapt the `abi.encodeCall`.
- Verify `SafeSigHelpers.execCall(Safe, address, bytes, uint256[])` is the real signature used by `P3GovernanceActions.s.sol` / `P3AggregatorGovernanceTest`. Match it.
- The skip-if-already-migrated guard makes the script safely re-runnable (same pattern as `P3GovernanceActions._accept`).

- [ ] **Step 2: Verify it compiles**

```bash
cd contracts && forge build 2>&1 | tail -5
```
Expected: clean compile (pre-existing lint notes OK; no errors).

- [ ] **Step 3: Confirm the full test suite still passes**

```bash
cd contracts && forge test 2>&1 | tail -3
```
Expected: 128 tests passing, 0 failed (this task adds no tests and must not break the build).

- [ ] **Step 4: Commit**

```bash
git add contracts/script/MigrateSecondaryWriters.s.sol
git commit -m "$(cat <<'EOF'
chore(deploy): MigrateSecondaryWriters — secondary-feed writer -> keeper EOA

Governance script: the Governance Safe calls setWriter(keeperEOA) on
each of the 7 P3 secondary feeds, so the keeper can push prices to
them and the OracleAggregators run in healthy two-source mode.
Re-runnable (skips a feed whose writer is already the keeper).

Spec: docs/superpowers/specs/2026-05-18-phase3-operationalization-design.md 3.1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Keeper dual-push refactor

**Files:**
- Modify: `ops/keepalive/multi-feed-push.mjs`

Refactor the keeper so each feed is pushed on both its primary and its secondary address, by extracting the per-feed-address push into a reusable helper and calling it twice. The existing per-push logic (sanity band already applied per symbol; deviation cap vs the on-chain `prev`; staleness refresh threshold; skip-when-current) must be preserved exactly — the helper IS that logic, lifted verbatim.

- [ ] **Step 1: Read the current keeper in full**

Read `ops/keepalive/multi-feed-push.mjs`. Identify the per-feed loop body in `main()` — from reading `prev`/`lastUpdated` through computing the capped `newAnswer`, the skip-if-current check, the `setAnswer` write, and the log line.

- [ ] **Step 2: Add the `secondary` field to each `FEEDS` entry**

In the `FEEDS` array, add a `secondary` property to each of the 7 entries, sourced from a `P3_SECONDARY_<SYM>` env var, e.g.:
```javascript
{ symbol: "USDC", feed: process.env.FEED_USDC, secondary: process.env.P3_SECONDARY_USDC, hardcodedAnswer1e8: 100_000_000n, band: { min: 1.00, max: 1.00 }, maxDevBps: 50 },
```
Do this for all 7 entries (`P3_SECONDARY_USDT`, `_PYUSD`, `_DAI`, `_EURC`, `_TRYC`, `_BRLC`).

- [ ] **Step 3: Extract the per-feed-address push into a helper**

Add a function — above `main()` — that performs one feed-address push. It takes the clients, a label (e.g. `"USDC primary"` / `"USDC secondary"`), the feed address, the band-checked target USD price, and `maxDevBps`; it does exactly what the current loop body does for a single address: read `prev`/`lastUpdated`, compute the deviation-capped `newAnswer` vs that address's own `prev`, apply the skip-when-current-and-fresh check, `setAnswer` + wait for receipt if needed, log, and return an outcome (`"updated"` / `"skipped"` / `"errored"`).

```javascript
/// Pushes one band-checked USD price to a single feed address. Encapsulates
/// the per-address logic (deviation cap vs that feed's own on-chain `prev`,
/// staleness-refresh, skip-when-current). Returns "updated" | "skipped" | "errored".
async function pushFeedAddress(publicClient, walletClient, label, feedAddr, usd, maxDevBps) {
    try {
        const targetAnswer = priceTo1e8(usd);
        const [prev, lastUpdated] = await Promise.all([
            publicClient.readContract({ address: feedAddr, abi: FEED_ABI, functionName: "latestAnswer" }),
            publicClient.readContract({ address: feedAddr, abi: FEED_ABI, functionName: "latestUpdatedAt" }),
        ]);
        const ageSeconds = Math.floor(Date.now() / 1000) - Number(lastUpdated);

        let newAnswer = targetAnswer;
        let capped = false;
        if (prev > 0n) {
            const maxDeltaAbs = (prev * BigInt(maxDevBps)) / 10_000n;
            const delta = targetAnswer > prev ? targetAnswer - prev : prev - targetAnswer;
            if (delta > maxDeltaAbs) {
                newAnswer = targetAnswer > prev ? prev + maxDeltaAbs : prev - maxDeltaAbs;
                capped = true;
            }
        }

        if (prev === newAnswer && ageSeconds < REFRESH_THRESHOLD_SECONDS) {
            log(`${label}: unchanged at ${prev}, fresh (${ageSeconds}s)`);
            return "skipped";
        }
        const hash = await walletClient.writeContract({
            address: feedAddr, abi: FEED_ABI, functionName: "setAnswer", args: [newAnswer],
        });
        await publicClient.waitForTransactionReceipt({ hash });
        const reason = capped
            ? `capped@${maxDevBps}bps (target=${targetAnswer})`
            : prev === newAnswer ? "refresh" : "value";
        log(`${label}: ${prev} -> ${newAnswer} (usd=${usd}, ${reason}, age=${ageSeconds}s) tx=${hash}`);
        return "updated";
    } catch (err) {
        log(`${label}: ERROR ${err?.message || err}`);
        return "errored";
    }
}
```

This helper must be the existing loop body, moved — not a reimplementation. Lift the exact arithmetic and the exact log strings; only parameterize the address and label.

- [ ] **Step 4: Rewrite the `main()` per-feed loop to call the helper twice**

In `main()`, replace the per-feed body so that, after the symbol-level work (price lookup from the `prices` map, `band` check), it calls `pushFeedAddress` once for the primary and once for the secondary, and folds both outcomes into the run counters. The symbol-level errors (missing price, out-of-band) are decided once and apply to both addresses. A missing `f.secondary` env var is handled like a missing `f.feed`: log it, count one error, still push the primary.

Structure:
```javascript
    for (const f of FEEDS) {
        const usd = prices.get(f.symbol);
        if (typeof usd !== "number") {
            log(`${f.symbol}: price source returned no value — skip both feeds`);
            errored += 2;
            continue;
        }
        if (usd < f.band.min || usd > f.band.max) {
            log(`${f.symbol}: price ${usd} outside band [${f.band.min}, ${f.band.max}] — skip both feeds`);
            skipped += 2;
            continue;
        }
        for (const [label, addr] of [[`${f.symbol} primary`, f.feed], [`${f.symbol} secondary`, f.secondary]]) {
            if (!addr) {
                log(`${label}: feed address env missing — skip`);
                errored++;
                continue;
            }
            const outcome = await pushFeedAddress(publicClient, walletClient, label, addr, usd, f.maxDevBps);
            if (outcome === "updated") updated++;
            else if (outcome === "skipped") skipped++;
            else errored++;
        }
    }
```
Adapt to match the file's actual variable names and counter style. Keep the final `done updated=.. skipped=.. errored=..` summary and the `process.exit(1)` on `errored > 0`.

- [ ] **Step 5: Syntax-check the script**

```bash
node --check ops/keepalive/multi-feed-push.mjs && echo "syntax OK"
```
Expected: `syntax OK`. (A live run requires the VPS env and is done in Task 6.)

- [ ] **Step 6: Self-review the refactor**

Confirm: the helper is the original per-address logic verbatim (same cap arithmetic, same skip condition, same log strings bar the label); the primary is still pushed even if the secondary env var is missing; the run-summary counters still add up; no symbol-level behaviour (band, price lookup) changed.

- [ ] **Step 7: Commit**

```bash
git add ops/keepalive/multi-feed-push.mjs
git commit -m "$(cat <<'EOF'
feat(keeper): push prices to both primary and secondary P3 feeds

Refactor the per-feed push into a pushFeedAddress() helper and call it
for both the primary feed (FEED_*) and the P3 secondary feed
(P3_SECONDARY_*). Each address keeps its own deviation cap vs its own
on-chain prev and its own staleness check. A missing secondary env var
is logged and counted as an error without blocking the primary push.

This makes the per-token OracleAggregator run in healthy two-source
mode instead of falling back to a single source.

Spec: docs/superpowers/specs/2026-05-18-phase3-operationalization-design.md 3.2

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `guard-record.mjs` monitor + systemd units

**Files:**
- Create: `ops/keepalive/guard-record.mjs`
- Create: `ops/keepalive/arcoradex-guard-record.service`
- Create: `ops/keepalive/arcoradex-guard-record.timer`

- [ ] **Step 1: Create `ops/keepalive/guard-record.mjs`**

```javascript
// ArcoraDEX CumulativeDeviationGuard recorder.
//
// Reads each per-token OracleAggregator's latestRoundData(), scales the
// 8-decimal answer to 1e18, and calls CumulativeDeviationGuard.record(token,
// price1e18). The guard is event-only: this produces the PriceObserved /
// CircuitBreakerTripped event stream that off-chain monitoring consumes.
//
// record() is permissionless; this signs with the keeper EOA (already funded).
// Designed to run from a systemd timer on the VPS (Type=oneshot every 30 min).

import {
    createPublicClient,
    createWalletClient,
    http,
    parseAbi,
    defineChain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const arcTestnet = defineChain({
    id: 5042002,
    name: "Arc Testnet",
    nativeCurrency: { name: "Arc", symbol: "ARC", decimals: 18 },
    rpcUrls: {
        default: { http: [process.env.ARC_TESTNET_RPC || "https://rpc.testnet.arc.network"] },
    },
});

const GUARD = "0x035447f8d97A23fFfC32aa8bFb8ffDbC7B94E608";

// (token, aggregator) pairs — fixed P3 deployment addresses.
const TOKENS = [
    { symbol: "USDC",  token: "0x3BFa09fF6467639f0981948385bA1018Ac07d22C", aggregator: "0x6c6519cB0C66c2269505833382f23D4e8f915480" },
    { symbol: "USDT",  token: "0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B", aggregator: "0x3e58dd7fD2729A27961Ffb11d37BFf42874cAa34" },
    { symbol: "PYUSD", token: "0xfdB2c86d010698401f0b969348DC58b6659B96a3", aggregator: "0x78cB5F03b420F0CD2E8adcb141069F31a38E07E8" },
    { symbol: "DAI",   token: "0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE", aggregator: "0x3e542b4d2EdBFC965028eB85140BcFEa6868A37E" },
    { symbol: "EURC",  token: "0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD", aggregator: "0x1357cf421A8c3b732A882e4812AFba6209EBEBbc" },
    { symbol: "TRYC",  token: "0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61", aggregator: "0xFE3FE7F2b2693D676E4831283dd1B81665AC9faA" },
    { symbol: "BRLC",  token: "0xa13c0935A98e2c175b31A4054f698819271a8FfC", aggregator: "0xF5021349E0D6e2ACB00bEb105D7793202ac3Aa46" },
];

const AGG_ABI = parseAbi([
    "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
]);
const GUARD_ABI = parseAbi([
    "function record(address token, uint256 price1e18) external",
]);

const ts = () => new Date().toISOString();
const log = (msg) => console.log(`[arcoradex-guard-record] ${ts()} ${msg}`);

async function main() {
    const pk = process.env.KEEPER_PRIVATE_KEY;
    if (!pk) {
        log("KEEPER_PRIVATE_KEY missing — abort");
        process.exit(2);
    }
    const account = privateKeyToAccount(pk);
    const publicClient = createPublicClient({ chain: arcTestnet, transport: http() });
    const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http() });

    let recorded = 0;
    let errored = 0;

    for (const t of TOKENS) {
        try {
            // latestRoundData() reverts if the aggregator's sources diverge or
            // are all unavailable — treat that as an errored token, not a hard stop.
            const round = await publicClient.readContract({
                address: t.aggregator, abi: AGG_ABI, functionName: "latestRoundData",
            });
            const answer = round[1]; // int256, 8-decimal
            if (answer <= 0n) throw new Error(`aggregator answer <= 0 (${answer})`);
            const price1e18 = answer * 10_000_000_000n; // 1e8 -> 1e18

            const hash = await walletClient.writeContract({
                address: GUARD, abi: GUARD_ABI, functionName: "record",
                args: [t.token, price1e18],
            });
            await publicClient.waitForTransactionReceipt({ hash });
            log(`${t.symbol}: recorded price1e18=${price1e18} tx=${hash}`);
            recorded++;
        } catch (err) {
            log(`${t.symbol}: ERROR ${err?.message || err}`);
            errored++;
        }
    }

    log(`done recorded=${recorded} errored=${errored}`);
    if (errored > 0) process.exit(1);
}

main().catch((err) => {
    log(`fatal: ${err?.message || err}`);
    process.exit(1);
});
```

Before finalizing: verify the 14 token/aggregator addresses against `docs/rollouts/2026-05-14-phase3-oracle.md` (the address tables) and the `GUARD` address against the same doc. They must match exactly.

- [ ] **Step 2: Syntax-check**

```bash
node --check ops/keepalive/guard-record.mjs && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 3: Create the systemd service unit**

Read the existing `ops/keepalive/arcoradex-feeds.service` first to match its style (User, EnvironmentFile path, hardening directives, WorkingDirectory). Then create `ops/keepalive/arcoradex-guard-record.service` mirroring it, but with:
- `Description=ArcoraDEX — record aggregator prices into CumulativeDeviationGuard (Arc testnet)`
- `ExecStart=` running `node /root/arcora-ops/relayer/guard-record.mjs` OR whatever path the keeper service uses for `multi-feed-push.mjs` — match the keeper service's actual deployed path and `EnvironmentFile`.

Do not invent paths — copy the keeper service's `EnvironmentFile=`, `WorkingDirectory=`, `User=`, and hardening lines verbatim, changing only `Description` and the script filename in `ExecStart`.

- [ ] **Step 4: Create the systemd timer unit**

Read `ops/keepalive/arcoradex-feeds.timer` first. Create `ops/keepalive/arcoradex-guard-record.timer` mirroring it, with:
- `Description=ArcoraDEX guard-record timer`
- An `OnCalendar=` 30-minute cadence offset from the keeper's by ~5 minutes so the recorder runs shortly after a keeper push (if the keeper runs at `*:00/*:30`, use `*:05/*:35`). Match the keeper timer's `OnCalendar` syntax and `Persistent`/`AccuracySec` style.
- `[Install] WantedBy=timers.target`.

- [ ] **Step 5: Commit**

```bash
git add ops/keepalive/guard-record.mjs ops/keepalive/arcoradex-guard-record.service ops/keepalive/arcoradex-guard-record.timer
git commit -m "$(cat <<'EOF'
feat(ops): guard-record monitor for CumulativeDeviationGuard

New ops/keepalive/guard-record.mjs reads each of the 7 OracleAggregators'
latestRoundData(), scales the 8-decimal answer to 1e18, and calls
CumulativeDeviationGuard.record(token, price) — producing the
PriceObserved / CircuitBreakerTripped event stream for off-chain
monitoring. Signs with the keeper EOA (record is permissionless).
A reverting aggregator errors only that token, not the whole run.

Adds the systemd oneshot service + 30-min timer, offset from the
keeper timer so recording follows a keeper push.

Spec: docs/superpowers/specs/2026-05-18-phase3-operationalization-design.md 3.3

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Auto-memory and rollout-doc updates

**Files:**
- Modify: auto-memory `arcoradex_role_eoas.md` and `MEMORY.md`
- Modify: `docs/rollouts/2026-05-14-phase3-oracle.md`

- [ ] **Step 1: Update the auto-memory**

The auto-memory directory is `/Users/huseyinarslan/.claude/projects/-Users-huseyinarslan-Desktop-arcora-v0-7-shared-vault-pool/memory/`. Read `arcoradex_role_eoas.md` there. Append the P3 oracle-layer addresses: the `CumulativeDeviationGuard` (`0x035447f8d97A23fFfC32aa8bFb8ffDbC7B94E608`), the 7 `OracleAggregator`s, and the 7 secondary feeds — sourced from `docs/rollouts/2026-05-14-phase3-oracle.md`. Add a one-line note that the secondary feeds' `writer` is the keeper EOA (post the Task 6 migration). Keep the file to one focused fact per the memory format; if it is getting long, summarize rather than dumping all 15 rows — a pointer to the rollout doc plus the guard address is enough. Update the `MEMORY.md` index line for that entry if its description changed.

This is a memory-file edit, not a repo commit — the auto-memory lives outside the repo. Make the edit; no `git add` for these two files.

- [ ] **Step 2: Fix the rollout-doc guard description**

In `docs/rollouts/2026-05-14-phase3-oracle.md`, find the description of the `CumulativeDeviationGuard` (the review noted it says "rolling signed drift" around lines 17 and 79). Correct it: the guard measures the **absolute** deviation `|price − anchor|` against a per-window anchor over a **tumbling** 24h window — it is not a rolling window and the deviation is unsigned. Reword both occurrences accurately.

- [ ] **Step 3: Add `maxStaleSeconds` to the rollout-doc config table**

In the same doc, the per-token configuration table lists divergence / cumulative / window columns. Add a `maxStaleSeconds` column with the per-token values from `contracts/script/DeployArcoraDexV3.s.sol` (the 6th `_list` argument): USDC/USDT/PYUSD/DAI = 3600, EURC = 14400, TRYC/BRLC = 86400. Verify these against that script before writing them.

- [ ] **Step 4: Commit the rollout-doc changes**

```bash
git add docs/rollouts/2026-05-14-phase3-oracle.md
git commit -m "$(cat <<'EOF'
docs(rollout): correct guard description + add maxStaleSeconds column

The P3 rollout doc described the CumulativeDeviationGuard as measuring
"rolling signed drift"; it measures absolute deviation from a
per-window anchor over a tumbling 24h window. Also adds the per-token
maxStaleSeconds values to the configuration table so it is a complete
record of the deployed oracle parameters.

Spec: docs/superpowers/specs/2026-05-18-phase3-operationalization-design.md 3.5

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Live broadcast and VPS deployment (operator-driven)

**Files:** none modified.

This task runs live against Arc testnet and the VPS. It is controller/operator work, performed the way P3's broadcasts and deploys were. Ideally run before the P3 Timelock batch executes (≈ 2026-05-19 21:35 UTC).

- [ ] **Step 1: Determine the keeper EOA address**

On the VPS, derive the keeper address from `KEEPER_PRIVATE_KEY` (do not print the key):
```bash
ssh root@194.163.136.1 'cd /root/arcora-ops/relayer && set -a; . /root/arcora-ops/.env 2>/dev/null; . ./.env 2>/dev/null; set +a; node -e "import(\"viem/accounts\").then(m=>console.log(m.privateKeyToAccount(process.env.KEEPER_PRIVATE_KEY.startsWith(\"0x\")?process.env.KEEPER_PRIVATE_KEY:\"0x\"+process.env.KEEPER_PRIVATE_KEY).address))"'
```
Adapt the env-file path to where `KEEPER_PRIVATE_KEY` actually lives (check the keeper systemd unit's `EnvironmentFile=`). Record the printed address — it is `KEEPER_ADDRESS` for the next step.

- [ ] **Step 2: Dry-run then broadcast `MigrateSecondaryWriters`**

From the repo, with `DEPLOYER_PRIVATE_KEY` (from `contracts/.env`), `KEEPER_ADDRESS` (Step 1), and the 7 `P3_SECONDARY_*` env vars set:
```bash
cd contracts && forge script script/MigrateSecondaryWriters.s.sol --rpc-url https://rpc.testnet.arc.network 2>&1 | tail -20
```
Expected: simulation succeeds, logs 7 `setWriter -> keeper` lines. Then broadcast:
```bash
cd contracts && forge script script/MigrateSecondaryWriters.s.sol --rpc-url https://rpc.testnet.arc.network --broadcast --slow --gas-estimate-multiplier 150 2>&1 | tail -15
```
Expected: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`.

- [ ] **Step 3: Verify the writer migration on-chain**

```bash
RPC=https://rpc.testnet.arc.network
for SYM in USDC USDT PYUSD DAI EURC TRYC BRLC; do
  # substitute each P3_SECONDARY_<SYM> address
  echo "$SYM secondary writer: $(cast call <P3_SECONDARY_SYM> 'writer()(address)' --rpc-url $RPC)"
done
```
Expected: every secondary feed's `writer` == the keeper EOA from Step 1.

- [ ] **Step 4: Deploy the updated keeper + the new monitor to the VPS**

Copy the updated `multi-feed-push.mjs`, the new `guard-record.mjs`, and the two new systemd units to the VPS, into the directory the keeper service already uses (match the keeper service's `WorkingDirectory`/`ExecStart` path — e.g. `/root/arcora-ops/relayer/`). Add the 7 `P3_SECONDARY_*` variables to the keeper's `EnvironmentFile`. Then:
```bash
ssh root@194.163.136.1 'cp /etc/systemd/system/arcoradex-guard-record.* /etc/systemd/system/ 2>/dev/null; systemctl daemon-reload && systemctl enable --now arcoradex-guard-record.timer && systemctl list-timers arcoradex-guard-record.timer'
```
Adapt the unit-file placement to wherever the units need to live. Confirm the timer is listed with a sane next-elapse.

- [ ] **Step 5: Live-verify both keeper and monitor**

Trigger one run of each and read the journal:
```bash
ssh root@194.163.136.1 'systemctl start arcoradex-feeds.service && journalctl -u arcoradex-feeds.service -n 30 --no-pager'
ssh root@194.163.136.1 'systemctl start arcoradex-guard-record.service && journalctl -u arcoradex-guard-record.service -n 20 --no-pager'
```
Expected: the keeper log shows both `<SYM> primary` and `<SYM> secondary` push/skip lines; the guard-record log shows `<SYM>: recorded ...` lines, `done recorded=7 errored=0` (or errors only on aggregators that legitimately revert).

No commit — Task 6 is operational.

---

### Task 7: Final checks and rollout doc

**Files:**
- Create: `docs/rollouts/2026-05-18-phase3-operationalization.md`

- [ ] **Step 1: Full contract suite**

```bash
cd contracts && forge build 2>&1 | tail -3 && forge test 2>&1 | tail -3
```
Expected: clean build; 128 tests passing, 0 failed.

- [ ] **Step 2: Syntax-check both ops scripts**

```bash
node --check ops/keepalive/multi-feed-push.mjs && node --check ops/keepalive/guard-record.mjs && echo "ops scripts OK"
```
Expected: `ops scripts OK`.

- [ ] **Step 3: Write the rollout doc**

Create `docs/rollouts/2026-05-18-phase3-operationalization.md` recording: the writer migration (the 7 secondary feeds now writable by the keeper EOA, broadcast tx), the keeper dual-push change, the new `guard-record` timer, and the doc/memory updates. Match the style of `docs/rollouts/2026-05-14-phase3-oracle.md`. Include the keeper EOA address and a short downstream note (the only remaining oracle item is a genuine independent second provider, P5).

- [ ] **Step 4: Commit**

```bash
git add docs/rollouts/2026-05-18-phase3-operationalization.md
git commit -m "$(cat <<'EOF'
docs(rollout): phase 3 operationalization rollout (2026-05-18)

Records the secondary-feed writer migration, the keeper dual-push
change, and the new guard-record monitor timer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: STOP — hand back to the controller for PR + merge.**

---

## Rollback

- **Task 2 (`MigrateSecondaryWriters`)** — the script is committed code; reverting the commit removes the script. The on-chain writer migration is undone by a new Safe `setWriter` call (the Governance Safe still owns the feeds).
- **Task 3 (keeper)** — `git revert` restores the single-feed keeper; redeploy to the VPS.
- **Task 4 (monitor)** — `systemctl disable --now arcoradex-guard-record.timer` on the VPS stops it; reverting the commit removes the files. The guard is event-only, so stopping the recorder has no on-chain effect.
- **Task 5 (docs/memory)** — `git revert` for the rollout doc; the memory edit is reverted by hand.
