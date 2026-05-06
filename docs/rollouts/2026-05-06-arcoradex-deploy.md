# ArcoraDEX testnet deploy — 2026-05-06

**Network:** Arc testnet (chainId `5042002`)
**RPC:** `https://rpc.testnet.arc.network`
**Explorer:** `https://testnet.arcscan.app`
**Native gas token:** USDC
**Deployer / Owner:** `0xe8E5AAa3d8c705A07de02aADF98CE31F20A5754b`
**Tag:** `v1.0-testnet`

## Protocol contracts

All three verified to hold non-empty bytecode via `cast code` immediately after broadcast.

| Contract             | Address                                      | Bytecode size |
|----------------------|----------------------------------------------|--------------:|
| `ArcoraDexRegistry`  | `0x920E3E59DD37Be3D9D3750D7B912A9dd08db0D29` | 6,076 hex |
| `ArcoraDexPool`      | `0x3051d24D771bAF44031571544a9159578035D0c5` | 18,806 hex |
| `ArcoraDexLP`        | `0x7CEAbF411806A29ffaEbCAB2BF3Dc8a9ECBD110C` | 4,350 hex |

Pool initial swap fee: **30 bps** · protocol fee share: **1000 bps (10 %)** · protocol-share cap: **2500 bps (25 %)**.

## Token + feed addresses (7 active stables)

| Symbol | Decimals | Token                                        | USD/Token feed                               | Initial price | DevBps |
|--------|---------:|----------------------------------------------|----------------------------------------------|---------------|-------:|
| USDC   | 6        | `0x3BFa09fF6467639f0981948385bA1018Ac07d22C` | `0xf150dfF405BFd58130287E60C70cBcc98b2f697d` | 1.0000        | 50     |
| USDT   | 6        | `0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B` | `0xEa12E9fFA2E3a965213C8A73c987bD6deA85A317` | 1.0000        | 50     |
| PYUSD  | 6        | `0xfdB2c86d010698401f0b969348DC58b6659B96a3` | `0xC740f1B1e165E027951c42345a443B5bCfF2c017` | 1.0000        | 50     |
| DAI    | 18       | `0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE` | `0x34aF55cB5F4d8C306600Bf78E247a362d393A486` | 1.0000        | 50     |
| EURC   | 6        | `0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD` | `0x0B6e17944819ab5D4DC58CbFb2786E9b3a2e54F6` | 1.0800        | 150    |
| TRYC   | 6        | `0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61` | `0x8c29A88e1dC4C50a62261c975932D4Ce64D8266c` | 0.0290        | 5000   |
| BRLC   | 6        | `0xa13c0935A98e2c175b31A4054f698819271a8FfC` | `0x657e7994257A6cdc0E171A2288f347403Bb1894b` | 0.2000        | 5000   |

`DevBps` is the per-token PriceGuard deviation cap. TRYC/BRLC are kept permissive (5000 bps) on testnet because mock-feed initial prices intentionally drift from the live FX, and tightening would block routine keeper updates. EURC has 150 bps to accommodate normal EUR/USD movement.

## Deploy seeding

Deployer pre-seeded **$10,000 USD-equivalent of every active stable** via `pool.deposit(...)` immediately after each token was listed.

- Final LP supply: `69_999_999_999_694_000_000_000` (= 70,000 ADEX-LP minus 1,000 wei `MINIMUM_LIQUIDITY` burnt to `0xdead`)
- Final NAV: `69_999_999_999_694_000_000_000` (= 1 ADEX-LP ≈ $1.00 at parity)

## Smoke flows (7-flow round trip)

All flows broadcast against the live deploy by the same key, recorded in `contracts/broadcast/SmokeArcoraDex.s.sol/5042002/run-latest.json`.

