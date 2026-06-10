import { defineConfig } from "tsup";

export default defineConfig({
  entry: {
    index: "src/index.ts",
    v2: "src/v2.ts",
    react: "src/react/index.ts",
    "react/v2": "src/react/v2/index.ts",
  },
  format: ["esm"],
  dts: true,
  splitting: true,
  treeshake: true,
  sourcemap: true,
  clean: true,
  external: ["react", "react-dom", "wagmi", "viem", "@tanstack/react-query"],
});
