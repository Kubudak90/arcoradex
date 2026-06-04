import { defineConfig } from "vitest/config";
import path from "node:path";

// App-level Vitest specs live under `lib/__tests__/` and route handlers under
// `app/api/**/__tests__/`. Most non-trivial protocol logic still lives in
// @arcoralabs/dex-sdk and is tested there; this config covers app-only modules
// (faucet rate-limit, faucet token list) plus the faucet route handler.
// `passWithNoTests` left on so deleting a spec doesn't break CI.
export default defineConfig({
  test: {
    environment: "node",
    include: ["lib/__tests__/**/*.test.ts", "app/**/__tests__/**/*.test.ts"],
    passWithNoTests: true,
  },
  resolve: {
    alias: { "@": path.resolve(__dirname, ".") },
  },
});
