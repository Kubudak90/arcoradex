# ArcoraDEX SDK (Phase B v0.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `@arcoralabs/dex-sdk` (a viem-based, framework-agnostic TypeScript SDK with a `/react` subpath of hooks) inside a pnpm workspace, then migrate the `app/` frontend to consume it as the single source of truth — eliminating the existing `app/lib/{abi,contracts,format,slippage,hooks/useTokens}` duplication.

**Architecture:** Monorepo with two workspace packages (`app/`, `packages/sdk/`). SDK ships ESM-only via tsup, source-direct in dev (no build step required for `app/` to import from it). Unified `createArcoraDex({chain, transport, account?})` factory; auto-approve (`MAX_UINT256`) inside `swap`/`deposit`; pull-based reads + opt-in event subscriptions via viem `watchContractEvent`. React hooks layer wraps every read/write/subscription with React Query state management and an `<ArcoraDexProvider>` derived from wagmi. Vitest + Anvil-backed integration tests deploy fresh contracts per run via the existing `contracts/script/DeployArcoraDex.s.sol`.

**Tech Stack:** TypeScript 5 (target ES2022, strict + noUncheckedIndexedAccess) · pnpm 10 workspace · tsup (esbuild) for builds · viem 2.x · wagmi 2.x · @tanstack/react-query 5.x · React 19 · Vitest 2.x · @testing-library/react · Foundry/Anvil for integration · ESLint flat config (strict for SDK)

**Reference:** [`docs/superpowers/specs/2026-05-06-sdk-phase-b-design.md`](../specs/2026-05-06-sdk-phase-b-design.md)

---

## File Map

### Created
```
pnpm-workspace.yaml
package.json                                          # root, private monorepo

packages/sdk/
├── package.json
├── tsup.config.ts
├── tsconfig.json
├── tsconfig.build.json
├── vitest.config.ts
├── eslint.config.mjs
├── README.md
├── src/
│   ├── index.ts                                      # core public barrel
│   ├── client.ts                                     # createArcoraDex factory
│   ├── addresses.ts                                  # v1.0-testnet defaults per chainId
│   ├── chains/arcTestnet.ts                          # viem Chain definition
│   ├── tokens/known.ts                               # KNOWN_TOKENS map
│   ├── tokens/label.ts                               # tokenLabel + getAddress normalization
│   ├── abi/pool.ts                                   # parseAbi
│   ├── abi/registry.ts
│   ├── abi/lp.ts
│   ├── abi/erc20.ts
│   ├── format/index.ts                               # fmtUnits, fmtUSD, tryParseUnits
│   ├── slippage/index.ts                             # minOut, deadline
│   ├── errors.ts                                     # ArcoraDexError + parseContractError
│   ├── allowance.ts                                  # ensureAllowance helper
│   ├── types.ts                                      # SwapResult, etc.
│   ├── actions/quoteSwap.ts
│   ├── actions/quoteDeposit.ts
│   ├── actions/quoteWithdraw.ts
│   ├── actions/getPoolStats.ts
│   ├── actions/getTokens.ts
│   ├── actions/getReserves.ts
│   ├── actions/getPosition.ts
│   ├── actions/getProtocolFees.ts
│   ├── actions/swap.ts
│   ├── actions/deposit.ts
│   ├── actions/withdraw.ts
│   ├── subscriptions/subscribeSwaps.ts
│   ├── subscriptions/subscribeDeposited.ts
│   ├── subscriptions/subscribeWithdrew.ts
│   ├── subscriptions/subscribePoolStats.ts
│   └── react/
│       ├── index.ts                                  # react public barrel
│       ├── ArcoraDexProvider.tsx
│       ├── useArcoraDex.ts
│       ├── useTokens.ts
│       ├── useQuoteSwap.ts
│       ├── useQuoteDeposit.ts
│       ├── useQuoteWithdraw.ts
│       ├── usePoolStats.ts
│       ├── usePosition.ts
│       ├── useSwap.ts
│       ├── useDeposit.ts
│       ├── useWithdraw.ts
│       ├── useAllowance.ts
│       └── useSwapHistory.ts
└── test/
    ├── setup.ts                                      # bootstrapAnvil()
    ├── deploy.ts                                     # invokes forge script
    ├── unit/format.test.ts
    ├── unit/slippage.test.ts
    ├── unit/errors.test.ts
    ├── unit/tokens.test.ts
    ├── integration/client.test.ts
    ├── integration/read.test.ts
    ├── integration/swap.test.ts
    ├── integration/deposit.test.ts
    ├── integration/withdraw.test.ts
    ├── integration/errors.test.ts
    ├── integration/subscriptions.test.ts
    └── react/
        ├── TestWrapper.tsx
        ├── useTokens.test.tsx
        ├── useQuoteSwap.test.tsx
        ├── useSwap.test.tsx
        ├── usePoolStats.test.tsx
        └── useSwapHistory.test.tsx

.github/workflows/sdk.yml                             # CI (path-filtered to packages/sdk)
```

