# Treasury & Protocol-Fee Sweep

**Date:** 2026-06-05
**Branch:** `treasury/fee-sweep`
**Script:** `contracts/script/SweepProtocolFees.s.sol`
**Test:** `contracts/test/SweepProtocolFees.t.sol`
**Closes:** the wide-audit **R7** "fee destination" concern for the
deferred-governance testnet — accrued protocol fees now have a dedicated home
(a user-held treasury EOA) and a one-command sweep.

---

## 1. What the treasury is

There is **no separate treasury contract.** The protocol's "treasury" is simply
the `to` address of:

```solidity
ArcoraDexPool.withdrawProtocolFees(address token, uint256 amount, address to)
```

The operator holds a **single user-generated EOA** as the treasury. Protocol fees
accrue per-token in `pool.protocolFeesAccrued(token)` on every swap/withdraw
(the protocol share is `protocolFeeShareBps` of the swap fee). Sweeping calls
`withdrawProtocolFees(token, accrued, TREASURY)` for each token with a non-zero
balance, moving the full accrued amount to that EOA.

Giving fees a dedicated, named destination is the R7 mitigation for v1: fees are
not commingled with deployer/keeper operating funds, and the sweep is auditable
(one `ProtocolFeesWithdrawn(token, amount, to)` event per token).

## 2. Generate the treasury EOA

Generate it locally; **the private key never leaves your machine** — only the
address is shared with the sweep operator / passed via `TREASURY`.

```bash
cast wallet new
# Successfully created new keypair.
# Address:     0x<TREASURY_ADDRESS>     <-- share this; set as TREASURY
# Private key: 0x<KEEP_THIS_SECRET>     <-- store securely; NEVER commit / paste into the repo
```

Back up the private key in your secret store. The sweep script only ever takes
the **address** (`TREASURY`), so the key has zero exposure to the deploy tooling.

## 3. Run the sweep

The script reads everything from env (no hardcoded Pool/Registry addresses), so it
works against the freshly-deployed public-testnet Pool. It discovers the Registry
from the Pool (`pool.REGISTRY()`), enumerates listed tokens via
`tokensLength()` + `tokens(i)`, and sweeps each token whose accrued balance is
non-zero (zero-accrued tokens are skipped).

```bash
cd contracts
POOL=0x<POOL_ADDRESS> \
TREASURY=0x<TREASURY_ADDRESS> \
DEPLOYER_PRIVATE_KEY=0x<POOL_OWNER_KEY> \
  forge script script/SweepProtocolFees.s.sol \
    --rpc-url $ARC_TESTNET_RPC --broadcast
```

The broadcaster key may be supplied as either `SWEEPER_PRIVATE_KEY` (preferred) or
`DEPLOYER_PRIVATE_KEY` (fallback). **It must be the key of the current Pool
owner** — see §4.

What the operator must supply at run time:

| Env var                                      | Meaning                                                        |
| -------------------------------------------- | -------------------------------------------------------------- |
| `POOL`                                       | ArcoraDexPool address (the freshly-deployed testnet Pool)      |
| `TREASURY`                                   | Destination EOA address (from §2)                              |
| `SWEEPER_PRIVATE_KEY` / `DEPLOYER_PRIVATE_KEY` | Broadcaster key — **must be the Pool owner** (see §4)        |
| `ARC_TESTNET_RPC`                            | Arc testnet RPC endpoint                                       |

Pre-broadcast the script asserts `msg.sender == pool.owner()` and `!pool.paused()`,
so a wrong key or a paused Pool fails **loudly** before any transaction is sent.

## 4. Owner path: deployer-owned vs Timelock-owned

`withdrawProtocolFees` is `onlyOwner` + `whenNotPaused`. The Pool owner determines
which path you use:

- **Deployer-owned Pool (this script's path).** On the deferred-governance public
  testnet the freshly-deployed Pool is owned by the **deployer** until governance
  is handed off. Use the deployer key as the broadcaster — `this script works as-is`.

- **Timelock-owned Pool (post-handoff — do NOT use this script).** Once
  `DeployPublicTestnet`'s governance handoff completes (Pool ownership →
  `TimelockController`), an EOA can no longer call `withdrawProtocolFees`. The
  sweep must instead be a **Timelock batch proposed by the Governance Safe**: for
  each token with accrued fees, schedule a
  `pool.withdrawProtocolFees(token, accrued, TREASURY)` call via
  `TimelockController.scheduleBatch` (subject to the 48-hour delay), then
  `executeBatch`. The script's `msg.sender == pool.owner()` guard will reject the
  EOA broadcaster in this state with a message pointing here — that is intentional.
  Building the full Timelock-batch path is out of scope for this script.

To check which path applies: `cast call $POOL "owner()(address)" --rpc-url $ARC_TESTNET_RPC`.
If it returns the deployer EOA → deployer path. If it returns the Timelock
(`0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83`) → Timelock path.

## 5. The `whenNotPaused` requirement

`withdrawProtocolFees` is gated by `whenNotPaused` (audit fix **I-3**): when the
Pool is paused, users cannot exit, so the admin must not be able to extract
protocol fees either (symmetry). If a sweep is genuinely needed while paused, the
owner must `unpause()` first (owner-only — the Pause Guardian cannot unpause). The
script checks `!pool.paused()` up front and aborts with a clear message rather than
reverting opaquely on-chain.

## 6. Mainnet-forward upgrade (R7 / P5)

For mainnet, the user-held EOA treasury is replaced by:

- a **Safe multisig** as the fee recipient (no single-key custody of revenue), and
- a **dedicated fee-collector module** separated from governance ownership, so the
  fee-withdrawal role is not the same principal as the Timelock owner.

This is the tracked **P5** item D6 ("Fee-collector multisig separation from
governance ownership") in `docs/audit/p5-tracking.md`, and the accepted-risk
rationale is **R7** in `docs/audit/known-acceptable-risks.md`. The EOA treasury +
sweep script here is the v1 / testnet bridge until that module lands.
