# Oracle Availability Verification — Base-first V2 (USDC / EURC / USDT)

Verified 2026-06-10 against Chainlink's reference-data directory (docs.chain.link backend),
live on-chain reads via Base public RPCs, Pyth's official docs, and the Hermes Stable API.
Every address was confirmed on-chain (`description()` / `decimals()` / `latestRoundData()` or
`eth_getCode`). Input to the (future) oracle-adapter + Base deploy plans; design ref:
`docs/superpowers/specs/2026-06-08-base-first-v2-design.md` §10/§15.

## Verdict

**The V2 launch set CAN be USDC + EURC + USDT as designed.** On Base mainnet every token has
two independent, DIRECT token/USD sources. EURC does NOT need the TRYC/BRLC deferral: direct
Chainlink EURC/USD and direct Pyth Crypto.EURC/USD both exist and answer live.

| Token | Base mainnet (8453) | Base Sepolia (84532) |
|---|---|---|
| USDC | ✅ Chainlink + ✅ Pyth → **PASS** | ✅ Chainlink (stale-prone) + ✅ Pyth → PASS w/ caveat |
| EURC | ✅ Chainlink (direct) + ✅ Pyth (direct) → **PASS** | ❌ Chainlink (none) + ✅ Pyth → FAIL dual-source (testnet mock needed) |
| USDT | ✅ Chainlink + ✅ Pyth → **PASS** | ✅ Chainlink + ✅ Pyth → PASS |

## 1. Chainlink — Base mainnet (8453)

| Feed | Proxy | Dec | Heartbeat | Deviation | Live check 2026-06-10 |
|---|---|---|---|---|---|
| USDC/USD | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | 8 | 86400 s | 0.3% | 0.99976703 ✓ |
| USDT/USD | `0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9` | 8 | 86400 s | 0.3% | 0.99936 ✓ |
| **EURC/USD** | `0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250` | 8 | 86400 s | 0.3% | 1.1561394 ✓ |
| EUR/USD (FX — reference only, does NOT qualify) | `0xc91D87E81faB8f93699ECf7Ee9B44D11e1D53F0F` | 8 | 3600 s | 0.1% | 1.15507 ✓ |

All `feedCategory: low`. SVR variants exist (`*-svr` proxies) for liquidation-MEV integrations —
use the standard proxies above, not SVR.

Sources: docs.chain.link addresses page (Base), machine-verified via
`https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json` (166 feeds);
on-chain via `https://mainnet.base.org`.

## 2. Chainlink — Base Sepolia (84532)

Only 9 feeds exist in total. Relevant:

| Feed | Proxy | Dec | Heartbeat | Live check |
|---|---|---|---|---|
| USDC/USD | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` | 8 | 86400 s | **~8 days stale at check time** |
| USDT/USD | `0x3ec8593F930EA45ea58c968260e6e9FF53FC934f` | 8 | 86400 s | fresh ✓ |
| EURC/USD | **does not exist** (EUR/USD also absent) | — | — | — |

Source: `https://reference-data-directory.vercel.app/feeds-ethereum-testnet-sepolia-base-1.json`.

## 3. Pyth on Base

Contracts (source: docs.pyth.network contract-addresses/evm; code confirmed on-chain):

| Network | Current | Upgraded (Pyth Core, 2026-07-31) |
|---|---|---|
| Base mainnet | `0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a` | `0xbC16aee60f64864882BC6C4E428e148Fc0E272F5` |
| Base Sepolia | `0xA2aa501b19aff244D90cc15a4Cf739D2725B5729` | `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83` |

> Pyth Core upgrades on EVM on 2026-07-31; new integrations should target the UPGRADED
> contracts and budget for the new API-key requirement (docs.pyth.network …/upgrade).

Price-feed IDs (Hermes Stable catalog; identical on mainnet + Sepolia):

| Feed | ID | Live (2026-06-10) |
|---|---|---|
| Crypto.USDC/USD | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` | 0.999739 ±0.000711 ✓ |
| Crypto.USDT/USD | `0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b` | 0.999199 ±0.000611 ✓ |
| **Crypto.EURC/USD** | `0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c` | 1.155001 ±0.001545 ✓ |
| FX.EUR/USD (ref only) | `0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b` | 1.15514 ✓ |

⚠ `Crypto.EURCV/USD` (`0x61162fa2…`) is Société Générale's EUR CoinVertible — NOT Circle EURC.
Pin the exact EURC ID above.

## 4. Caveats to carry into the adapter/deploy plans

1. Base Sepolia has no Chainlink EURC/USD → testnet EURC needs a mock/stub Chainlink leg
   (test-environment workaround, not a production blocker).
2. Base Sepolia Chainlink USDC/USD observed ~8 days stale → testnet staleness config must be
   lenient or mocked.
3. Mainnet stable feeds run 24 h heartbeat / 0.3% deviation → the adapter's Chainlink
   staleness window must accept up to ~86400 s.
4. Integrate Pyth against the UPGRADED Core contracts; plan for the post-2026-07-31 API key.
