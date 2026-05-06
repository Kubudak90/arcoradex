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