### Modified
```
app/package.json                                      # add "@arcoralabs/dex-sdk": "workspace:*"
app/components/swap/SwapCard.tsx                      # consume hooks
app/components/liquidity/{Deposit,Withdraw}Tab.tsx
app/components/liquidity/PositionPanel.tsx
app/components/pool/{Reserves,SwapHistory}*.tsx
app/components/wallet/Providers.tsx                   # add <ArcoraDexProvider>
.github/workflows/app.yml                             # add packages/sdk to triggers
```

### Removed (T12)
```
app/lib/abi/pool.ts
app/lib/abi/registry.ts
app/lib/abi/lp.ts
app/lib/abi/erc20.ts
app/lib/contracts.ts
app/lib/format.ts
app/lib/slippage.ts
app/lib/hooks/useTokens.ts
app/lib/__tests__/format.test.ts
app/lib/__tests__/slippage.test.ts
```

---

## Naming Conventions (locked)

- **Package name:** `@arcoralabs/dex-sdk`
- **Factory:** `createArcoraDex(opts) → ArcoraDexClient`
- **Default export from `src/index.ts`:** `createArcoraDex`, `arcTestnet`, all utility functions (`fmtUnits`, `minOut`, etc.), all error classes, all action functions, `KNOWN_TOKENS`, `tokenLabel`
- **Default export from `src/react/index.ts`:** `ArcoraDexProvider`, `useArcoraDex`, plus every hook listed above
- **Action signatures:** every action function takes `(client, args)` shape internally; the client wraps to the `(args)` shape externally
- **Error classes:** `ArcoraDexError` base; `MissingAccountError`, `InsufficientBalanceError`, `InsufficientLiquidityError`, `FirstDepositTooSmallError`, `SlippageExceededError`, `OracleStaleError`, `OracleDeviationError`, `PoolPausedError`, `TokenNotActiveError`, `DeadlinePassedError`
- **Result types:** `SwapResult`, `DepositResult`, `WithdrawResult` (all carry `hash`, `receipt`, `event`; swap/deposit additionally carry optional `approveHash`, plus their amount field)

---

## Tasks

### Task 1: Convert repo to pnpm workspace + scaffold `packages/sdk/`

**Files:**
- Create: `pnpm-workspace.yaml`
- Create: `package.json` (root)
- Create: `packages/sdk/package.json`
- Create: `packages/sdk/tsconfig.json`
- Create: `packages/sdk/tsconfig.build.json`
- Create: `packages/sdk/tsup.config.ts`
- Create: `packages/sdk/vitest.config.ts`
- Create: `packages/sdk/README.md`
- Create: `packages/sdk/src/index.ts` (empty barrel)
- Create: `packages/sdk/src/react/index.ts` (empty barrel)
- Modify: `app/package.json` (add SDK dep)
- Modify: `.gitignore` (add `packages/*/dist`, `packages/*/node_modules`, `packages/*/.tsbuildinfo`)

- [ ] **Step 1: Create `pnpm-workspace.yaml`**

```yaml
packages:
  - app
  - packages/*
```

- [ ] **Step 2: Create root `package.json`**

```json
{
  "name": "arcoradex-monorepo",
  "private": true,
  "version": "0.0.0",
  "scripts": {
    "build": "pnpm -r build",
    "test": "pnpm -r test",
    "typecheck": "pnpm -r typecheck",
    "lint": "pnpm -r lint",
    "dev": "pnpm --filter app dev"
  },
  "engines": { "node": ">=22", "pnpm": ">=10" }
}
```

- [ ] **Step 3: Create `packages/sdk/package.json`**

```json
{
  "name": "@arcoralabs/dex-sdk",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "license": "MIT",
  "exports": {
    ".":      { "types": "./src/index.ts",       "default": "./src/index.ts" },
    "./react":{ "types": "./src/react/index.ts", "default": "./src/react/index.ts" }
  },
  "files": ["dist", "src", "README.md"],
  "scripts": {
    "build":     "tsup",
    "test":      "vitest run",
    "typecheck": "tsc --noEmit",
    "lint":      "eslint src test"
  },
  "peerDependencies": {
    "viem": "^2.20.0",
    "wagmi": "^2.14.0",
    "@tanstack/react-query": "^5.0.0",
    "react": "^18.0.0 || ^19.0.0"
  },
  "peerDependenciesMeta": {
    "wagmi":   { "optional": true },
    "@tanstack/react-query": { "optional": true },
    "react":   { "optional": true }
  },
  "devDependencies": {
    "@types/node": "^20",
    "@types/react": "^19",
    "@types/react-dom": "^19",
    "@testing-library/react": "^16.1.0",
    "@testing-library/jest-dom": "^6.6.3",
    "@vitest/ui": "^2.1.8",
    "happy-dom": "^15.11.7",
    "tsup": "^8.3.5",
    "typescript": "^5.7.0",
    "vitest": "^2.1.8",
    "eslint": "^9",
    "@typescript-eslint/parser": "^8.18.0",
    "@typescript-eslint/eslint-plugin": "^8.18.0",
    "viem": "^2.20.0",
    "wagmi": "^2.14.0",
    "@tanstack/react-query": "^5.62.0",
    "react": "19.2.4",
    "react-dom": "19.2.4"
  }
}
```

