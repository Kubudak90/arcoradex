# Arc V2 Deploy — 2026-06-11 (LIVE)

Second live deployment of the Base-first V2 stack, this time on **Arc testnet (chainId
5042002)**, so the dApp's chain switcher can run V2 on BOTH Arc and Base Sepolia (same UI,
full §9). Deployer `0xC49303Bda108dE3FFDBDEC069B795b645168D7e6`.

## Oracle approach: deployable settable mock adapter

Arc has no Pyth and no real Chainlink. Rather than the dual-source `ChainlinkPythAdapterV2`,
Arc lists tokens against `src/v2/testnet/MockOracleAdapterV2Settable` — a deployable
`IOracleAdapterV2` with `Ownable2Step` admin + a keeper `writer`, settable `(price1e18, safe)`.
Seeded SAFE at peg in-broadcast; the mocks have no intrinsic staleness, so the pool stays
functional without a running keeper (the keeper is for price freshness/parity, and the §11
oracle-failure drill is a deliberate `setSafe(false)`). The Pool/Registry/LP/FeeBandMath are
the SAME audited V2 contracts live on Base — §9 (reserveHealth/quotes/maxSwapOut) is identical.

## Live ledger (chainId 5042002)

| Contract | Address |
|---|---|
| Pool | `0x9191B2c7ac888F2840a99bb1Bf154b8B38716312` |
| Registry | `0x1beBA5b2F374F9e5C8b47439CB743442f1408536` |
| LP | `0x332e977aA9707eC3a0125B22c97Bc0c464658150` |
| Gov Safe (3/5) | `0x535aF4fB7636856f8518375E31077097Eb987BDF` |
| Pause Guardian (2/3) | `0x3e2A7DE087E8B86f073C1E9fA404f058e2621EAB` |
| Timelock | `0xe71AbE95deFAEc16B113b62f1eED95FF5442f7F1` |

Governance owners = public Foundry test mnemonic (`GOV_USE_TEST_MNEMONIC=true`, testnet).
**Governance FINALIZED 2026-06-11** (see below): Pool/Registry `owner = Timelock`, the 3 mock
adapters `owner = Gov Safe`, Timelock locked to 48h. Adapter `writer` = keeper
`0xed37B7fc534Cc93D4195b4F11ADc5C14237cd287` (unchanged — only the Ownable2Step admin moved).

| Token | Token | Mock adapter |
|---|---|---|
| USDC | `0x168655bc42265d8721AD6BCe20435919A0160B79` | `0x0FF2CA8C319C817eE6968BA2a32F0AF1EAa96Fd1` |
| USDT | `0xD05FE3e0A38508b182143E1eBf69C657a87cBe22` | `0x04E44fB0c86735c7D83F8E4F046306101943b7b9` |
| EURC | `0xb1D82C6ba72CfE115Baa0Cd33De78224D9370Eea` | `0x17B6Aa1AabA0514cAe6BFefb90b097B1079A4dB1` |

Fresh `MintableERC20` test stables (6-dec), seeded 5× the $1,000 floor (= target): USDC/USDT
5,000, EURC 4,350 → maxSwapOut > 0 (swap headroom from genesis). **NAV $15,002.50**, paused
false, all adapters safe at peg (verified on-chain 2026-06-11).

## Governance finalized 2026-06-11

Run via `script/ExecuteGovArcV2.s.sol` (deployer broadcast, `--slow`; the test-mnemonic Safe
owners signed off-chain — the EXACT SAME KEYS as Base: deployer EOA + public Foundry test
mnemonic, gov indices 0/1/2, pg indices 5/6, verified on-chain to match the Arc Safes). The
Arc twin of `ExecuteGovBaseSepoliaV2`; only addresses + the `5042002` chainid guard differ.
Sequence (delay-0 window): A) Gov Safe accepted the 3 mock adapters; B) Gov Safe drove the
Timelock (schedule+execute, delay 0) to accept Pool + Registry; C) pause drill — PG Safe paused,
Gov Safe unpaused via Timelock; D) `ARC_LOCK_48H=true` → `Timelock.updateDelay(172800)`.

Verified independently on-chain after broadcast: Pool/Registry `owner == Timelock`
(`pendingOwner == 0x0`), 3 adapters `owner == Gov Safe`, `getMinDelay() == 172800`, pool
unpaused. Future gov ops now incur the 48h delay; emergency pause stays immediate via the PG
Safe. No address needed gas (deployer paid all); Arc gov keys are the public test mnemonic
(nothing secret to delete).

## Outstanding / next

- Optional Arc V2 keeper (`ops/arckeeper/`) to refresh prices — NOT required for the pool to work
  (the mock adapters don't go stale).
- **DONE: SDK multi-chain + app chain switcher** — the 5042002 V2 ledger is in the SDK's
  `DEFAULT_ADDRESSES_V2`, both chains are wagmi-wired, and the header Arc↔Base switcher is LIVE on
  `swap.arcorapay.xyz` (footer + faucet are chain-aware too; verified on both pools 2026-06-11).
