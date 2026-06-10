import { defineConfig } from "vitest/config";
import path from "node:path";

// App-level Vitest specs live under `lib/__tests__/`, route handlers under
// `app/api/**/__tests__/`, and the V2 §9 building-block specs under
// `components/**/__tests__/`. Most non-trivial protocol logic still lives in
// @arcoralabs/dex-sdk and is tested there; this config covers app-only modules
// (faucet rate-limit, faucet token list, the §9 Max-guard / health-band /
// dynamic-fee mapping) plus the faucet route handler.
// `passWithNoTests` left on so deleting a spec doesn't break CI.
export default defineConfig({
  test: {
    environment: "node",
    include: [
      "lib/__tests__/**/*.test.ts",
      "app/**/__tests__/**/*.test.ts",
      "components/**/__tests__/**/*.test.ts",
    ],
    passWithNoTests: true,
  },
  resolve: {
    alias: { "@": path.resolve(__dirname, ".") },
  },
});
