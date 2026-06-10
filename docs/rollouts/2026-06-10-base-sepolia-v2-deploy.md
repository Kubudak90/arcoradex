# Base Sepolia V2 Deploy — 2026-06-10 (LIVE)

First live deployment of the Base-first V2 stack, on **Base Sepolia (chainId 84532)**.
Deployer `0xC49303Bda108dE3FFDBDEC069B795b645168D7e6` (the Arc fresh-redeploy deployer;
EOA, same address cross-chain), funded by bridging 1.9 ETH from Ethereum Sepolia L1 via
the Base L1StandardBridge `0xfd0Bf71F60660E2f608ed56e1659C450eB113120`.

## Deploy-time finding (fixed): Pyth receiver

The oracle-adapters research targeted the **upgraded** Pyth Core (`0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83`,
the 2026-07-31 address). On 2026-06-10 that contract has code but is **not yet VAA-live**:
`getUpdateFee()` returns 0 and `updatePriceFeeds()` reverts `InvalidWormholeVaa()`. Verified
the **current** receiver `0xA2aa501b19aff244D90cc15a4Cf739D2725B5729` returns a real fee (30
wei) and accepts Hermes blobs. Fix: `DeployBaseSepoliaV2.s.sol` now resolves the Pyth address
from env `PYTH_SEPOLIA` (default = upgraded, for post-upgrade deploys); this deploy used
`PYTH_SEPOLIA=0xA2aa501b…` (commit on `feat/base-v2-sepolia-deploy`). The first broadcast
(upgraded Pyth, adapters permanently unsafe) is **abandoned** — addresses below are the
second, working deploy.

## Live ledger (chainId 84532)

| Contract | Address |
|---|---|
| Pool | `0x63FD6180dC6Aa5aE2941Bd28D2dc34c54F2b7820` |
| Registry | `0xae1f10b007cDC4131797A45232a3D52Ff2C314e2` |
| LP | `0x02aFC4c2c72ecE2049725DA2bd9080EF6285c844` |
| Gov Safe (3/5) | `0x262d4069348093D1Fe8860EEB7483ce1FEd068d2` |
| Pause Guardian (2/3) | `0x1516Bc7e614ba71AE95dD226df7F783FeD32c01c` |
| Timelock | `0x62Bf16e9921A1b9C2d8ec58e84b155AE9c9FbaD6` |

Governance owners = the public Foundry test mnemonic (testnet opt-in `GOV_USE_TEST_MNEMONIC=true`;
the factory's mainnet guard + the script's 84532 chainid guard both intact). Pool/Registry
`pendingOwner = Timelock`, adapters `pendingOwner = Gov Safe` (Ownable2Step, not yet accepted —
deployer still owns until the Gov Safe accepts; fine for a testnet validation run).

| Token | Token | Adapter | Chainlink leg |
|---|---|---|---|
| USDC | `0x3a98d8adC295d90171e9DA93D411dEa95674c867` | `0x7C5eAf40638Bb99595F1cD7d08d4C72e3833577e` | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` (real Sepolia CL) |
| USDT | `0x7110315D229C7CE655399703ACbA8E67f1d5C0c0` | `0x4D350eA1BfEb3ccE076d4bd3ade26FFcedb1C4C9` | `0x3ec8593F930EA45ea58c968260e6e9FF53FC934f` (real Sepolia CL) |
| EURC | `0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7` | `0xf141246C632d19157C1222591CFab64e3025C108` | `0x74441A33809Fe14A16FfF3d0bB2E701F426Dba58` (mock $1.15, deployer-owned for drills) |

All three adapters use Pyth `0xA2aa501b…` + the verified feed IDs (USDC `0xeaa0…`, USDT `0x2b89…`,
EURC `0x76fa…`).

## Verified live (2026-06-10)

- Keeper `ops/basekeeper/update-pyth-base-sepolia.mjs` pulled Hermes → `updatePyth` 3/3 (fee 30 each)
  → all adapters `peekPrice.safe == true` (USDC $0.9997, USDT $0.9992, EURC $1.1529).
- Bootstrap seeded: USDC 5000, USDT 5000, EURC 4350 → **NAV $15,009**.
- **Live oracle-priced swap:** 100 USDC → 86.67 EURC (Pyth/CL price $1.153/EUR, 0.05% fee); reserves
  moved USDC 5000→5100, EURC 4350→4263.3. Deposit + swap + keeper all confirmed on-chain.

## Notes / outstanding

- Public RPC `sepolia.base.org` showed heavy read-after-write lag during ops — use
  `base-sepolia-rpc.publicnode.com` for reliable reads/verification.
- **Governance finalized 2026-06-10** via `script/ExecuteGovBaseSepoliaV2.s.sol` (deployer broadcast;
  test-mnemonic owners signed off-chain): 3 adapters → Gov Safe, Pool/Registry → Timelock, pause
  drill passed, Timelock locked to 48h. No address needed gas (deployer paid all); Base Sepolia gov
  keys are the public test mnemonic (nothing secret to delete). EURC mock CL leg stays deployer-owned
  for drills. Future gov ops incur the 48h delay; emergency pause stays immediate via PG Safe.
- The live §13 drill scripts (`ops/basekeeper/drills/`) remain an optional operational follow-up; all
  drill BEHAVIORS are already proven in the CI revalidation suite
  (`test/DeployBaseSepoliaV2.t.sol`, 11 tests incl. confidence/stale/floor/divergence/proportional/pause).
- For a post-2026-07-31 or mainnet deploy, drop the `PYTH_SEPOLIA` override (default upgraded address
  becomes correct) and re-verify `getUpdateFee > 0` against the chosen receiver first.
