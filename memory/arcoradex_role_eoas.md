# ArcoraDEX — Role EOAs and Contract Addresses

Arc testnet (chainId 5042002). All addresses are testnet-only.

## Protocol EOAs

| Role | Address | Notes |
|---|---|---|
| Deployer EOA | `0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b` | Fund source for deploys; no longer direct owner post-P2 |
| Governance Safe (3/5) | `0x715f669D79Cc72d6685F8724c0B86f7B53d7e624` | Owner of all protocol contracts via Timelock |
| Pause Guardian Safe (2/3) | `0x39500e45935f36CfcEb826590aaE97226Ac6640D` | Emergency pause/unpause only, bypasses Timelock |
| TimelockController (48 h) | `0x36444f653E7746d69aD5d91dA920f5Cd2F9C6E83` | All governance actions gated here |
| Safe singleton (v1.4.1) | `0x93e259adbee7b1bf16619b39905f1154d4025f10` | |
| SafeProxyFactory | `0x5f1ad56dc1d90688113baf80fc3572cd441f3cc3` | |

## Test signers (testnet only — Foundry mnemonic `test test … junk`)

| Role | HD Index | Address |
|---|---|---|
| gov1 | 0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` |
| gov2 | 1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` |
| gov3 | 2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` |
| gov4 | 3 | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` |
| gov5 | 4 | `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65` |
| pg1  | 5 | `0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc` |
| pg2  | 6 | `0x976EA74026E726554dB657fA54763abd0C3a0aa9` |
| pg3  | 7 | `0x14dC79964da2C08b23698B3D3cc7Ca32193d9955` |

## Live protocol contracts (V3)

| Contract | Address |
|---|---|
| ArcoraDexRegistry V3 | `0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB` |
| ArcoraDexPool V3 | `0x1ce1ef94e7ebe70727bd69003d61a3f0c9a331bc` |
| ArcoraDexLP V3 | `0x17B47173C457069E53B3B75Ef42773041B79523e` |

## Token addresses

| Symbol | Decimals | Address |
|---|---|---|
| USDC  | 6  | `0x3BFa09fF6467639f0981948385bA1018Ac07d22C` |
| USDT  | 6  | `0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B` |
| PYUSD | 6  | `0xfdB2c86d010698401f0b969348DC58b6659B96a3` |
| DAI   | 18 | `0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE` |
| EURC  | 6  | `0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD` |
| TRYC  | 6  | `0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61` |
| BRLC  | 6  | `0xa13c0935A98e2c175b31A4054f698819271a8FfC` |

## OracleAggregator addresses

> **V1 aggregators (P3, 2026-05-17) are superseded as of 2026-05-22.** Registry pointers updated to V2 via Timelock batch `0xe2e130fb…58354c` (tx `0x6b65230972baab17f256b9fd62643d7af370617ec8b6077fa30d7e852045d314`, block 43528310). V1 addresses retained below for historical reference only.

### V2 Aggregators (P3.5, 2026-05-20 deploy / 2026-05-22 activated — CURRENT)

| Token | V2 Aggregator |
|---|---|
| USDC  | `0x2a326377726748Be85d951A8356a944D9c76b7b8` |
| USDT  | `0x797e4a1611F544B321802D38d234D36DDE3Bd900` |
| PYUSD | `0x4C101C0d607409ddC2D1045548582b522b285033` |
| DAI   | `0x98ed4909168051BFb39ff527ad0a8F1F381c21a8` |
| EURC  | `0x862E1CBD0f767da4aa87527a29240AfD06Cda261` |
| TRYC  | `0x41255684f22D1bD80455B4c73814e5743f0cf7c8` |
| BRLC  | `0x7b887B5D570221a7b276B301Ca6c74AFf9fA9169` |

V2 changes vs V1: per-source staleness check (`MAX_STALE_SECONDS = 3600` immutable), `roundId = 0` degraded-mode signal (closes audit C-1/C-2/C-5), monotonic `roundId = max(pR, sR)` when both sources healthy.

### V1 Aggregators (P3, 2026-05-17 — SUPERSEDED)

| Token | V1 Aggregator |
|---|---|
| USDC  | `0x6c6519cB0C66c2269505833382f23D4e8f915480` |
| USDT  | `0x3e58dd7fD2729A27961Ffb11d37BFf42874cAa34` |
| PYUSD | `0x78cB5F03b420F0CD2E8adcb141069F31a38E07E8` |
| DAI   | `0x3e542b4d2EdBFC965028eB85140BcFEa6868A37E` |
| EURC  | `0x1357cf421A8c3b732A882e4812AFba6209EBEBbc` |
| TRYC  | `0xFE3FE7F2b2693D676E4831283dd1B81665AC9faA` |
| BRLC  | `0xF5021349E0D6e2ACB00bEb105D7793202ac3Aa46` |

## Primary feeds (unchanged across P3/P3.5)

| Token | Primary Feed |
|---|---|
| USDC  | `0x2E6B862E1Ac74328238494B22317262004534B39` |
| USDT  | `0x741af784a1d4C69843A1764099433160088a1c70` |
| PYUSD | `0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896` |
| DAI   | `0xAAC5a5855deF9414f7330f350c2E00119C2097c8` |
| EURC  | `0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170` |
| TRYC  | `0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C` |
| BRLC  | `0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d` |

## Secondary feeds (unchanged across P3/P3.5)

| Token | Secondary Feed |
|---|---|
| USDC  | `0x88D1D41d902eb9e589Bd9840c688F93b833E5Bcf` |
| USDT  | `0x380DF13433f0908d7Fff9c0f5A9e7d7020148325` |
| PYUSD | `0xac5C2Ad4Cf30c39b60C6DFD29bEAc79deE583B83` |
| DAI   | `0x63D06bdD48afa8d3e4166CdBf8102562b17Cb4B1` |
| EURC  | `0x7e29777A4632714C8C08a49b159E706bDBC414E5` |
| TRYC  | `0x30669c5C1baC6c7CEfDd7E842D621075d3454da9` |
| BRLC  | `0x00058b5F7d6f29bC37092F156afe7f2EBE7D3EA6` |

## Other contracts

| Contract | Address | Notes |
|---|---|---|
| CumulativeDeviationGuard | `0x035447f8d97A23fFfC32aa8bFb8ffDbC7B94E608` | Event-only in P3; auto-pause deferred to P5 |