| # | Flow                              | Result                              | tx hash |
|---|-----------------------------------|-------------------------------------|---------|
| 1 | Deposit 1,000 USDC                | NAV → $71,000                       | `0x9e8f11ccc75766109851a8dd6f27c1f440c05ed142235376bed9fdddb258815d` |
| 2 | Deposit 1,000 EURC                | NAV → $72,080                       | `0x5a6fbedee53c3ff6aed20c4f5650ebc0dcf1499c9f4163b60502845813c58b81` |
| 3 | Swap 100 USDC → EURC              | 92.314815 EURC                      | `0xed72a109c4757ba4748bc3228dd4a7f912cf8ec00b00cf451d17b2282e5efbf8` |
| 4 | Swap 100 EURC → TRYC (cross-FX)   | 3,712.965518 TRYC                   | `0x057b3013fe9eea444015d6a460d4b527fc5644d50e58351d909315b83976d468` |
| 5 | Swap 100 PYUSD → DAI (6 ↔ 18 dec) | 99.700000000000000000 DAI           | `0x6bc46b5b3aeb3c8589150196bffd5833beae8b12d58dc5ed37af6db05e10e4c8` |
| 6 | Withdraw 500 LP → USDC            | 498.505751 USDC                     | `0x14d64b7085c4061c2f834696e6484c1ce1b36a182b05be1457a29db358095da8` |
| 7 | Withdraw 500 LP → BRLC            | 2,492.575765 BRLC                   | `0xe4798a0ace119dc5ee9919a60eae465c74521ea84af3cd5f47c4b8a22fe73aed` |

Math sanity:
- Flow 3: 100 USDC → 100 / 1.08 EURC = 92.5926, after 30 bps fee = 92.315 ✓
- Flow 5: 100 PYUSD * 1.0000 USD = 100 USD, after 30 bps fee = 99.700 DAI ✓
- Flow 6: 500 LP * (NAV / supply) ≈ $500.00, after 30 bps fee = 498.50 USDC ✓
- Flow 7: 500 LP ≈ $500.00, after 30 bps fee = $498.50, ÷ 0.20 = 2492.50 BRLC ✓

## Post-deploy state (read-only sanity)

Run after smoke completed:

```
pool.swapFeeBps()           = 30
pool.protocolFeeShareBps()  = 1000
pool.MAX_PROTOCOL_FEE_SHARE_BPS = 2500
pool.LP() = 0x7CEAbF411806A29ffaEbCAB2BF3Dc8a9ECBD110C
pool.REGISTRY() = 0x920E3E59DD37Be3D9D3750D7B912A9dd08db0D29
LP.MINTER() = 0x3051d24D771bAF44031571544a9159578035D0c5
LP.balanceOf(0xdead) = 1000           # MINIMUM_LIQUIDITY anti-inflation burn
```

## Smoke script bug fix (during this rollout)

First broadcast of `SmokeArcoraDex.s.sol` reverted at flow 3 (`ERC20InsufficientBalance` on USDC) because the upfront mint loop only minted 1,000 of each token while flow 1 deposited 1,000 USDC, leaving 0 for the subsequent swap. Patched in commit during this rollout to mint 2,000 of each token (deposit headroom + swap headroom). Re-broadcast was fully successful.

## Keeper

VPS keeper (`194.163.136.1`) systemd unit renamed:
- Old: `arcora-v07-feeds.timer` / `arcora-v07-feeds.service` — disabled
- New: `arcoradex-feeds.timer` / `arcoradex-feeds.service` — active
- Working dir: `/root/arcoradex-feeds/`
- Feed config (`feeds.json`) updated with the 7 new mock feed addresses listed above

Logs: `journalctl -u arcoradex-feeds.service`

## v0.7 → v1.0 cutover

The previous `Kubudak90/arcoradex` deploy (when the repo was still `arcora-v0.7-shared-vault-pool`) is now strictly historical. The frozen branch `legacy/v0.7-arc-fx-gateway` preserves the source. Old contract addresses:

| Component (v0.7) | Address | Status |
|---|---|---|
| `StablecoinRegistry` | `0x967F498cf759F2CA8a43394a21f6b317A2c0d56c` | Abandoned (still on chain) |
| `StablePool`         | `0xB8941ED1057F7e881dC4534d2435CBF5d395Ffb6` | Abandoned (still on chain) |
| `ArcFXGateway`       | `0x3201B0EE7E39542a2D6Fa958f5502F210532De53` | Abandoned (still on chain) |

Old keeper systemd timer was disabled (`arcora-v07-feeds.timer`). Old contracts still hold owner-funded reserves; they are not actively pushed prices to anymore so swap quotes will revert on staleness ≥ 1 hour. No action required — the addresses simply rot.

## Cost

Deployer balance:
- Pre-deploy: 20.000754 USDC
- Post-deploy: 19.752956 USDC (deploy cost ≈ 0.247 USDC)
- Post-smoke: see `cast balance` (smoke + deploy combined ≈ 0.3 USDC range)

The full 16-contract deploy + 7-flow smoke cost well under 1 USDC on Arc testnet.