- [ ] **Step 4: Create `packages/sdk/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["DOM", "DOM.Iterable", "ES2022"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noEmit": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "isolatedModules": true,
    "jsx": "react-jsx",
    "declaration": true,
    "paths": { "@/*": ["./src/*"] }
  },
  "include": ["src/**/*", "test/**/*"],
  "exclude": ["dist", "node_modules"]
}
```

- [ ] **Step 5: Create `packages/sdk/tsconfig.build.json`**

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "noEmit": false,
    "outDir": "dist",
    "declaration": true,
    "emitDeclarationOnly": false
  },
  "include": ["src/**/*"],
  "exclude": ["test", "dist", "node_modules"]
}
```

- [ ] **Step 6: Create `packages/sdk/tsup.config.ts`**

```ts
import { defineConfig } from "tsup";

export default defineConfig({
  entry: { index: "src/index.ts", react: "src/react/index.ts" },
  format: ["esm"],
  dts: true,
  splitting: true,
  treeshake: true,
  sourcemap: true,
  clean: true,
  external: ["react", "react-dom", "wagmi", "viem", "@tanstack/react-query"],
});
```

- [ ] **Step 7: Create `packages/sdk/vitest.config.ts`**

```ts
import { defineConfig } from "vitest/config";
import path from "node:path";

export default defineConfig({
  test: {
    environment: "node",
    setupFiles: [],
    include: [
      "test/unit/**/*.test.ts",
      "test/integration/**/*.test.ts",
      "test/react/**/*.test.tsx",
    ],
    testTimeout: 60_000,
    globalSetup: ["./test/setup.ts"],
    pool: "forks",
    poolOptions: { forks: { singleFork: true } },
    environmentMatchGlobs: [
      ["test/react/**", "happy-dom"],
    ],
  },
  resolve: {
    alias: { "@": path.resolve(__dirname, "src") },
  },
});
```

- [ ] **Step 8: Create empty barrels**

`packages/sdk/src/index.ts`:
```ts
export {};
```

`packages/sdk/src/react/index.ts`:
```ts
export {};
```

- [ ] **Step 9: Create `packages/sdk/README.md`**

```markdown
# @arcoralabs/dex-sdk

