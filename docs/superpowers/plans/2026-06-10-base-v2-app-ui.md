# Base V2 App UI (Plan 4b — ArcoraDEX V2 App UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. FRONTEND NOTE: TDD is weaker for UI — each task shows real TSX + the exact design tokens/classes from the prototype, and VERIFICATION is build + render (`pnpm --filter arcoradex-app build` passing) plus a Playwright/manual render check. Keep unit tests light but real where logic fits (the Max-guard, the health-band mapping, the oracle-unsafe routing).

**Goal:** Port the polished UI prototype at `arcoradex-ui/` (the user's authoritative design reference — dark ServiceNow theme, chartreuse/lime accent `#C8F24A`, glassy cards, Hanken Grotesk + IBM Plex Mono, 4-column footer) into the real Next.js app (`app/`, package `arcoradex-app`, currently the Arc V1 blue UI), wired to the **V2 SDK** via `@arcoralabs/dex-sdk/v2` + `@arcoralabs/dex-sdk/react/v2` against the live Base Sepolia V2 ledger (Pool `0x63FD…7820`, Registry `0xae1f…14e2`, chainId 84532, tokens USDC/USDT/EURC), and ADD the spec §9 V2 features on every page: a **reserve-health indicator** (bar/label per output token via `healthBand`/`healthLabel`), an **estimated dynamic fee** (marginal, from the quote's `feeUsd1e18` via `estimatedFeePct`), a **`Max` action** that selects ONLY the floor-safe maximum (`useMaxSwapOut`/`useMaxWithdraw` + `applyMaxGuard`) with an **over-max WARNING** that never submits, **quote refresh immediately before submit**, **single-token AND proportional-emergency withdraw** with an **oracle-unsafe (`OracleUnsafeError`) → proportional-exit fallback**, across **Swap + Liquidity + Pool** as NEW prototype-based components (the existing Arc-blue pages/components are replaced as the universal shell, not branched per chain). The new UI is the universal shell pointed at Base Sepolia 84532; the contract stays the final enforcement layer (UI guards are advisory).

**Architecture:** The prototype is a single-file React-via-CDN app (`app.jsx`/`swap.jsx`/`liquidity.jsx`/`pool.jsx`/`ui.jsx`/`data.jsx`) using inline-style design tokens and `window.ArcoraData` mock data. We port its DESIGN — not its code — into the app-router structure: the ServiceNow token set from `_ds/.../colors_and_type.css` (the `--sn-*`, `--chartreuse-*`, `--green-*`, semantic `--surface/--fg/--accent/--action/--border/--elev/--glass` tokens, `.overline`/`.h*` type roles, the Hanken Grotesk + IBM Plex Mono `@import`) replaces the Arc-blue tokens in `globals.css`, and the prototype's primitives (`Icon`, `Wordmark`, `CoinBadge`, `Card`, `Button`, `Pill`, `Overline`, `TokenSelectModal`, `AreaChart`, `Sparkline`, `AnimatedNumber`) become real TSX components under `components/ds/`. The shell (`layout.tsx` + new `Header`/`Footer`/`Background`/`Toasts`) reproduces the sticky glassy nav (Wordmark, Swap/Liquidity/Pool tabs, Add-network chip, Faucet, theme toggle, lime Connect-wallet button) and the 4-column footer. Each page is a new prototype-shaped component fed by the V2 hooks instead of mock data: `useArcoraDexV2` (via a new `ArcoraDexV2Provider` in `Providers`), `sdk.getTokens()` for the active token universe, `useQuoteSwapV2`/`useQuoteWithdrawV2` (four-return `{amountOut, protocolFee, feeUsd1e18, postHealthBps}`), `useReserveHealth`, `useMaxSwapOut`/`useMaxWithdraw`, and the `useSwapV2`/`useDepositV2`/`useWithdrawSingleV2`/`useWithdrawProportionalV2` mutations. The §9 surface slots in as three reusable pieces consumed by all flows: a `<ReserveHealthBar>` (bps → band/label/color), a `<DynamicFeeRow>` (`estimatedFeePct(feeUsd1e18, grossUsd1e18)`), and a `useMaxGuard` hook wrapping `applyMaxGuard` (clamp to floor-safe max, flag over-max, gate the CTA). Wagmi is repointed to `baseSepolia` (84532); the SDK actions already re-quote before submit and the contract enforces the floor, so the UI guard is purely advisory. Withdraw renders a single-token tab and, when its output token's oracle is unsafe (caught `OracleUnsafeError` or a `tokenUnsafe` health probe), surfaces the proportional-exit path which needs no USD valuation or token selection.

