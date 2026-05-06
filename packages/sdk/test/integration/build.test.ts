import { describe, it, expect } from "vitest";
import { existsSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
// dist/ is two levels up from test/integration/
const distDir = join(__dirname, "..", "..", "dist");

describe("dist build artifacts", () => {
  it("emits index.js (main ESM bundle)", () => {
    const f = join(distDir, "index.js");
    expect(existsSync(f), `${f} missing — did you run pnpm build?`).toBe(true);
    expect(statSync(f).size).toBeGreaterThan(1_000);
  });

  it("emits index.d.ts (type declarations)", () => {
    const f = join(distDir, "index.d.ts");
    expect(existsSync(f), `${f} missing — did you run pnpm build?`).toBe(true);
    expect(statSync(f).size).toBeGreaterThan(500);
  });

  it("emits react.js (react sub-entry barrel)", () => {
    const f = join(distDir, "react.js");
    expect(existsSync(f), `${f} missing — did you run pnpm build?`).toBe(true);
  });

  it("emits react.d.ts (react type declarations)", () => {
    const f = join(distDir, "react.d.ts");
    expect(existsSync(f), `${f} missing — did you run pnpm build?`).toBe(true);
  });
});
