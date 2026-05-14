# Phase 1 — Testnet Redeploy

**Date:** 2026-05-14
**Branch:** `phase1/testnet-redeploy` (merged to main as PR #N)
**Spec:** `docs/superpowers/specs/2026-05-14-phase1-contract-fixes-design.md`
**Roadmap parent:** `docs/superpowers/specs/2026-05-13-mainnet-readiness-roadmap.md` §3

## Why redeploy

P1 (PR #6, merged 2026-05-14) extended storage on both `ArcoraDexRegistry` (added `maxStaleSeconds` to `TokenInfo`) and `ArcoraDexPool` (added `lastValidPrice`, `lastValidPriceAt`, `lastMintAt` mappings). The contracts are not proxy-upgradable, so the new storage layout ships as a fresh deploy. The old testnet pool is paused and abandoned; the mock ~$70k of NAV in it has no economic value.

## Old (frozen) addresses

| Contract           | Address                                       | State          |
|--------------------|-----------------------------------------------|----------------|
| ArcoraDexRegistry  | `0x920E3E59DD37Be3D9D3750D7B912A9dd08db0D29`  | abandoned (no on-chain pause; replaced by new Registry below) |
| ArcoraDexPool      | `0x3051d24D771bAF44031571544a9159578035D0c5`  | **paused** (tx `0xaab7ac647f1b4c0af027aa2bdd770d3add117b520a810ec67863bf2e4b35ac8b`) |
| ArcoraDexLP        | `0x7CEAbF411806A29ffaEbCAB2BF3Dc8a9ECBD110C`  | orphaned (still mintable by old pool, but old pool is paused) |

## New addresses (Arc testnet, chainId 5042002)

| Contract           | Address                                       |
|--------------------|-----------------------------------------------|
| ArcoraDexRegistry  | `0x8748fc38718dd2985e2680e7fc122c7946fb2ad0`  |
| ArcoraDexPool      | `0xb01a7a4da9986e9eb197d98242cf74d15f1f648b`  |
| ArcoraDexLP        | `0xfD431f8101405DD3781F92056347bd4D323c97c7`  |

Pool parameters at deploy:

| Param                     | Value                          |
|---------------------------|--------------------------------|
| swapFeeBps                | 5 (0.05%)                      |
| protocolFeeShareBps       | 2500 (25% of swap fee)         |
| MIN_HOLD_SECONDS          | 3600 (1 hour, immutable)       |
| MINIMUM_LIQUIDITY         | 1000 (DEAD-locked)             |
| VIRTUAL_SHARES            | 1e6 (immutable)                |
| VIRTUAL_ASSETS            | 1 (immutable)                  |
| Owner                     | `0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b` (deployer EOA; transfers to multisig in P2) |

Note: live pool's old `protocolFeeShareBps` was higher (likely 6000+ per inferred swap math). The new `MAX_PROTOCOL_FEE_SHARE_BPS = 2500` constant in the P1 contract enforces a tighter cap. Resulting LP-vs-protocol fee split: 75% LP / 25% protocol on every swap.

## Token listings (new pool)

Reuses existing testnet `MintableERC20` tokens and `MockChainlinkFeedV2` feeds from the 2026-05-10 key-separation cutover.

| Symbol | Token                                         | Feed                                          | DevBps | maxStaleSeconds |
|--------|-----------------------------------------------|-----------------------------------------------|--------|-----------------|
| USDC   | `0x3BFa09fF6467639f0981948385bA1018Ac07d22C`  | `0x2E6B862E1Ac74328238494B22317262004534B39`  | 50     | 3600 (1h)       |
| USDT   | `0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B`  | `0x741af784a1d4C69843A1764099433160088a1c70`  | 50     | 3600 (1h)       |
| PYUSD  | `0xfdB2c86d010698401f0b969348DC58b6659B96a3`  | `0x2285FeDA1F9c07959db2b97bFC8F9cCBCDb51896`  | 50     | 3600 (1h)       |
| DAI    | `0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE`  | `0xAAC5a5855deF9414f7330f350c2E00119C2097c8`  | 50     | 3600 (1h)       |
| EURC   | `0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD`  | `0x0656C1DeBCa98fAE7447ad8b0DF38C444833A170`  | 150    | 14400 (4h)      |
| TRYC   | `0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61`  | `0xB49BF86c11b5A949dd91819bB1BA1399b6bbDf9C`  | 5000   | 86400 (24h)     |
| BRLC   | `0xa13c0935A98e2c175b31A4054f698819271a8FfC`  | `0x8Ee5C63efea3Ac2807a45A00D45507f3514B612d`  | 5000   | 86400 (24h)     |

**P3 to tighten TRYC/BRLC `maxOracleDeviationBps`** based on Chainlink heartbeat survey + multi-source aggregator. The 5000-bps cap is a known residual risk (cache walk-up via writer-key compromise, ~2.25× per pair of fresh oracle updates).

## Founding liquidity bootstrap

Each of the 7 stables seeded with ~$100 USD-equivalent from the deployer's existing testnet balances:

| Symbol | Amount (native units)        | USD value (approx) |
|--------|------------------------------|--------------------|
| USDC   | 100_000_000 (6d)             | $100.00            |
| USDT   | 100_000_000 (6d)             | ~$99.96            |
| PYUSD  | 100_000_000 (6d)             | ~$99.98            |
| DAI    | 100 × 10^18 (18d)            | ~$99.97            |
| EURC   | 86_000_000 (6d)              | ~$99.90            |
| TRYC   | 4_390_000_000 (6d)           | ~$100.00           |
| BRLC   | 516_000_000 (6d)             | ~$100.00           |

**Total initial NAV:** $699.80 (`totalReservesUSD()` returned `699799512000000000000`).
**Initial LP supply:** `699799512000000000000006993` (≈ 7 × 1e26 LP units due to virtual-shares math).

## Deploy & bootstrap transactions

| Action                  | Tx hash                                                              |
|-------------------------|----------------------------------------------------------------------|
| Full deploy run         | See `contracts/broadcast/DeployArcoraDexV2.s.sol/5042002/run-latest.json` for the 22 individual tx hashes (1 Registry + 1 Pool + 7 listToken + 7 approve + 7 deposit) |
| Pause old pool          | `0xaab7ac647f1b4c0af027aa2bdd770d3add117b520a810ec67863bf2e4b35ac8b`  |

## Downstream tasks (operator-driven, NOT in this PR)

- [ ] Update SDK to point at new Pool / Registry / LP addresses
- [ ] Update Vercel app env (`NEXT_PUBLIC_POOL_ADDR`, `NEXT_PUBLIC_REGISTRY_ADDR`, etc.)
- [ ] Update keeper VPS `.env` if any addresses changed (feeds reused so likely no change; verify via `ssh root@194.163.136.1 'grep ^FEED_ /home/arcora/arcoradex-feeds/.env'`)
- [ ] Update auto-memory `arcoradex_role_eoas.md` with new Pool/Registry/LP addresses
- [ ] Announce in #ops (or wherever the team coordinates)
- [ ] Track the residual risks in P3 brainstorming: TRYC/BRLC deviation cap tightening + cache-deviation guard refinement

## Rollback

The old pool was paused but not destroyed. To revert:
1. Unpause the old pool: `cast send 0x3051d24D771bAF44031571544a9159578035D0c5 'unpause()' --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url <RPC>`
2. Update SDK/app/keeper addresses back to the old contracts.
3. The new pool can be left running in parallel (no harm) or also paused for cleanliness.

No data migration was performed; rollback is purely a pointer swap.

## Phase 1 status

✅ Contract fixes (PR #6): merged
✅ Testnet redeploy (this rollout): live
⏭ Next: P2 governance migration (Safe multisig + OZ TimelockController + Pause Guardian)
