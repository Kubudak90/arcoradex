# ArcoraDEX — Spearbit Audit Scope

ArcoraDEX is a public-LP, oracle-priced multi-stablecoin shared vault that issues a single ERC20 receipt token (ADEX-LP) and settles all operations through NAV-based accounting.

## System overview

ArcoraDEX is an oracle-priced multi-stablecoin vault supporting seven stablecoins: USDC, USDT, PYUSD, DAI, EURC, TRYC, and BRLC. Liquidity providers deposit any listed token and receive a single shared ADEX-LP receipt token; the LP token price is derived from the Net Asset Value (NAV) of all reserves. NAV is computed from an explicit `reserves[]` mapping — balances are tracked internally rather than read from `balanceOf`, which structurally blocks donation-inflation attacks. Each token has a two-source oracle aggregation layer (`OracleAggregator`): a primary and secondary Chainlink-compatible feed must agree within a per-token divergence cap; the pool further applies a per-block deviation ratchet (`lastAcceptedPrice`) and a fallback cache to preserve availability when a feed goes stale. A permissionless `CumulativeDeviationGuard` tracks 24 h tumbling-window price drift per token and emits events consumed by off-chain monitoring; it has no on-chain auto-pause in the current phase.

## In scope

### Core contracts

| Contract | Path | LoC | Responsibility |
|---|---|---|---|
| `ArcoraDexPool` | `contracts/src/ArcoraDexPool.sol` | 678 | Core vault: deposit, withdraw, swap, oracle pricing, pause/unpause, fee management |
| `ArcoraDexLP` | `contracts/src/ArcoraDexLP.sol` | 42 | ERC20 LP receipt token; mint/burn restricted to `MINTER` (the Pool); propagates min-hold lock on transfer |
| `ArcoraDexRegistry` | `contracts/src/ArcoraDexRegistry.sol` | 99 | Per-token catalogue: decimals, USD oracle, deviation cap, staleness threshold, active flag |
| `OracleAggregator` | `contracts/src/oracle/OracleAggregator.sol` | 112 | 2-source `IChainlinkAggregator` wrapper; averages primary and secondary feeds when they agree within `maxDivergenceBps`; falls back to the surviving source on single-source failure |
| `CumulativeDeviationGuard` | `contracts/src/oracle/CumulativeDeviationGuard.sol` | 93 | Permissionless 24 h tumbling-window price-drift recorder; emits `CircuitBreakerTripped` events for off-chain monitoring |

### Interfaces (imported by the core contracts above)

| Interface | Path | LoC | Purpose |
|---|---|---|---|
| `IArcoraDexPool` | `contracts/src/interfaces/IArcoraDexPool.sol` | 121 | External ABI, errors, and events for `ArcoraDexPool` |
| `IArcoraDexLP` | `contracts/src/interfaces/IArcoraDexLP.sol` | 17 | External ABI for `ArcoraDexLP` |
| `IArcoraDexRegistry` | `contracts/src/interfaces/IArcoraDexRegistry.sol` | 57 | External ABI and `TokenInfo` struct for `ArcoraDexRegistry` |
| `IChainlinkAggregator` | `contracts/src/interfaces/IChainlinkAggregator.sol` | 11 | Minimal `latestRoundData` / `decimals` interface consumed by registry and oracle layer |

**Total in-scope LoC: 1,230** (core contracts: 1,024; interfaces: 206)

## Out of scope

| Artifact | Reason |
|---|---|
| `contracts/src/testnet/MockChainlinkFeed.sol` | Testnet mock only; never deployed to mainnet |
| `contracts/src/testnet/MockChainlinkFeedV2.sol` | Testnet mock only; never deployed to mainnet |
| `contracts/src/testnet/MintableERC20.sol` | Testnet faucet token; never deployed to mainnet |
| `contracts/script/` (all deploy and ops scripts) | Deployment tooling, not production contract logic |
| OpenZeppelin `TimelockController` | Upstream-audited; consumed as a dependency, not modified |
| OpenZeppelin `Ownable` / `Ownable2Step` | Upstream-audited; used as base classes without modification |
| OpenZeppelin `ERC20` | Upstream-audited; used as base class for `ArcoraDexLP` without modification |
| OpenZeppelin `ReentrancyGuard` | Upstream-audited; used unmodified |
| Safe v1.4.1 contracts (`contracts/lib/safe-contracts/`) | Upstream-audited governance infrastructure |

## Frozen baseline

The audit reviews the commit tagged `audit/spearbit-p4`. Retrieve the exact commit hash with:

```
git rev-parse audit/spearbit-p4
```

The tag is created at merge of `phase4/audit-rollout` into `main`; it is not hardcoded in this document to avoid stale-hash risk.

## Toolchain

| Item | Value |
|---|---|
| Solidity | 0.8.26 |
| Build tool | Foundry (forge) |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| Fuzz runs (CI profile) | 10,000 |
| Invariant runs (CI profile) | 1,024 depth 128 |

Settings source: `contracts/foundry.toml`.

## Build and test

```bash
cd contracts

# Build
forge build

# Run full test suite (128 tests as of audit freeze)
forge test

# Coverage summary (excludes scripts and test helpers)
forge coverage --report summary --no-match-coverage "(script|test)"
```

**Current test results (at time of document authoring):** 128 tests pass, 0 fail, 0 skip across 11 test suites.

**Current coverage (in-scope contracts):**

| Contract | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `src/ArcoraDexLP.sol` | 100.00% | 100.00% | 100.00% | 100.00% |
| `src/ArcoraDexPool.sol` | 93.23% | 87.39% | 55.07% | 96.15% |
| `src/ArcoraDexRegistry.sol` | 100.00% | 91.67% | 57.14% | 100.00% |
| `src/oracle/CumulativeDeviationGuard.sol` | 100.00% | 100.00% | 100.00% | 100.00% |
| `src/oracle/OracleAggregator.sol` | 100.00% | 98.36% | 90.00% | 100.00% |
| **Total** | **95.44%** | **90.43%** | **62.75%** | **97.87%** |

## Repository layout

```
arcora-v0.7-shared-vault-pool/
├── contracts/
│   ├── src/
│   │   ├── ArcoraDexPool.sol
│   │   ├── ArcoraDexLP.sol
│   │   ├── ArcoraDexRegistry.sol
│   │   ├── interfaces/
│   │   │   ├── IArcoraDexPool.sol
│   │   │   ├── IArcoraDexLP.sol
│   │   │   ├── IArcoraDexRegistry.sol
│   │   │   └── IChainlinkAggregator.sol
│   │   ├── oracle/
│   │   │   ├── OracleAggregator.sol
│   │   │   └── CumulativeDeviationGuard.sol
│   │   └── testnet/          ← out of scope
│   ├── test/                 ← out of scope
│   ├── script/               ← out of scope
│   ├── lib/                  ← out of scope (OZ, Safe, forge-std)
│   └── foundry.toml
└── docs/
    ├── audit/                ← this document and companion audit docs
    ├── rollouts/
    └── superpowers/
```