**Tech Stack:** Next.js `16.2.6` app-router (React `19.2.4`), Tailwind CSS v4 (`@theme inline` in `globals.css`), wagmi `^2.14` + `@tanstack/react-query` `^5.62` + viem `^2.21`, `@arcoralabs/dex-sdk` workspace package (entrypoints `@arcoralabs/dex-sdk/v2` and `@arcoralabs/dex-sdk/react/v2`). Package manager is **pnpm workspaces**; the app is built/tested with **`pnpm --filter arcoradex-app <script>`** (the package `name` is `arcoradex-app`, NOT the `app/` dir name). Build = `pnpm --filter arcoradex-app build` (`next build`), tests = `pnpm --filter arcoradex-app test` (vitest), typecheck = `pnpm --filter arcoradex-app typecheck`. Render checks use the Playwright MCP against `pnpm --filter arcoradex-app dev` (http://localhost:3000). No new runtime dependency is required (icons are inline SVG per the prototype, not lucide).

**Out of scope (other plans / explicitly OUT):**
- The on-chain V2 contracts, oracle adapters, the Base Sepolia deploy, and off-chain monitoring (done / separate — `docs/rollouts/2026-06-10-base-sepolia-v2-deploy.md`, spec §12).
- The SDK V2 module itself (Plan 4a, merged — this plan only CONSUMES `@arcoralabs/dex-sdk/v2` + `/react/v2`).
- **Base mainnet** addresses/network (spec §13 — a later plan once the mainnet ledger exists). Only Base Sepolia 84532.
- A visual redesign beyond the prototype — match the prototype's exact colors/typography/spacing; do not invent new visual language.
- New SDK hooks/actions — if a needed read is missing, use the existing `sdk.getTokens()`/`sdk.getPoolStats()` client methods, do not add to the SDK here.

---

## Scope Decision (extend-in-place vs new files; pages) — DECIDED: new prototype-based UI files, all 3 pages, universal (not per-chain)

The input says "build the new prototype-based UI as new components/files; don't gut the existing pages in place" AND "apply to ALL pages, NOT chain-conditional." Resolved as:

- **New files, not edits to the Arc-blue components.** New components live under `components/ds/` (design-system primitives) and `components/v2/` (the V2-wired page bodies + §9 pieces). The OLD Arc-blue components (`components/swap/SwapCard.tsx`, `components/liquidity/*`, `components/pool/*`, the old `Header`/`Footer`) are **deleted at the end** (Task 12) once the new pages render, so the repo isn't left with two parallel UIs. The route files (`app/page.tsx`, `app/liquidity/page.tsx`, `app/pool/page.tsx`, `app/layout.tsx`) are **re-pointed** to the new components — these are thin shells, so editing them is not "gutting a page."
- **Universal shell, single chain target.** The new UI targets Base Sepolia 84532 only (the V2 ledger). Wagmi/`wagmi.ts` is repointed from `arcTestnet` to `baseSepolia`; the app no longer renders the Arc V1 UI. "Apply to all, not per-chain" is read as: the new prototype UI is THE app for every page, not a chain-conditional branch. Arc V1 is NOT kept running in this app (the SDK's V1 surface stays intact for other consumers; only this app moves).
- **Pages covered:** Swap (`/`), Liquidity (`/liquidity`), Pool (`/pool`) — all three, plus the shared shell (header/footer/background/toasts/providers) and the Faucet (re-pointed to the V2 token set).

---

## Resolved ambiguities (explicit)

1. **Theme replaces, not coexists.** The app's Arc-blue token set (`--arc-blue-*`, `--grad-arcora`, Roboto/Material Symbols) is fully replaced by the prototype's ServiceNow tokens (chartreuse accent, Hanken Grotesk + IBM Plex Mono, inline-SVG icons). There is no theme switch between Arc-blue and ServiceNow; "dark mode default + light option" is the prototype's own dark/light token pair (`data-theme` on `<html>`).
2. **Token universe is on-chain, not the 6-coin mock.** The prototype's `data.jsx` lists 6 stables (USDC/USDT/USDe/PYUSD/DAI/crvUSD); the LIVE V2 registry has **3** (USDC/USDT/EURC). The real UI renders `sdk.getTokens({ activeOnly: true })` — the visual treatment (CoinBadge discs, composition bar, reserves list) is preserved but driven by real data. No mock data ships.
3. **"Add Arc Testnet" chip → "Add Base Sepolia".** The prototype's network chip is relabeled and wired to `wallet_addEthereumChain` for 84532 (or a switch via `useSwitchChain`). The label/handler change but the chip's visual style is kept.
4. **Reserve-health is per OUTPUT token.** `useReserveHealth({ tokenOut })` keys on the receive/withdraw token (the floor that matters). The swap card shows the receive token's health; the withdraw tab shows the selected output token's health; the pool page's Reserves list shows each token's health as a small band.
5. **Estimated fee uses the quote's `feeUsd1e18`.** `estimatedFeePct(feeUsd1e18, grossUsd1e18)` — `grossUsd1e18` for swap = `amountOut`-derived gross from `maxSwapOut.grossUsd1e18` is NOT the per-trade gross; instead compute gross as `feeUsd1e18 + netUsd` is unavailable, so display the marginal fee as `estimatedFeePct(quote.feeUsd1e18, grossUsd1e18)` where `grossUsd1e18` is derived from the input amount × oracle (the SDK quote does not return gross; we approximate gross ≈ amountOut value + fee for display only, labelled "est."). The fee is advisory display; the contract is authoritative. (If a later SDK rev returns gross, swap the input — leave a `// TODO(gross)` marker.)
6. **Proportional withdraw needs no token/quote.** Per §8.3/§11 it returns the pro-rata basket; the UI shows "you receive a pro-rata share of all reserves" with `useWithdrawProportionalV2` and no Max/quote/health gating (it bypasses the floor). It is always available; it is PROMOTED (banner) when single-token is blocked by an unsafe oracle.
7. **Faucet re-points to V2 tokens + 84532.** `lib/faucet-tokens.ts`, `app/api/faucet/route.ts`, the rate-limit store, and `FaucetButton`/`ConnectButton` chain checks move from `arcTestnet.id` to `baseSepolia.id`. The faucet's mint set becomes the V2 token addresses (USDC/USDT/EURC). The faucet's minter/route security (BotID, Upstash, same-origin) is preserved unchanged in behaviour.
8. **Build command + names (FOUND):** app package `name` = **`arcoradex-app`**, dir `app/`; build = **`pnpm --filter arcoradex-app build`** (`next build`, Next 16.2.6); test = `pnpm --filter arcoradex-app test` (vitest); SDK package = `@arcoralabs/dex-sdk` with `./v2` + `./react/v2` exports.

---

## File Structure

| File | Responsibility (one each) |
|------|---------------------------|
| `app/app/globals.css` | **Replace** Arc-blue `@theme` + `:root` with the prototype's ServiceNow tokens (chartreuse `--accent`, `--sn-*`, `--green-*` ramp, semantic `--surface/--fg-1..3/--border/--elev-1..4/--glass-*`, `.overline`/`.h*`/`.code` type roles) for BOTH `data-theme="light"` and `data-theme="dark"`, the Hanken Grotesk + IBM Plex Mono `@import`, and the prototype keyframes (`ar-draw`, `ar-fadein`, `ar-pop`, `ar-overlay`, `ar-pagein`, `ar-toastin`, `ar-rowin`, `ar-spin`, `ar-pulse`, `ar-float1..3`). Keep `@import "tailwindcss"`. |
| `app/app/layout.tsx` | **Re-point** shell: set `data-theme="dark"` default on `<html>`, swap Roboto/Material-Symbols `<link>`s for the prototype fonts (or rely on the CSS `@import`), render new `<Header>`/`<Footer>`/`<Background>`/`<Toasts host>` inside `<Providers>`, update `<main>` wrapper (max 1280, the `44px 24px 0` padding). |
| `app/app/page.tsx` | **Re-point** the `/` (swap) route to `<SwapPageV2>`. |
| `app/app/liquidity/page.tsx` | **Re-point** the `/liquidity` route to `<LiquidityPageV2>`. |
| `app/app/pool/page.tsx` | **Re-point** the `/pool` route to `<PoolPageV2>`. |
| `app/components/wallet/Providers.tsx` | **Edit:** wrap children in `ArcoraDexV2Provider` (from `@arcoralabs/dex-sdk/react/v2`) — keep `WagmiProvider` + `QueryClientProvider`; the V2 provider auto-resolves `baseSepolia` + `DEFAULT_ADDRESSES_V2`. |
| `app/lib/wagmi.ts` | **Edit:** chains `[baseSepolia]` (from `@arcoralabs/dex-sdk/v2`), transport keyed by `baseSepolia.id`, env override `NEXT_PUBLIC_RPC_URL` falls back to `baseSepolia.rpcUrls.default.http[0]`. |
| `app/lib/chain.ts` | **New:** single source of `ACTIVE_CHAIN = baseSepolia`, `EXPLORER` (BaseScan), `addNetworkParams` for `wallet_addEthereumChain`. Imported by Header/Connect/Faucet so chain id/explorer live in one place. |
| `app/components/ds/tokens.ts` | **New:** TS mirror of the prototype's per-token brand colors (`tokenColor(symbol)`), accent constants, and shared inline-style helpers (`shade()`), so CoinBadge/composition bars match the prototype palette without a 6-coin mock. |
| `app/components/ds/Icon.tsx` | **New:** the prototype `ICONS` set + `<Icon name size stroke />` (inline single-stroke SVG, `currentColor`). Replaces Material Symbols. |
| `app/components/ds/Wordmark.tsx` | **New (replaces brand/Wordmark):** the prototype lime-disc + `arcora`+`dex` wordmark. |
| `app/components/ds/CoinBadge.tsx` | **New:** the prototype gradient stablecoin disc (`sym`, `color`, `size`, `ring`). |
| `app/components/ds/Card.tsx` | **New:** the prototype glass `Card` (surface, border, `--radius-lg`, `--elev-*`, optional hover lift). |
| `app/components/ds/Button.tsx` | **New:** the prototype `Button` (variants primary/brand/secondary/ghost/danger; sizes sm/md/lg; `icon`/`iconRight`/`full`/`disabled`). |
| `app/components/ds/Pill.tsx` | **New:** the prototype `Pill` (tones neutral/accent/success/danger/info). |
| `app/components/ds/Overline.tsx` | **New:** `.overline` label wrapper. |
| `app/components/ds/TokenSelectModal.tsx` | **New:** the prototype token-search modal, fed by V2 `TokenInfoV2[]` + balances (replaces `swap/TokenPickerModal`). |
| `app/components/ds/AreaChart.tsx` | **New:** the prototype draw-in area chart (Pool TVL). |
| `app/components/ds/Sparkline.tsx` | **New:** the prototype tiny sparkline (Pool stat tiles). |
| `app/components/ds/AnimatedNumber.tsx` | **New:** the prototype count-up number. |
| `app/components/layout/Header.tsx` | **Replace:** the prototype sticky glassy nav — Wordmark, Swap/Liquidity/Pool `NavTab`s (active underline), "Add Base Sepolia" chip, Faucet link/button, theme toggle, `<ConnectButton>`. |
| `app/components/layout/Footer.tsx` | **Replace:** the prototype 4-column footer (Protocol/Develop/Ecosystem/Network) + brand blurb + "Operational" pill + © bar. |
| `app/components/layout/Background.tsx` | **New:** the prototype animated mesh/grid backdrop blobs (`data-theme`-aware, motion-gated). |
| `app/components/layout/Toasts.tsx` + `app/components/layout/toast-store.ts` | **New:** the prototype toast host + a tiny client store (replaces `sonner`) for swap/deposit/withdraw confirmations with tx hash + explorer link. |
| `app/components/wallet/ConnectButton.tsx` | **Edit:** restyle to the prototype wallet button/dropdown; chain check → `ACTIVE_CHAIN.id` (84532); "Switch to Base Sepolia". |
| `app/components/wallet/NetworkButton.tsx` | **Edit:** the "Add Base Sepolia" chip → `wallet_addEthereumChain`/switch. |
| `app/components/wallet/FaucetButton.tsx` | **Edit:** restyle to prototype; chain check → 84532; mint-list from the V2 `FAUCET_TOKENS`. |
| `app/components/v2/useTokensV2.ts` | **New:** small hook over `useArcoraDexV2().getTokens({ activeOnly:true })` via react-query (the SDK has no `useTokensV2`); returns `TokenInfoV2[]` + by-address map. |
| `app/components/v2/usePoolStatsV2.ts` | **New:** react-query over `sdk.getPoolStats()` (no SDK hook for stats); NAV/LP price/paused for Pool + stat tiles. |
| `app/components/v2/useMaxGuard.ts` | **New (§9):** wraps `applyMaxGuard(entered,max)` → `{ amount, clamped, overMax }`; the swap/withdraw CTAs gate on `!overMax`. Unit-tested. |
| `app/components/v2/ReserveHealthBar.tsx` | **New (§9):** bps → `healthBand`/`healthLabel` → colored bar + label + post-trade delta (uses `postHealthBps` from the quote). Unit-tested mapping. |
| `app/components/v2/DynamicFeeRow.tsx` | **New (§9):** "Est. fee" row from `estimatedFeePct(feeUsd1e18, grossUsd1e18)` + a fee-band tooltip from `feeBandsForToken(token.bands)`. |
| `app/components/v2/SwapPageV2.tsx` | **New:** the prototype classic swap card wired to V2 — pay/receive fields, flip, token modal, `useQuoteSwapV2`, ReserveHealthBar (receive token), DynamicFeeRow, MAX (`useMaxSwapOut`+guard), over-max warning, quote-refresh-on-submit (`useSwapV2`), toast. |
| `app/components/v2/LiquidityPageV2.tsx` | **New:** the prototype deposit/withdraw two-pane layout wired to V2 — deposit (`useDepositV2`), single-withdraw tab (`useQuoteWithdrawV2`, `useMaxWithdraw`+guard, ReserveHealthBar, `useWithdrawSingleV2`), proportional-exit fallback (`useWithdrawProportionalV2`) promoted on `OracleUnsafeError`, LP rewards / position / pool-composition cards. |
| `app/components/v2/PoolPageV2.tsx` | **New:** the prototype pool analytics — 4 stat tiles (TVL/volume/LP price/fee from `usePoolStatsV2`), TVL AreaChart, Reserves list with per-token ReserveHealthBar, Recent-transactions feed (from `useSwapHistory`-style reads or a light on-chain log poll; if unavailable, render the prototype feed shell with a "live" pill over real `Swapped` events). |
| `app/lib/faucet-tokens.ts` | **Edit:** mint set → the live Base Sepolia V2 token addresses (USDC/USDT/EURC) with correct decimals/amounts. |
| `app/app/api/faucet/route.ts` | **Edit:** chain id 84532, V2 token set, explorer URL; keep BotID/same-origin/rate-limit logic. |
| `app/.env.example` | **Edit:** `NEXT_PUBLIC_CHAIN_ID=84532`, Base Sepolia RPC + BaseScan explorer, V2 Pool/Registry/LP addresses, keep WC/BotID/Upstash keys. |
| `app/components/v2/__tests__/useMaxGuard.test.ts` | **New:** unit — clamp/over-max/exact-max cases. |
| `app/components/v2/__tests__/health-band.test.ts` | **New:** unit — bps → band/label boundaries (7500/5000/2500). |
| `app/components/v2/__tests__/dynamic-fee.test.ts` | **New:** unit — `estimatedFeePct` rounding + zero-gross guard. |
| `docs/superpowers/plans/2026-06-10-base-v2-app-ui.md` | This plan. |

Removed at Task 12 (old Arc-blue UI, superseded): `components/swap/SwapCard.tsx`, `components/swap/TokenPickerModal.tsx`, `components/swap/SlippageMenu.tsx`, `components/swap/ConfirmSwapModal.tsx`, `components/liquidity/{DepositTab,WithdrawTab,PositionPanel}.tsx`, `components/pool/{RecentSwapsCard,ReservesTable}.tsx`, `components/brand/Wordmark.tsx`, `components/common/{TokenIcon,TokenSelect}.tsx`, `components/wallet/CircleFaucetLink.tsx` (Circle/Arc-specific), and the `components/ui/*` shadcn-ish primitives if unused after the port.

---

### Task 0: Branch + green baseline + pin the live V2 facts

**Files:** none modified; verification only.

- [ ] **Step 1: Branch from the current app tip**

Run:
```bash
git checkout -b feat/base-v2-app-ui && git log --oneline -1
```
Expected: a clean branch off the tip that contains the merged Plan 4a SDK V2 module (`@arcoralabs/dex-sdk/v2` + `./react/v2`) and the existing Arc-blue app.

- [ ] **Step 2: Establish the app baseline (must build today, before any change)**

Run:
```bash
pnpm --filter arcoradex-app build && pnpm --filter arcoradex-app test
```
Expected: build succeeds (the current Arc-blue UI) and tests pass. Record any pre-existing failures so they are not blamed on this plan.

- [ ] **Step 3: Confirm the SDK V2 entrypoints resolve from the app**

Run:
```bash
node -e "import('@arcoralabs/dex-sdk/v2').then(m=>console.log('v2:',Object.keys(m).slice(0,8))).catch(e=>{console.error(e);process.exit(1)})"
```
Expected: prints `createArcoraDexV2`, `baseSepolia`, `DEFAULT_ADDRESSES_V2`, `KNOWN_TOKENS_V2`, `healthBand`, … . If the workspace symlink is stale, run `pnpm install` first.

- [ ] **Step 4: Pin the live facts (paste into the PR description, do not hardcode beyond addresses.v2)**

Record: chainId `84532`, Pool `0x63FD6180dC6Aa5aE2941Bd28D2dc34c54F2b7820`, Registry `0xae1f10b007cDC4131797A45232a3D52Ff2C314e2`, LP `0x02aFC4c2c72ecE2049725DA2bd9080EF6285c844`, RPC `https://base-sepolia-rpc.publicnode.com`, explorer `https://sepolia.basescan.org`, V2 tokens USDC `0x3a98d8adC295d90171e9DA93D411dEa95674c867`, USDT `0x7110315D229C7CE655399703ACbA8E67f1d5C0c0`, EURC `0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7`. Source of truth: `packages/sdk/src/{addresses.v2,tokens/known.v2,chains/baseSepolia}.ts`.

**Verification:** baseline build + tests green; V2 import resolves.

---

### Task 1: Swap the design-token foundation (globals.css + layout fonts/theme)

**Files:** `app/app/globals.css`, `app/app/layout.tsx`.

- [ ] **Step 1: Replace `globals.css` tokens with the ServiceNow set**

Keep `@import "tailwindcss";` at the top. Replace the Arc-blue `@theme inline` + `:root` body with the prototype's foundation copied verbatim from `_ds/servicenow-design-system-*/colors_and_type.css`: the font `@import` (`Hanken Grotesk` + `IBM Plex Mono`), the CORE palette (`--sn-ink/-deep/-green/-sage`, `--chartreuse-100..700`, `--green-50..990`, functional hues), TYPE (`--font-sans/-mono/-display`, weights, `--text-*`, leading/tracking), spacing, `--radius-*`, MOTION (`--ease-*`, `--dur-*`), and BOTH semantic blocks `:root,[data-theme="light"]` and `[data-theme="dark"]` (the `--bg/--surface/--surface-2/--fg-1..3/--border*/--brand/--accent/--accent-hover/--action/--success/--info/--warning/--danger/--elev-0..4/--glass-bg/--glass-border/--glass-blur` tokens). Append the type-role classes (`.overline`, `.h1..h5`, `.title`, `.body`, `.code`).

- [ ] **Step 2: Add the prototype keyframes + base body**

Append the animation keyframes the components reference:
```css
@keyframes ar-draw { to { stroke-dashoffset: 0 } }
@keyframes ar-fadein { to { opacity: 1 } }
@keyframes ar-pop { from { opacity:0; transform: scale(.96) } to { opacity:1; transform:none } }
@keyframes ar-overlay { from { opacity:0 } to { opacity:1 } }
@keyframes ar-pagein { from { opacity:0; transform: translateY(6px) } to { opacity:1; transform:none } }
@keyframes ar-toastin { from { opacity:0; transform: translateX(16px) } to { opacity:1; transform:none } }
@keyframes ar-rowin { from { opacity:0; transform: translateY(-6px) } to { opacity:1; transform:none } }
@keyframes ar-spin { to { transform: rotate(360deg) } }
.ar-spin { animation: ar-spin .8s linear infinite; }
@keyframes ar-pulse { 0%{box-shadow:0 0 0 0 rgba(98,216,78,.6)} 70%{box-shadow:0 0 0 7px rgba(98,216,78,0)} 100%{box-shadow:0 0 0 0 rgba(98,216,78,0)} }
.ar-pulse { animation: ar-pulse 1.6s infinite; }
@keyframes ar-float1 { 0%,100%{transform:translate(-50%,-50%)} 50%{transform:translate(-46%,-54%)} }
@keyframes ar-float2 { 0%,100%{transform:translate(-50%,-50%)} 50%{transform:translate(-54%,-46%)} }
@keyframes ar-float3 { 0%,100%{transform:translate(-50%,-50%)} 50%{transform:translate(-48%,-52%)} }
html { -webkit-text-size-adjust: 100%; }
body { font-family: var(--font-sans); color: var(--fg-1); background: var(--bg); -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }
```

- [ ] **Step 3: Re-point `layout.tsx` theme + fonts**

Set `<html lang="en" data-theme="dark" className="h-full">`. Remove the Roboto/Roboto Flex/Material Symbols `<link>`s (fonts now come from the `globals.css` `@import`; optionally keep a `preconnect` to `fonts.googleapis.com`). Keep `<BotIdClient protect=[{path:"/api/faucet",method:"POST"}]/>`. Body: `className="min-h-full"` with the prototype shell (Background + Header + main + Footer + Toasts) added in Task 7 — for now keep the existing `<Header/><main/><Footer/>` so the build stays green; this task only changes tokens/fonts/theme.

- [ ] **Step 4: Verify**

```bash
pnpm --filter arcoradex-app build
```
Render check: `pnpm --filter arcoradex-app dev`, open `/` in Playwright MCP, `browser_take_screenshot`. Expect: page still renders (old Arc-blue components will now read undefined `--arc-*` vars and look broken — that's expected mid-port; confirm the BODY background is the dark green `--bg` and the font is Hanken Grotesk, proving the token swap took).

**Verification:** build passes; screenshot shows dark `--bg` + Hanken Grotesk applied.

---

### Task 2: Port the design-system primitives (`components/ds/*`)

**Files:** `components/ds/{tokens.ts,Icon.tsx,Wordmark.tsx,CoinBadge.tsx,Card.tsx,Button.tsx,Pill.tsx,Overline.tsx,AnimatedNumber.tsx,Sparkline.tsx,AreaChart.tsx}`.

- [ ] **Step 1: `tokens.ts` — palette + helpers**

Port `shade()` from `ui.jsx`. Add `tokenColor(symbol)` mapping the live V2 symbols to brand colors (`USDC #2775CA`, `USDT #26A17B`, `EURC #2B6CB0` or the prototype's blue family) with a deterministic fallback hash for unknown symbols. Export accent constant `ACCENT = "#C8F24A"`.

- [ ] **Step 2: `Icon.tsx`**

Port the full `ICONS` object + `<Icon name size=18 stroke=1.75 style className />` verbatim (TSX: use `dangerouslySetInnerHTML={{__html: d}}` on the `<svg>`). Type `name: keyof typeof ICONS`.

- [ ] **Step 3: `Wordmark.tsx`, `CoinBadge.tsx`**

Port both verbatim (inline styles + the lime-disc gradient + `var(--accent)` ring). `CoinBadge` label = `sym.replace(/USD/i,"$").slice(0,3)`.

- [ ] **Step 4: `Card.tsx`, `Button.tsx`, `Pill.tsx`, `Overline.tsx`**

Port verbatim. `Button` keeps the 5 variants + 3 sizes + hover/active state machine + `--accent` lime primary with the `0 2px 12px rgba(200,242,74,.32)` glow. `Pill` keeps the 5 tones. Mark each `"use client"` (they use `useState` for hover).

- [ ] **Step 5: `AnimatedNumber.tsx`, `Sparkline.tsx`, `AreaChart.tsx`**

Port verbatim (the rAF count-up; the draw-in area chart with the self-heal `setTimeout`). `"use client"`.

- [ ] **Step 6: A light render-smoke test (optional but recommended)**

A tiny vitest + `@testing-library/react` mount of `<Button>`/`<Pill>`/`<CoinBadge>` asserting they render text + the accent style — keeps the primitives honest. (If `@testing-library/react` is not a dev dep of the app, skip the DOM test and rely on the build/Playwright check — do not add the dep just for this.)

- [ ] **Step 7: Verify**

```bash
pnpm --filter arcoradex-app build
```
**Verification:** build passes; primitives compile under app-router (`"use client"` where stateful).

---

### Task 3: Wire wagmi + providers + chain to Base Sepolia 84532

**Files:** `lib/wagmi.ts`, `lib/chain.ts` (new), `components/wallet/Providers.tsx`.

- [ ] **Step 1: `lib/chain.ts`**

```ts
import { baseSepolia } from "@arcoralabs/dex-sdk/v2";
export const ACTIVE_CHAIN = baseSepolia;
export const EXPLORER = process.env.NEXT_PUBLIC_BLOCK_EXPLORER ?? "https://sepolia.basescan.org";
export const ADD_NETWORK_PARAMS = {
  chainId: "0x" + baseSepolia.id.toString(16),          // 0x14a34
  chainName: baseSepolia.name,
  nativeCurrency: baseSepolia.nativeCurrency,
  rpcUrls: baseSepolia.rpcUrls.default.http,
  blockExplorerUrls: [EXPLORER],
} as const;
```

- [ ] **Step 2: Repoint `lib/wagmi.ts`**

Replace `arcTestnet` with `baseSepolia` (import from `@arcoralabs/dex-sdk/v2`): `chains: [baseSepolia]`, `transports: { [baseSepolia.id]: fallback([http(RPC_URL)]) }`, `RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || baseSepolia.rpcUrls.default.http[0]`. Keep injected + optional walletConnect connectors and `ssr: true`.

- [ ] **Step 3: Wrap `Providers` with `ArcoraDexV2Provider`**

```tsx
import { ArcoraDexV2Provider } from "@arcoralabs/dex-sdk/react/v2";
// inside, replacing ArcoraDexProvider:
<ArcoraDexV2Provider>{children}</ArcoraDexV2Provider>
```
(The V2 provider defaults `chain=baseSepolia` + `DEFAULT_ADDRESSES_V2`, so no props are needed.)

- [ ] **Step 4: Verify**

```bash
pnpm --filter arcoradex-app build
```
Render check: `dev`, connect an injected wallet against Base Sepolia in Playwright (or assert `useChainId()` returns 84532 via a temporary debug print). Confirm no "two WagmiContexts" warning (the `turbopack.root` pin in `next.config.ts` already prevents the double-context fork — leave it).

**Verification:** build passes; app reads chainId 84532; V2 provider mounts.

---

### Task 4: §9 building blocks — `useMaxGuard`, `ReserveHealthBar`, `DynamicFeeRow` (+ unit tests)

**Files:** `components/v2/{useMaxGuard.ts,ReserveHealthBar.tsx,DynamicFeeRow.tsx}`, `components/v2/__tests__/{useMaxGuard,health-band,dynamic-fee}.test.ts`.

- [ ] **Step 1: `useMaxGuard.ts`**

```ts
import { applyMaxGuard } from "@arcoralabs/dex-sdk/v2";
export function useMaxGuard(entered: bigint | null, max: bigint | null) {
  if (entered == null || max == null) return { amount: entered ?? 0n, clamped: false, overMax: false };
  return applyMaxGuard(entered, max);   // { amount, clamped, overMax }
}
```
The CTA gates on `!overMax`; the `Max` button setter writes the floor-safe `max` (formatted to the token's decimals).

- [ ] **Step 2: `ReserveHealthBar.tsx`**

```tsx
import { healthBand, healthLabel } from "@arcoralabs/dex-sdk/v2";
const BAND_COLOR = { "75-100":"var(--success)", "50-75":"var(--accent)", "25-50":"var(--warning)", "0-25":"var(--danger)" } as const;
export function ReserveHealthBar({ healthBps, postHealthBps }: { healthBps: number; postHealthBps?: number }) {
  const band = healthBand(healthBps); const label = healthLabel(healthBps);
  const pct = Math.max(0, Math.min(100, healthBps / 100));
  // overline + label pill + a track with a fill at pct + (optional) a ghost marker at postHealthBps
}
```
Use `--surface-2` track, `BAND_COLOR[band]` fill, IBM Plex Mono label. When `postHealthBps` is provided (from the quote), render a thin "after" marker + a `↓ to {label}` hint.

- [ ] **Step 3: `DynamicFeeRow.tsx`**

```tsx
import { estimatedFeePct, feeBandsForToken } from "@arcoralabs/dex-sdk/v2";
export function DynamicFeeRow({ feeUsd1e18, grossUsd1e18, bands }: { feeUsd1e18: bigint; grossUsd1e18: bigint; bands?: { upperHealthBps:number; rateBps:number }[] }) {
  const pct = estimatedFeePct(feeUsd1e18, grossUsd1e18);
  // "Est. fee  {pct.toFixed(2)}%" detail row; on hover/expand list feeBandsForToken(bands) as "75-100% → 0.05%" rows
}
```

- [ ] **Step 4: Unit tests (real, light)**

`useMaxGuard.test.ts`: entered<max → passthrough no clamp; entered===max → no over; entered>max → `{amount:max, clamped:true, overMax:true}`; null inputs → safe default.
`health-band.test.ts`: 10000/7500→"75-100"/"Healthy"; 7499/5000→"50-75"/"Caution"; 4999/2500→"25-50"/"Low"; 2499/0→"0-25"/"Critical".
`dynamic-fee.test.ts`: `estimatedFeePct(5n*10n**14n, 10n**18n)` ≈ 0.05; `grossUsd1e18===0n`→0.

- [ ] **Step 5: Verify**

```bash
pnpm --filter arcoradex-app test && pnpm --filter arcoradex-app build
```
**Verification:** the three unit suites pass; components compile.

---

### Task 5: Token + pool-stats hooks + the prototype `TokenSelectModal` (V2-fed)

**Files:** `components/v2/{useTokensV2.ts,usePoolStatsV2.ts}`, `components/ds/TokenSelectModal.tsx`.

- [ ] **Step 1: `useTokensV2.ts`**

```tsx
"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "@arcoralabs/dex-sdk/react/v2";
export function useTokensV2() {
  const sdk = useArcoraDexV2();
  const { data, isFetching } = useQuery({
    queryKey: ["arcora","v2","tokens", sdk.chain.id],
    queryFn: () => sdk.getTokens({ activeOnly: true }),
  });
  const tokens = data ?? [];
  const byAddr = Object.fromEntries(tokens.map(t => [t.address.toLowerCase(), t]));
  return { tokens, byAddr, isFetching };
}
```

- [ ] **Step 2: `usePoolStatsV2.ts`**

react-query over `sdk.getPoolStats()` → `{ navUsd1e18, lpSupply, lpPriceUsd1e18, protocolFeeShareBps, paused }`. `queryKey: ["arcora","v2","poolStats", sdk.chain.id]` so the mutation invalidations (already emitted by the V2 mutation hooks) refresh it.

- [ ] **Step 3: `TokenSelectModal.tsx`**

Port the prototype modal but typed for `TokenInfoV2[]` + a `balances: Record<addrLower,bigint>` map. Render `CoinBadge` (color via `tokenColor(t.symbol)`), `t.symbol`/`t.name`, formatted balance, search by symbol/name/address. `exclude` is the other side's address.

- [ ] **Step 4: Verify**

```bash
pnpm --filter arcoradex-app build
```
Render check: a temporary mount of `<TokenSelectModal open tokens={...}/>` shows USDC/USDT/EURC discs (or run after Task 6 inside the swap card).

**Verification:** build passes; modal lists the live token set.

---

### Task 6: Swap page (`SwapPageV2`) — full §9 surface

**Files:** `components/v2/SwapPageV2.tsx`, `app/app/page.tsx`.

- [ ] **Step 1: Engine state + balances**

`"use client"`. State: `tokenIn`/`tokenOut` (default to `tokens[0]`/`tokens[1]` addresses), `amountStr`, `picker`, `slippageBps` (default 50). Balances via `useReadContract` `balanceOf` per side (like the old SwapCard). `amountIn = tryParseUnits(amountStr, inMeta.decimals)`.

- [ ] **Step 2: Quote + health + max**

```tsx
const { data: quote, isFetching } = useQuoteSwapV2({ tokenIn, tokenOut, amountIn });
const { data: health } = useReserveHealth({ tokenOut });
const { data: maxOut } = useMaxSwapOut({ tokenOut });
```
`quote` is `{ amountOut, protocolFee, feeUsd1e18, postHealthBps }`. The receive field shows `fmtUnits(quote.amountOut, outMeta.decimals)`.

- [ ] **Step 3: Render the prototype classic card**

Reproduce `swap.jsx`'s CLASSIC layout: `<Card pad={20} elev={2}>`, `SwapHeader` (title + settings popover with the 0.1/0.5/1.0 presets), pay `FieldBox`, `FlipBtn`, receive `FieldBox` (readOnly), the detail block, the CTA. Use the ported DS primitives. The MAX mini-button sets `amountStr` from `maxOut.netOut` interpreted as the **input** floor-safe max — NOTE: `maxSwapOut` returns the max OUTPUT; for the input cap, set the amount such that the quote's output ≤ `maxOut.netOut`. Simplest faithful approach: on MAX, set `amountStr` to the user's balance, then let the over-max guard (Step 4) clamp using a derived input-max. Document this with `// §9: MAX = min(balance, floor-safe input)`; if `maxSwapOut`-as-output makes input-cap non-trivial, compute input-max by binary-search of the quote OR cap output display + warn (see Step 4). Keep it advisory.

- [ ] **Step 4: §9 wiring (the load-bearing part)**

Insert into the detail block: `<ReserveHealthBar healthBps={health.healthBps} postHealthBps={quote?.postHealthBps} />` and `<DynamicFeeRow feeUsd1e18={quote.feeUsd1e18} grossUsd1e18={grossForDisplay} bands={outMeta.bands} />` where `grossForDisplay ≈ quote.amountOut`-value + `quote.feeUsd1e18` (advisory; mark `// TODO(gross)`). Compute `overMax`: if `quote.amountOut > maxOut.netOut` (output exceeds floor-safe), show a warning row "Amount exceeds the floor-safe maximum — reduce or it will revert" and **disable the CTA**. The MAX button sets the amount to the largest value whose quote stays ≤ `maxOut.netOut`. The contract still enforces the floor (advisory UI).

- [ ] **Step 5: Submit (quote-refresh-before-submit)**

`const swap = useSwapV2();` On confirm: `await swap.mutateAsync({ tokenIn, tokenOut, amountIn, slippageBps, deadline })`. The SDK action already re-quotes immediately before the write (Plan 4a, `swapV2.ts` §9 comment), so the UI requirement is satisfied by the action; additionally, gate the button so it never fires while `isFetching` (stale quote). On success, `pushToast({kind:"success", title:"Swap confirmed", hash})` with the explorer link; clear `amountStr`. Surface `swap.error.message` on failure.

- [ ] **Step 6: Re-point `app/page.tsx`**

```tsx
import { SwapPageV2 } from "@/components/v2/SwapPageV2";
export default function Page() { return <SwapPageV2 />; }
```
(Drop the old `SwapCard`/`RecentSwapsCard` grid here.)

- [ ] **Step 7: Verify**

```bash
pnpm --filter arcoradex-app build
```
Render check (Playwright MCP): `dev`, `/`, connect wallet on 84532, screenshot — expect the lime swap card matching `screenshots/swap2.png`, with a reserve-health bar + "Est. fee" row, MAX button, and (entering a huge amount) the over-max warning + disabled CTA. Capture a before/after screenshot pair.

**Verification:** build passes; screenshot shows the prototype swap card + §9 health bar + dynamic fee + working MAX/over-max guard.

---

### Task 7: Shell — Header, Footer, Background, Toasts, ConnectButton, NetworkButton

**Files:** `components/layout/{Header,Footer,Background,Toasts}.tsx`, `components/layout/toast-store.ts`, `components/wallet/{ConnectButton,NetworkButton}.tsx`, `app/app/layout.tsx`.

- [ ] **Step 1: `toast-store.ts` + `Toasts.tsx`**

A tiny client store (`useSyncExternalStore` or a Zustand-free module-level `Set` + `useState` subscriber) exposing `pushToast`/`dismiss`. Port the prototype `Toasts` host (bottom-right, `ar-toastin`, success/info icon, hash + external icon). Replace any `sonner` usage.

- [ ] **Step 2: `Background.tsx`**

Port the prototype `Background` (mesh blobs `ar-float1..3`, optional grid). Render it `position:fixed; inset:0; z-index:0` behind the shell. Default `style="mesh"`, motion on.

- [ ] **Step 3: `Header.tsx`**

Port `TopNav`: sticky glass (`--glass-bg`/`--glass-blur`), `Wordmark`, `NavTab` Swap/Liquidity/Pool (active = `usePathname()` match, lime underline), the "Add Base Sepolia" chip (`<NetworkButton>`), Faucet (`<FaucetButton>`), theme toggle button (sets `document.documentElement.dataset.theme`, persists to `localStorage`), `<ConnectButton>`. Use `next/link` for the nav.

- [ ] **Step 4: `ConnectButton.tsx` + `NetworkButton.tsx`**

`ConnectButton`: restyle to the prototype wallet button + dropdown; `wrongChain = isConnected && chainId !== ACTIVE_CHAIN.id`; "Switch to Base Sepolia" via `useSwitchChain`. `NetworkButton`: the chip calls `window.ethereum.request({ method:"wallet_addEthereumChain", params:[ADD_NETWORK_PARAMS] })` (fallback to `switchChain`).

- [ ] **Step 5: `Footer.tsx`**

Port the prototype 4-column footer (Protocol/Develop/Ecosystem/Network), brand blurb (update copy to "Stableswap on Base Sepolia… ArcoraPay ecosystem"), "Operational" success pill, © `v2-testnet` bar. Relabel "Arc Testnet" links → "Base Sepolia".

- [ ] **Step 6: Assemble in `layout.tsx`**

Body: `<Providers><Background/><div className="relative z-1"><Header/><main style padding 44 24 0 max-1280><PageFade>{children}</PageFade></div><Footer/></Providers><Toasts/>`. Add a `PageFade` client wrapper (`ar-pagein`) keyed on `usePathname()` if desired (optional).

- [ ] **Step 7: Verify**

```bash
pnpm --filter arcoradex-app build
```
Render check: `/`, screenshot the full page — expect the header (Wordmark + lime Connect button + Faucet + Add-Base-Sepolia chip), the mesh background, and the 4-column footer matching `screenshots/01-v-pages.png`/`02-v-pages.png`. Toggle theme and confirm light/dark both render.

**Verification:** build passes; header + footer + background + theme toggle + toasts match the prototype.

---

### Task 8: Liquidity page (`LiquidityPageV2`) — deposit, single-withdraw, proportional fallback (§8.2/§8.3/§11)

**Files:** `components/v2/LiquidityPageV2.tsx`, `app/app/liquidity/page.tsx`.

- [ ] **Step 1: Two-pane prototype layout**

Port `liquidity.jsx`: left action `Card` with a Deposit/Withdraw tab pill; right column = LP-rewards card (90% to LPs / APR pill / TVL·24h-fees·to-LPs tiles from `usePoolStatsV2`), the "Your position" card (LP balance from `balanceOf` on the LP token + `lpPriceUsd1e18`), and the Pool-composition card (per-token weight bar from `tokens` + reserves; derive weights from on-chain reserves if exposed, else from `targetReserveUsd`).

- [ ] **Step 2: Deposit tab**

Token select (any active token), amount, balance, MAX. `const dep = useDepositV2();` On submit `dep.mutateAsync({ token, amount, ... })`. Show LP-minted estimate (advisory) + a deposit-cap note (`depositCapUsd` from the token config); if over cap, warn. Toast on success.

- [ ] **Step 3: Single-token withdraw tab (§8.2 + §9)**

Output token select, LP amount input. `const { data: quote } = useQuoteWithdrawV2({ tokenOut, lpAmount });` `const { data: maxW } = useMaxWithdraw({ tokenOut, account });` MAX sets `lpAmount` from `maxW.lpAmount` via `useMaxGuard` (over-max → warn + disable). Show `<ReserveHealthBar healthBps postHealthBps={quote.postHealthBps}/>` for the output token + `<DynamicFeeRow feeUsd1e18={quote.feeUsd1e18} .../>`. Submit `useWithdrawSingleV2().mutateAsync({ tokenOut, lpAmount, minTokenOut/slippage })`. Keep the prototype's "Single-token withdraw — redeem entirely in {tok} at the oracle price" info banner.

- [ ] **Step 4: Proportional emergency withdraw (§8.3/§11) + oracle-unsafe fallback**

Add a "Proportional exit" affordance under the withdraw tab: a `useWithdrawProportionalV2()` action that burns LP and returns the pro-rata basket — **no** token select, **no** quote, **no** Max/health gating (it bypasses the floor). PROMOTE it (a `Pill tone="warning"` banner + auto-switch) when single-token is unavailable: detect via (a) a caught `OracleUnsafeError` from a single-withdraw attempt, OR (b) the output token reading unsafe (e.g. `useReserveHealth`/`getTokens` shows `isActive=false` or a health probe errors). Copy: "This token's oracle is unsafe — single-token withdrawal is paused. You can still exit proportionally (pro-rata share of all reserves)." Submit `withdrawProportional.mutateAsync({ lpAmount, minAmountsOut? })`; show the returned `amounts[]` in the success toast.

- [ ] **Step 5: Re-point `app/liquidity/page.tsx`**

```tsx
import { LiquidityPageV2 } from "@/components/v2/LiquidityPageV2";
export default function Page() { return <LiquidityPageV2 />; }
```

- [ ] **Step 6: Verify**

```bash
pnpm --filter arcoradex-app build
```
Render check: `/liquidity`, screenshot deposit + withdraw tabs (match `screenshots/01-v-pages.png`); simulate/force an `OracleUnsafeError` (e.g. a token with no safe oracle, or mock the mutation to throw it in a temporary dev toggle) and confirm the proportional-exit banner appears and proportional withdraw is callable.

**Verification:** build passes; deposit, single-withdraw (with health+fee+Max guard), and proportional fallback all render; oracle-unsafe promotes proportional.

---

### Task 9: Pool page (`PoolPageV2`) — analytics + reserves health + live feed

**Files:** `components/v2/PoolPageV2.tsx`, `app/app/pool/page.tsx`.

- [ ] **Step 1: Stat tiles + TVL chart**

Port `pool.jsx`: 4 `BigStat` tiles — Pool TVL (`navUsd1e18`), 24h volume (from a `Swapped`-event sum if available, else hide/placeholder with a real label), LP price (`lpPriceUsd1e18`), Swap fee (the active band's marginal rate or `protocolFeeShareBps` context). Use `AnimatedNumber` + `Sparkline`. The TVL `AreaChart` uses a real series if a history read exists, else a single-point/flat series labelled honestly (do NOT fabricate a mock series — the prototype's `genSeries` is removed). Keep the 24H/7D/30D/ALL range pills as UI even if only one bucket has data.

- [ ] **Step 2: Reserves list with per-token health**

For each `token` in `tokens`: `CoinBadge`, symbol/name, reserve USD (from `getPoolStats`/per-token reserve read), weight %, oracle price, and a compact `<ReserveHealthBar healthBps={...}/>` (call `useReserveHealth({tokenOut: token.address})` per token, or a batched read). Match `screenshots/02-v-pages.png` reserves panel.

- [ ] **Step 3: Recent transactions feed**

Port the prototype `LiveFeed` shell (the "Recent transactions" card + "Live" pulse pill + row layout). Feed it REAL `Swapped`/`WithdrewSingle`/`WithdrewProportional` events via a light `usePublicClient().getLogs`/`watchEvent` poll on the Pool (decoded with `poolAbiV2`), newest-first, capped at 30, with `ar-rowin` on fresh rows. If wiring a log watcher is heavy, render the card with the current connected user's own recent actions (from the mutation results) — but prefer real on-chain logs. No `randAddr`/`makeTx` mock data.

- [ ] **Step 4: Re-point `app/pool/page.tsx`**

```tsx
import { PoolPageV2 } from "@/components/v2/PoolPageV2";
export default function Page() { return <PoolPageV2 />; }
```

- [ ] **Step 5: Verify**

```bash
pnpm --filter arcoradex-app build
```
Render check: `/pool`, screenshot — expect the 4 lime/info/success stat tiles, the TVL area chart, the reserves panel with per-token health bars, and the live feed, matching `screenshots/02-v-pages.png`.

**Verification:** build passes; pool analytics + reserves health + (real) feed render.

---

### Task 10: Faucet → V2 tokens + 84532

**Files:** `lib/faucet-tokens.ts`, `app/api/faucet/route.ts`, `components/wallet/FaucetButton.tsx`, `lib/faucet-rate-limit.ts` (if it hardcodes chain), `app/.env.example`.

- [ ] **Step 1: `faucet-tokens.ts`**

Replace the Arc token set with the live Base Sepolia V2 mint set (USDC `0x3a98…c867` 6dp, USDT `0x7110…C0c0` 6dp, EURC `0x4b1F…8bD7` 6dp) with `$1000`-equivalent amounts. Keep the `FaucetToken` interface + the test assertion shape.

- [ ] **Step 2: `route.ts` + rate-limit**

Update the chain id check / minter config / explorer to 84532 / BaseScan. Keep BotID `checkBotId`, same-origin CSRF, and the Upstash/in-memory rate-limit logic byte-for-byte. Ensure the faucet's signer/minter env points at a Base Sepolia funded key (document the env var; do not commit a key).

- [ ] **Step 3: `FaucetButton.tsx`**

Restyle to the prototype (lime CTA, prototype modal); `wrongChain` check → `ACTIVE_CHAIN.id`; mint-list from the V2 `FAUCET_TOKENS`; explorer = BaseScan.

- [ ] **Step 4: `.env.example`**

`NEXT_PUBLIC_CHAIN_ID=84532`, `NEXT_PUBLIC_RPC_URL=https://base-sepolia-rpc.publicnode.com`, `NEXT_PUBLIC_BLOCK_EXPLORER=https://sepolia.basescan.org`, `NEXT_PUBLIC_POOL_ADDRESS=0x63FD…7820`, `NEXT_PUBLIC_REGISTRY_ADDRESS=0xae1f…14e2`, `NEXT_PUBLIC_LP_ADDRESS=0x02aF…c844`; keep WC/BotID/Upstash/`NEXT_PUBLIC_APP_URL`.

- [ ] **Step 5: Verify**

```bash
pnpm --filter arcoradex-app test && pnpm --filter arcoradex-app build
```
The existing `faucet-tokens.test.ts` / `route.test.ts` must pass against the new set (update expectations in those tests as part of this task). Render check: open the Faucet modal, confirm it lists USDC/USDT/EURC.

**Verification:** faucet tests pass; modal lists V2 tokens; route targets 84532.

---

### Task 11: Cross-page polish — loading/empty/error states, a11y, paused/disconnected

**Files:** `components/v2/*` (touch-ups), `components/ds/*`.

- [ ] **Step 1: Disconnected + wrong-chain states**

Every page renders sensibly with no wallet (CTA = "Connect wallet"; balances "—"; reads that don't need an account still populate). Wrong chain → the CTA becomes "Switch to Base Sepolia" (mirror across Swap/Liquidity/Faucet).

- [ ] **Step 2: Loading / empty / paused**

Quote `isFetching` → a subtle "Refreshing…" label (prototype style) and the CTA disabled while stale (satisfies "refresh before submit"). `poolStats.paused === true` → a banner "Pool is paused" and swaps/deposits disabled (proportional withdraw stays available per §11). Empty token list → a graceful "No active tokens" state.

- [ ] **Step 3: a11y**

Keep the existing `role="alert"`/`aria-live` on faucet failures; add `aria-label`s on icon-only buttons (flip, settings, theme, close); ensure modals trap focus + close on Escape (the prototype modal already wires Escape).

- [ ] **Step 4: Verify**

```bash
pnpm --filter arcoradex-app build
```
Render check: Playwright — disconnected `/`, wrong-chain `/`, and (if forceable) paused-pool banner. Screenshot each.

**Verification:** build passes; states render; no console errors in the Playwright run (`browser_console_messages` clean).

---

### Task 12: Remove the superseded Arc-blue UI + final verification

**Files:** delete the old components listed in the File Structure note; final sweep of `app/`.

- [ ] **Step 1: Delete superseded files**

Remove `components/swap/{SwapCard,TokenPickerModal,SlippageMenu,ConfirmSwapModal}.tsx`, `components/liquidity/{DepositTab,WithdrawTab,PositionPanel}.tsx`, `components/pool/{RecentSwapsCard,ReservesTable}.tsx`, `components/brand/Wordmark.tsx`, `components/common/{TokenIcon,TokenSelect}.tsx`, `components/wallet/CircleFaucetLink.tsx`, and any now-unused `components/ui/*` + `sonner` import. Update `tailwind.tokens.json` if it referenced Arc-blue tokens.

- [ ] **Step 2: Grep for stragglers**

```bash
grep -rnE "arc-blue|grad-arcora|arcTestnet|Material Symbols|@arcoralabs/dex-sdk/react\b|sonner" app/ --include=*.ts --include=*.tsx --include=*.css | grep -v node_modules
```
Expected: no live references to the V1/Arc theme, the V1 react entrypoint (`/react` without `/v2`), `arcTestnet`, Material Symbols, or `sonner` (except in deleted files / comments). Fix any hit.

- [ ] **Step 3: Full verification**

```bash
pnpm --filter arcoradex-app typecheck && pnpm --filter arcoradex-app test && pnpm --filter arcoradex-app build
```
All green. Then a final Playwright pass over `/`, `/liquidity`, `/pool` (connected on 84532): screenshot each, confirm they match `screenshots/swap2.png` / `01-v-pages.png` / `02-v-pages.png`, the §9 features are visible (health bar + est. fee + Max + over-max warning on swap/withdraw; proportional fallback on liquidity), and the console is clean.

- [ ] **Step 4: Hand off (do NOT commit)**

Leave the branch for the controller to review + commit. Summarize in the PR body: pages ported, §9 features wired, chain repointed to 84532, faucet repointed, old UI removed.

**Verification:** typecheck + tests + build all pass; all three pages render the prototype design with the §9 V2 features; console clean; no Arc-blue/V1 stragglers.

---

## Gotchas (encode these)

- **SDK import paths:** the package is `@arcoralabs/dex-sdk`; the V2 surface is `@arcoralabs/dex-sdk/v2` (client/helpers/types/chain/addresses) and `@arcoralabs/dex-sdk/react/v2` (hooks + `ArcoraDexV2Provider`). Do NOT import V2 hooks from `/react` (that's the V1 layer). There is no `useTokensV2`/`usePoolStatsV2` hook in the SDK — use `useArcoraDexV2().getTokens()`/`.getPoolStats()` wrapped in react-query (Task 5).
- **The quote is four-return:** `{ amountOut, protocolFee, feeUsd1e18, postHealthBps }`. Use `feeUsd1e18` for the dynamic fee and `postHealthBps` for the after-trade health marker.
- **Match the prototype exactly:** colors (`--accent: #C8F24A`, `--sn-*`, `--green-*`), type (Hanken Grotesk + IBM Plex Mono), radii/elevation/glass tokens, and the inline-SVG icon set — copy from `_ds/.../colors_and_type.css` + `ui.jsx`, do not approximate.
- **Next.js app-router:** every stateful/`window`/wagmi-touching component needs `"use client"`. Server components (route files, layout) stay server unless they render client children only.
- **Don't break the build:** keep the old shell rendering until each page is re-pointed; delete the old UI only in Task 12. Keep the `turbopack.root` pin in `next.config.ts` (prevents the double-WagmiContext prerender break) and the BotID config wrapper.
- **No mock data:** the prototype's `data.jsx` (6 coins, fake series, `makeTx`) is design reference only — the real UI renders the live 3-token V2 registry + real reads. Preserve the visual treatment, drop the mock generators.
- **§9 guards are advisory:** the SDK action re-quotes before submit and the contract enforces the floor; the UI Max/over-max/health are advisory. Never SUBMIT over-max (disable the CTA), but rely on the contract as the final layer.
- **Faucet chain churn:** every `arcTestnet.id` check (ConnectButton, FaucetButton, SwapCard, route) must move to `baseSepolia.id` (84532) — grep in Task 12 to be sure.

---

## Feature Reachability Checklist + Gap-fills (controller addendum)

Requirement: **every protocol capability must be reachable from the frontend** (user
directive). Core flows are covered by Tasks 0–12. The following are explicit gap-fills to
add DURING execution (the prototype omitted them; the user expects iterative completion):

- [ ] **GF-1 — Protocol/governance status surface (read-only).** A `/status` route or an
  "About/Protocol" panel showing: Pool `paused` state, Timelock address + `getMinDelay()`
  (48h), Gov Safe + Pause-Guardian Safe addresses + thresholds, current adapter/oracle owner.
  Reads only; links to BaseScan. (Task 9 or a new thin route.)
- [ ] **GF-2 — Per-token oracle badge.** On Swap/Pool, each token shows its live oracle
  price (from `getTokens()`/adapter `peekPrice`) + a safe/unsafe badge; unsafe → the token is
  disabled for oracle-priced ops and the proportional-exit hint surfaces (already §11-wired).
- [ ] **GF-3 — LP position + value.** On Liquidity/Pool, the connected wallet's LP balance,
  its USD value (`lpPriceUsd1e18 × balance`), and pool share %. Drives the withdraw Max.
- [ ] **GF-4 — Deposit-cap state.** Show each token's `depositCapUsd` headroom; when a token
  is at/near cap, disable deposit with a "cap reached" message (contract `DepositCapExceeded`
  stays the backstop).
- [ ] **GF-5 — Per-token reserve floor / target + fee-band schedule** visible on Pool (the
  §7 marginal schedule via `feeBandsForToken` / `INITIAL_FEE_SCHEDULE`), so users understand
  why a large swap/withdraw costs more.

These are small read-only/UX additions; fold each into the matching page task or add a thin
`/status` route. None block the core build.