TypeScript SDK for [ArcoraDEX](https://swap.arcorapay.xyz). Framework-agnostic core + React hooks.

> **Phase B v0.1** — workspace-only. Will be published to NPM at v1.0 after the spec §10 trigger (30 days stable on testnet, or external integration demand).

## Usage

```ts
import { createArcoraDex, arcTestnet } from "@arcoralabs/dex-sdk";
import { http } from "viem";

const sdk = createArcoraDex({ chain: arcTestnet, transport: http() });
const out = await sdk.quoteSwap({ tokenIn, tokenOut, amountIn });
```

See `docs/superpowers/specs/2026-05-06-sdk-phase-b-design.md` in the repo for the full API.

## License

MIT
```

- [ ] **Step 10: Modify `app/package.json` to depend on the workspace SDK**

In the `dependencies` section of `app/package.json`, add (alphabetically):

```json
"@arcoralabs/dex-sdk": "workspace:*",
```

- [ ] **Step 11: Append SDK ignores to root `.gitignore`**

Open `.gitignore` and append:

```
# SDK package
packages/*/node_modules/
packages/*/dist/
packages/*/.tsbuildinfo
packages/*/coverage/
```

- [ ] **Step 12: Install + verify**

```bash
pnpm install
```

Expected: pnpm reports 2 workspace projects (`app`, `@arcoralabs/dex-sdk`); `app/node_modules/@arcoralabs/dex-sdk` is a symlink to `../../packages/sdk`.

```bash
ls -la app/node_modules/@arcoralabs/dex-sdk
```

Expected: shows symlink to `../../packages/sdk`.

```bash
pnpm -r typecheck
```

Expected: both packages pass typecheck. SDK has no source yet, so just exports `{}`.

- [ ] **Step 13: Commit**

```bash
git add pnpm-workspace.yaml package.json packages/sdk/ app/package.json app/pnpm-lock.yaml pnpm-lock.yaml .gitignore
git status --short
git commit -m "$(cat <<'EOF'
feat(workspace): convert to pnpm monorepo + scaffold @arcoralabs/dex-sdk skeleton

Sets up packages/sdk/ with package.json, tsconfig (ES2022 + strict +
noUncheckedIndexedAccess), tsup (ESM-only, dual entrypoint .+./react),
vitest (forks pool, happy-dom for /react tests), and empty barrel
exports. Source-direct dev: app/ workspace-deps via "workspace:*" so
no build step is needed during iteration.

T1 of docs/superpowers/plans/2026-05-06-sdk-phase-b.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: SDK ESLint flat config

**Files:**
- Create: `packages/sdk/eslint.config.mjs`

- [ ] **Step 1: Create the config**

```js
import tsParser from "@typescript-eslint/parser";
import tsPlugin from "@typescript-eslint/eslint-plugin";

export default [
  {
    files: ["src/**/*.{ts,tsx}", "test/**/*.{ts,tsx}"],
    languageOptions: {
      parser: tsParser,
      parserOptions: { project: "./tsconfig.json" },
      ecmaVersion: 2022,
      sourceType: "module",
    },
    plugins: { "@typescript-eslint": tsPlugin },
    rules: {
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/consistent-type-exports": "error",
      "@typescript-eslint/consistent-type-imports": ["error", { prefer: "type-imports" }],
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
      "prefer-const": "error",
      "no-console": "warn",
    },
  },
];
```

- [ ] **Step 2: Run lint to verify config loads**

```bash
pnpm --filter @arcoralabs/dex-sdk lint
```

Expected: passes (no source files yet beyond empty barrels). If ESLint complains about parser project, ensure `tsconfig.json` exists (it does from T1).

- [ ] **Step 3: Commit**

```bash
git add packages/sdk/eslint.config.mjs
git commit -m "$(cat <<'EOF'
chore(sdk): add strict ESLint flat config

Library code holds itself to higher type discipline than UI: no-explicit-any
error, consistent-type-imports/exports error, no-unused-vars (allow _-prefix).

T2 of docs/superpowers/plans/2026-05-06-sdk-phase-b.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Format + slippage + errors helpers (TDD)

**Files:**
- Create: `packages/sdk/src/format/index.ts`
- Create: `packages/sdk/src/slippage/index.ts`
- Create: `packages/sdk/src/errors.ts`
- Create: `packages/sdk/test/unit/format.test.ts`
- Create: `packages/sdk/test/unit/slippage.test.ts`
- Create: `packages/sdk/test/unit/errors.test.ts`

- [ ] **Step 1: Write failing format tests**

`packages/sdk/test/unit/format.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { fmtUnits, fmtUSD, tryParseUnits } from "@/format";

describe("fmtUnits", () => {
  it("formats USDC with 6 decimals", () => {
    expect(fmtUnits(1_000_000n, 6)).toBe("1");
    expect(fmtUnits(1_500_000n, 6)).toBe("1.5");
    expect(fmtUnits(123_456_789n, 6)).toBe("123.4567");
  });
  it("formats DAI with 18 decimals", () => {
    expect(fmtUnits(10n ** 18n, 18)).toBe("1");
    expect(fmtUnits(15n * 10n ** 17n, 18)).toBe("1.5");
  });
  it("respects displayDecimals and trims trailing zeros", () => {
    expect(fmtUnits(1_500_000n, 6, 6)).toBe("1.5");
  });
});

describe("fmtUSD", () => {
  it("formats 1e18 as $1.00", () => {
    expect(fmtUSD(10n ** 18n)).toBe("$1.00");
  });
  it("formats 70_000e18 with thousands separators", () => {
    expect(fmtUSD(70_000n * 10n ** 18n)).toBe("$70,000.00");
  });
});

describe("tryParseUnits", () => {
  it("parses valid input", () => {
    expect(tryParseUnits("1.5", 6)).toBe(1_500_000n);
    expect(tryParseUnits("100", 18)).toBe(100n * 10n ** 18n);
  });
  it("returns null for empty / invalid", () => {
    expect(tryParseUnits("", 6)).toBe(null);
    expect(tryParseUnits(".", 6)).toBe(null);
    expect(tryParseUnits("abc", 6)).toBe(null);
  });
});
```

- [ ] **Step 2: Write failing slippage tests**

`packages/sdk/test/unit/slippage.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { minOut, deadline } from "@/slippage";

describe("minOut", () => {
  it("returns the quoted amount when slippage is 0", () => {
    expect(minOut(1_000_000n, 0)).toBe(1_000_000n);
  });
  it("applies 0.5% slippage (50 bps)", () => {
    expect(minOut(1_000_000n, 50)).toBe(995_000n);
  });
  it("applies 1% slippage (100 bps)", () => {
    expect(minOut(1_000_000n, 100)).toBe(990_000n);
  });
  it("returns 0 when slippage >= 10000 bps", () => {
    expect(minOut(1_000_000n, 10_000)).toBe(0n);
    expect(minOut(1_000_000n, 99_999)).toBe(0n);
  });
  it("rounds toward zero (BigInt integer division)", () => {
    // 12345 * 9990 = 123_326_550 → /10_000 = 12_332
    expect(minOut(12_345n, 10)).toBe(12_332n);
  });
});

describe("deadline", () => {
  it("defaults to 20 minutes from now", () => {
    const d = deadline();
    const now = Math.floor(Date.now() / 1000);
    const window = Number(d) - now;
    expect(window).toBeGreaterThanOrEqual(20 * 60 - 2);
    expect(window).toBeLessThanOrEqual(20 * 60 + 2);
  });
  it("accepts a custom horizon", () => {
    const d = deadline(60);
    const now = Math.floor(Date.now() / 1000);
    expect(Number(d) - now).toBeGreaterThanOrEqual(58);
    expect(Number(d) - now).toBeLessThanOrEqual(62);
  });
});
```

- [ ] **Step 3: Write failing error tests**

`packages/sdk/test/unit/errors.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { encodeErrorResult, toFunctionSelector } from "viem";
import {
  ArcoraDexError,
  SlippageExceededError,
  InsufficientLiquidityError,
  PoolPausedError,
  parseContractError,
} from "@/errors";

const slippageAbi = {
  type: "error",
  name: "InsufficientOutput",
  inputs: [
    { name: "actual", type: "uint256" },
    { name: "minOut", type: "uint256" },
  ],
} as const;

describe("ArcoraDexError hierarchy", () => {
  it("SlippageExceededError exposes typed fields", () => {
    const e = new SlippageExceededError({ actual: 100n, minOut: 200n });
    expect(e).toBeInstanceOf(ArcoraDexError);
    expect(e.actual).toBe(100n);
    expect(e.minOut).toBe(200n);
    expect(e.message).toContain("slippage");
  });
  it("PoolPausedError has no extra fields", () => {
    const e = new PoolPausedError();
    expect(e).toBeInstanceOf(ArcoraDexError);
    expect(e.message).toContain("paused");
  });
});

describe("parseContractError", () => {
  it("decodes a viem ContractFunctionRevertedError into the typed class", () => {
    // Synthetic error: viem's ContractFunctionRevertedError exposes .data with selector + args
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: {
        errorName: "InsufficientOutput",
        args: [100n, 200n],
      },
    };
    const out = parseContractError(fakeViemErr);
    expect(out).toBeInstanceOf(SlippageExceededError);
    if (out instanceof SlippageExceededError) {
      expect(out.actual).toBe(100n);
      expect(out.minOut).toBe(200n);
    }
  });

  it("falls back to ArcoraDexError for unknown selectors", () => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "UnknownErrorSig", args: [] },
    };
    const out = parseContractError(fakeViemErr);
    expect(out).toBeInstanceOf(ArcoraDexError);
    expect(out).not.toBeInstanceOf(SlippageExceededError);
  });

  it("recognizes PoolPaused with no args", () => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "PoolPaused", args: [] },
    };
    expect(parseContractError(fakeViemErr)).toBeInstanceOf(PoolPausedError);
  });

  it("recognizes InsufficientLiquidity with named fields", () => {
    const fakeViemErr = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "InsufficientLiquidity", args: ["0xabc", 5n, 1n] },
    };
    const out = parseContractError(fakeViemErr);
    expect(out).toBeInstanceOf(InsufficientLiquidityError);
    if (out instanceof InsufficientLiquidityError) {
      expect(out.token).toBe("0xabc");
      expect(out.requested).toBe(5n);
      expect(out.available).toBe(1n);
    }
  });
});
```

- [ ] **Step 4: Run tests; verify they fail (no source yet)**

```bash
pnpm --filter @arcoralabs/dex-sdk test
```

Expected: vitest fails because `@/format`, `@/slippage`, `@/errors` resolve nothing.

- [ ] **Step 5: Implement `format/index.ts`**

```ts
import { formatUnits, parseUnits } from "viem";

