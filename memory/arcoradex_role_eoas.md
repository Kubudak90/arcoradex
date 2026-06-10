# ArcoraDEX — Role EOAs and Contract Addresses

> **FRESH redeploy 2026-06-10 (Branch C); supersedes 2026-06-06 (keys lost).**

Arc testnet (chainId 5042002). All addresses are testnet-only.

## Protocol EOAs

| Role | Address | Notes |
|---|---|---|
| Deployer EOA | `0xC49303Bda108dE3FFDBDEC069B795b645168D7e6` | Fund source for deploys; no longer direct owner post-handoff |
| Governance Safe (3/5) | `0x396145BAB316d84F958368d93ec8984559f0261B` | Owner of all protocol contracts via Timelock |
| Pause Guardian Safe (2/3) | `0x1098e88b8b243451109D7eA7690f9e2ca7b18280` | Emergency pause/unpause only, bypasses Timelock |
| TimelockController | `0xEb2E77144F5BcB854ED75C687988c4F19100e5D7` | Deployed at delay 0; raising to 48h in Phase 5 |
| Keeper EOA (primary) | `0xed37B7fc534Cc93D4195b4F11ADc5C14237cd287` | Writer for primary (bounded H-2) feeds |
| Keeper EOA (secondary) | `0x14Bd4a84A32823a1ffC36B34eb36c872FEe99523` | Writer for secondary feeds |
| Treasury | `0xC6937816A3115bE3E9e1b1C184775818cCe6CE01` | Protocol fee recipient |
| Faucet | `0xb5f3196D8634D16286C661520CEa3b0b15bC08B6` | Mints testnet stables to claimants |

## Live protocol contracts (V3)

| Contract | Address |
|---|---|
| ArcoraDexRegistry V3 | `0x372f83a1432Aa43b72eDCE083DC8352d9Bfb47f1` |
| ArcoraDexPool V3 | `0x214825E3e24a07cd58e48267e492320dAccCe2f6` |
| ArcoraDexLP V3 | `0xc07e979B5Ee023Ad96E65E733b99902306CAFEf2` |
| CumulativeDeviationGuard | `0x06f4EbCd1780721ab2eCDd776294699d2697761d` |

## Token addresses

| Symbol | Decimals | Address |
|---|---|---|
| USDC  | 6  | `0x200380a191FdB530C73120674EAF00E8417D168B` |
| USDT  | 6  | `0xd93548768635d218478899448729eB9d6fCE9903` |
| PYUSD | 6  | `0xd3fea5191fbD9e5B7492DE0e8289897514421407` |
| DAI   | 18 | `0x89dD7f0D66e35F78794ee0215E380DD3269A2a0B` |
| EURC  | 6  | `0xD4637b44879630dD0fE35FE86CC90EA192aeF008` |
| TRYC  | 6  | `0x0dA050E630A1801421AdEf52351b1a1123b38265` |
| BRLC  | 6  | `0x98422826dD9C22123991713810E1aC0B5d15179d` |

## P3.5 V2 aggregators (Registry usdOracle pointers — owner = Gov Safe)

| Token | V2 Aggregator |
|---|---|
| USDC  | `0x1BD92d2bb0877b3Ba9E39882DC7cB6628aaCe1bD` |
| USDT  | `0x3F90447874F4914eF1E00316b14Cf67443a96074` |
| PYUSD | `0x480f3c42a68074B8A1Ba2670a3d5A3562456A102` |
| DAI   | `0xd94c932ad7c7E579ec33E892A1c753Cd4868FB56` |
| EURC  | `0x7Bf31fDAd7d33A2b3d80f894cfFd4a90E924dD8a` |
| TRYC  | `0x479906AF47Db3D5704c2B2C171Aee5B52a9FD523` |
| BRLC  | `0x58D9118407B96b0b58e3F303949e0dB92F7F66E7` |

## Primary feeds (bounded H-2 — writer = Keeper primary)

| Token | Primary Feed |
|---|---|
| USDC  | `0xa57B5b023335DAeadE30024b11eA9caC2Eb08212` |
| USDT  | `0x9Fb7FF1Fab0f8557a73aaa8299ED3Aa7deA1c611` |
| PYUSD | `0x054818FB22De2Ab111362FE05DeD221d51d7fd43` |
| DAI   | `0xfd7701ed4685a4240294F1010bA62AF3BfD398f2` |
| EURC  | `0xBdFCa92587CDcF4ed150343A30B19F29C80917aD` |
| TRYC  | `0x9B5d25E1e58D32F5B9624943FEeD5D27350BC5ED` |
| BRLC  | `0x3ff4d256b4cC25ab0f0Fff5aB7D3bAf35CA5d329` |

## Secondary feeds (writer = Keeper secondary)

| Token | Secondary Feed |
|---|---|
| USDC  | `0x344634C00573A1678a9B3594c7bC070c608B1708` |
| USDT  | `0x0D2118E485fD4cb7F40a73ECAc2Eae330A97F717` |
| PYUSD | `0x612Dd283afFe8235b70A9Cf3ccEa9f0cE9fa271e` |
| DAI   | `0x67a1744363830B63809BC01FDd7020Ea8eF4bd91` |
| EURC  | `0x56eD0616119924bD69E440123274E9dABA97a80C` |
| TRYC  | `0x1f218DD7DD6858D67912496a49c3F8bc8500Ea0e` |
| BRLC  | `0xCbdD7381766f3021C5fae2a5bBeAe5CF0Fc20bcF` |
