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