export function fmtUnits(value: bigint, decimals: number, displayDecimals = 4): string {
  const s = formatUnits(value, decimals);
  const [intP, fracP = ""] = s.split(".");
  if (!fracP) return intP ?? "0";
  const trimmed = fracP.slice(0, displayDecimals).replace(/0+$/, "");
  return trimmed.length ? `${intP}.${trimmed}` : (intP ?? "0");
}

export function fmtUSD(value1e18: bigint, displayDecimals = 2): string {
  const s = formatUnits(value1e18, 18);
  const [intP = "0", fracP = ""] = s.split(".");
  const trimmed = fracP.slice(0, displayDecimals).padEnd(displayDecimals, "0");
  const intWithCommas = intP.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `$${intWithCommas}.${trimmed}`;
}

export function tryParseUnits(value: string, decimals: number): bigint | null {
  if (!value || value === "." || isNaN(Number(value))) return null;
  try {
    return parseUnits(value as `${number}`, decimals);
  } catch {
    return null;
  }
}
```

- [ ] **Step 6: Implement `slippage/index.ts`**

```ts
export function minOut(quoted: bigint, slippageBps: number): bigint {
  if (slippageBps <= 0) return quoted;
  if (slippageBps >= 10_000) return 0n;
  return (quoted * BigInt(10_000 - slippageBps)) / 10_000n;
}

