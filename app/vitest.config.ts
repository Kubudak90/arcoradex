import { defineConfig } from "vitest/config";
import path from "node:path";

// All non-trivial logic moved into @arcoralabs/dex-sdk; this app currently
// has no Vitest specs. The config remains so `pnpm -r test` and contributors
// can drop new specs under `lib/__tests__/` without re-adding boilerplate.
export default defineConfig({
  test: {
    environment: "node",
    include: ["lib/__tests__/**/*.test.ts"],
    passWithNoTests: true,
  },
  resolve: {
    alias: { "@": path.resolve(__dirname, ".") },
  },
});