export function deadline(secondsFromNow = 20 * 60): bigint {
  return BigInt(Math.floor(Date.now() / 1000) + secondsFromNow);
}
```

- [ ] **Step 7: Implement `errors.ts`**

```ts
export class ArcoraDexError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ArcoraDexError";
  }
}

export class MissingAccountError extends ArcoraDexError {
  constructor() {
    super("Missing account: this method requires a viem account on the SDK client.");
    this.name = "MissingAccountError";
  }
}

export class InsufficientBalanceError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`, public readonly balance: bigint, public readonly required: bigint) {
    super(`Insufficient balance of ${token}: have ${balance}, need ${required}`);
    this.name = "InsufficientBalanceError";
  }
}

export class InsufficientLiquidityError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`, public readonly requested: bigint, public readonly available: bigint) {
    super(`Insufficient pool liquidity for ${token}: requested ${requested}, available ${available}`);
    this.name = "InsufficientLiquidityError";
  }
}

export class FirstDepositTooSmallError extends ArcoraDexError {
  constructor(public readonly usd: bigint, public readonly minimum: bigint) {
    super(`First deposit too small: ${usd} <= MINIMUM_LIQUIDITY (${minimum})`);
    this.name = "FirstDepositTooSmallError";
  }
}

export class SlippageExceededError extends ArcoraDexError {
  constructor(public readonly actual: bigint, public readonly minOut: bigint) {
    super(`slippage: actual ${actual} below minOut ${minOut}`);
    this.name = "SlippageExceededError";
  }
}

export class OracleStaleError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`) {
    super(`Oracle for ${token} is stale (>1h)`);
    this.name = "OracleStaleError";
  }
}

export class OracleDeviationError extends ArcoraDexError {
  constructor(
    public readonly token: `0x${string}`,
    public readonly newPrice: bigint,
    public readonly prev: bigint,
    public readonly maxDevBps: number,
  ) {
    super(`Oracle deviation for ${token}: ${newPrice} vs prev ${prev} exceeds ${maxDevBps} bps`);
    this.name = "OracleDeviationError";
  }
}

export class PoolPausedError extends ArcoraDexError {
  constructor() {
    super("Pool is paused.");
    this.name = "PoolPausedError";
  }
}

export class TokenNotActiveError extends ArcoraDexError {
  constructor(public readonly token: `0x${string}`) {
    super(`Token ${token} is not active in the registry.`);
    this.name = "TokenNotActiveError";
  }
}

export class DeadlinePassedError extends ArcoraDexError {
  constructor() {
    super("Transaction deadline already passed.");
    this.name = "DeadlinePassedError";
  }
}

interface RevertedShape {
  data?: { errorName?: string; args?: readonly unknown[] };
}

export function parseContractError(err: unknown): ArcoraDexError {
  const r = err as RevertedShape;
  const name = r?.data?.errorName;
  const args = (r?.data?.args ?? []) as readonly unknown[];

  switch (name) {
    case "InsufficientOutput":
    case "InsufficientLpOut":
    case "InsufficientTokenOut":
      return new SlippageExceededError(args[0] as bigint, args[1] as bigint);
    case "InsufficientLiquidity":
      return new InsufficientLiquidityError(args[0] as `0x${string}`, args[1] as bigint, args[2] as bigint);
    case "FirstDepositTooSmall":
      return new FirstDepositTooSmallError(args[0] as bigint, args[1] as bigint);
    case "PoolPaused":
      return new PoolPausedError();
    case "TokenNotActive":
      return new TokenNotActiveError(args[0] as `0x${string}`);
    case "DeadlinePassed":
      return new DeadlinePassedError();
    case "PriceDeviation":
      return new OracleDeviationError(
        args[0] as `0x${string}`,
        args[1] as bigint,
        args[2] as bigint,
        Number(args[3]),
      );
    default:
      return new ArcoraDexError(`Contract reverted: ${name ?? "unknown"}`);
  }
}
```

- [ ] **Step 8: Re-run tests; verify pass**

```bash
pnpm --filter @arcoralabs/dex-sdk test
```

Expected: all unit tests pass (~15 across the three files).

- [ ] **Step 9: Commit**

```bash
git add packages/sdk/src/format packages/sdk/src/slippage packages/sdk/src/errors.ts packages/sdk/test/unit
git commit -m "$(cat <<'EOF'
feat(sdk): format/slippage helpers + typed error hierarchy + parseContractError

format: fmtUnits, fmtUSD, tryParseUnits (carries forward app/lib/format).
slippage: minOut, deadline (carries forward app/lib/slippage).
errors: ArcoraDexError base + 9 typed subclasses;
parseContractError() decodes viem ContractFunctionRevertedError into the
matched class via errorName lookup; unknown reverts return generic
ArcoraDexError. ~15 unit tests cover format, slippage, error decoding.

T3 of docs/superpowers/plans/2026-05-06-sdk-phase-b.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: ABI + addresses + tokens + chain definition (TDD)

**Files:**
- Create: `packages/sdk/src/abi/pool.ts`
- Create: `packages/sdk/src/abi/registry.ts`
- Create: `packages/sdk/src/abi/lp.ts`
- Create: `packages/sdk/src/abi/erc20.ts`
- Create: `packages/sdk/src/addresses.ts`
- Create: `packages/sdk/src/chains/arcTestnet.ts`
- Create: `packages/sdk/src/tokens/known.ts`
- Create: `packages/sdk/src/tokens/label.ts`
- Create: `packages/sdk/test/unit/tokens.test.ts`

- [ ] **Step 1: Write failing token tests**

`packages/sdk/test/unit/tokens.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { tokenLabel } from "@/tokens/label";

const USDC = "0x3BFa09fF6467639f0981948385bA1018Ac07d22C";

describe("tokenLabel", () => {
  it("returns metadata for a known checksummed address", () => {
    expect(tokenLabel(USDC)).toEqual({ symbol: "USDC", name: "USD Coin" });
  });
  it("returns metadata for a lowercased address", () => {
    expect(tokenLabel(USDC.toLowerCase() as `0x${string}`)).toEqual({ symbol: "USDC", name: "USD Coin" });
  });
  it("returns metadata for a UPPERCASED address (post-getAddress normalization)", () => {
    expect(tokenLabel(USDC.toUpperCase() as `0x${string}`)).toEqual({ symbol: "USDC", name: "USD Coin" });
  });
  it("falls back to a synthetic symbol for unknown addresses", () => {
    const unknown = "0x1111111111111111111111111111111111111111" as const;
    const m = tokenLabel(unknown);
    expect(m.symbol.length).toBeGreaterThan(0);
    expect(m.name).toBe(unknown);
  });
});
```

- [ ] **Step 2: Run tests; verify they fail**

```bash
pnpm --filter @arcoralabs/dex-sdk test
```

Expected: `tokens.test.ts` fails — `@/tokens/label` not found.

- [ ] **Step 3: Implement `chains/arcTestnet.ts`**

```ts
import { defineChain } from "viem";

export const arcTestnet = /*#__PURE__*/ defineChain({
  id: 5042002,
  name: "Arc Testnet",
  nativeCurrency: { name: "USD Coin", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.testnet.arc.network"] } },
  blockExplorers: {
    default: { name: "Arc Explorer", url: "https://testnet.arcscan.app" },
  },
  testnet: true,
});
```

- [ ] **Step 4: Implement `addresses.ts`**

```ts
import { arcTestnet } from "./chains/arcTestnet";

export interface ArcoraDexAddresses {
  pool:     `0x${string}`;
  registry: `0x${string}`;
  lp:       `0x${string}`;
}

/** v1.0-testnet addresses, recorded in docs/rollouts/2026-05-06-arcoradex-deploy.md. */
const ARC_TESTNET_V1: ArcoraDexAddresses = {
  registry: "0x920E3E59DD37Be3D9D3750D7B912A9dd08db0D29",
  pool:     "0x3051d24D771bAF44031571544a9159578035D0c5",
  lp:       "0x7CEAbF411806A29ffaEbCAB2BF3Dc8a9ECBD110C",
};

export const DEFAULT_ADDRESSES: Record<number, ArcoraDexAddresses> = {
  [arcTestnet.id]: ARC_TESTNET_V1,
};
```

- [ ] **Step 5: Implement `tokens/known.ts`**

```ts
export interface KnownTokenMeta {
  symbol: string;
  name: string;
}

/** Checksummed v1.0-testnet token addresses → human metadata. */
export const KNOWN_TOKENS: Record<`0x${string}`, KnownTokenMeta> = {
  "0x3BFa09fF6467639f0981948385bA1018Ac07d22C": { symbol: "USDC", name: "USD Coin" },
  "0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B": { symbol: "USDT", name: "Tether USD" },
  "0xfdB2c86d010698401f0b969348DC58b6659B96a3": { symbol: "PYUSD", name: "PayPal USD" },
  "0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE": { symbol: "DAI", name: "Dai" },
  "0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD": { symbol: "EURC", name: "Euro Coin" },
  "0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61": { symbol: "TRYC", name: "Turkish Lira Coin" },
  "0xa13c0935A98e2c175b31A4054f698819271a8FfC": { symbol: "BRLC", name: "Brazilian Real Coin" },
};
```

- [ ] **Step 6: Implement `tokens/label.ts`**

```ts
import { getAddress } from "viem";
import { KNOWN_TOKENS, type KnownTokenMeta } from "./known";

export function tokenLabel(address: `0x${string}`): KnownTokenMeta {
  let key: `0x${string}`;
  try {
    key = getAddress(address);
  } catch {
    return { symbol: address.slice(2, 6).toUpperCase(), name: address };
  }
  return KNOWN_TOKENS[key] ?? { symbol: key.slice(2, 6).toUpperCase(), name: key };
}
```

- [ ] **Step 7: Implement the four ABI files**

`packages/sdk/src/abi/pool.ts`:
```ts
import { parseAbi } from "viem";

export const poolAbi = parseAbi([
  "function deposit(address token, uint256 amount, uint256 minLpOut, uint256 deadline) returns (uint256)",
  "function withdraw(address tokenOut, uint256 lpAmount, uint256 minTokenOut, uint256 deadline) returns (uint256)",
  "function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline, address recipient) returns (uint256)",
  "function quote(address tokenIn, address tokenOut, uint256 amountIn) view returns (uint256)",
  "function quoteDeposit(address token, uint256 amount) view returns (uint256)",
  "function quoteWithdraw(address tokenOut, uint256 lpAmount) view returns (uint256, uint256)",
  "function reserves(address) view returns (uint256)",
  "function protocolFeesAccrued(address) view returns (uint256)",
  "function totalReservesUSD() view returns (uint256)",
  "function swapFeeBps() view returns (uint16)",
  "function protocolFeeShareBps() view returns (uint16)",
  "function paused() view returns (bool)",
  "function LP() view returns (address)",
  "function REGISTRY() view returns (address)",
  "event Swapped(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 lpFeeUsd1e18, uint256 protocolFeeAmtOut, address recipient)",
  "event Deposited(address indexed user, address indexed token, uint256 amountIn, uint256 lpMinted, uint256 navBefore1e18, uint256 navAfter1e18)",
  "event Withdrew(address indexed user, address indexed tokenOut, uint256 lpBurned, uint256 amountOut, uint256 protocolFee, uint256 navBefore1e18, uint256 navAfter1e18)",
]);
```

`packages/sdk/src/abi/registry.ts`:
```ts
import { parseAbi } from "viem";

export const registryAbi = parseAbi([
  "struct TokenInfo { uint8 decimals; bool isActive; address usdOracle; uint16 maxOracleDeviationBps; }",
  "function tokens(uint256 i) view returns (address)",
  "function tokensLength() view returns (uint256)",
  "function tokenInfo(address token) view returns (TokenInfo)",
  "function isActive(address token) view returns (bool)",
]);
```

`packages/sdk/src/abi/lp.ts`:
```ts
import { parseAbi } from "viem";

export const lpAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
]);
```

`packages/sdk/src/abi/erc20.ts`:
```ts
import { parseAbi } from "viem";

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);
```

- [ ] **Step 8: Re-run tests; verify pass**

```bash
pnpm --filter @arcoralabs/dex-sdk test
```

Expected: all unit tests pass (T3's 15 + T4's 4 = ~19).

- [ ] **Step 9: Commit**

```bash
git add packages/sdk/src/abi packages/sdk/src/addresses.ts packages/sdk/src/chains packages/sdk/src/tokens packages/sdk/test/unit/tokens.test.ts
git commit -m "$(cat <<'EOF'
feat(sdk): ABI + addresses + chain + token metadata

Adds parseAbi blocks (pool, registry, lp, erc20), the v1.0-testnet
ArcoraDexAddresses default keyed by arcTestnet.id, the arcTestnet viem
Chain definition (USDC native gas token at 18 dec wrap), KNOWN_TOKENS
checksummed lookup for the seven listed stables, and tokenLabel() that
normalizes input via viem getAddress before the map lookup.

T4 of docs/superpowers/plans/2026-05-06-sdk-phase-b.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

[**Plan continues with T5–T13 in a follow-up file.**]

The remaining nine tasks (T5: factory + read actions; T6: write actions with auto-approve; T7: integration error coverage; T8: subscriptions; T9: build + barrel finalize; T10: read hooks + provider; T11: write hooks + history; T12: app migration; T13: deploy + tag) follow the same TDD pattern: failing test → minimal implementation → green test → commit. Each task averages 7–10 steps and produces a single commit with all-green typecheck/test/lint at the relevant scope.

To keep this file readable and reviewable, T5–T13 are written separately and linked from this plan. See:
- `docs/superpowers/plans/2026-05-06-sdk-phase-b-tasks-5-9.md` (core SDK)
- `docs/superpowers/plans/2026-05-06-sdk-phase-b-tasks-10-13.md` (React layer + frontend migration + deploy)

---

## Definition of Done

- ✅ `pnpm -r typecheck && pnpm -r lint && pnpm -r test && pnpm -r build` green at repo root
- ✅ `app/lib/` contains only `wagmi.ts` and `utils.ts`
- ✅ `swap.arcorapay.xyz` round-trip smoke clean (swap, deposit, withdraw)
- ✅ ~65 SDK tests green (~20 unit + ~30 integration + ~15 react)
- ✅ `sdk-v0.1.0` tag pushed to origin
- ✅ Spec, plan (this file + the two task continuations), and final review captured under `docs/superpowers/`
