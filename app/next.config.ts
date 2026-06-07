import type { NextConfig } from "next";
import { withBotId } from "botid/next/config";
import path from "node:path";

const nextConfig: NextConfig = {
  // This app is one package of a pnpm workspace. Next/Turbopack infers the
  // "workspace root" from the nearest lockfile, and with the per-package
  // app/pnpm-lock.yaml removed it would otherwise walk past the repo and pick a
  // stray lockfile higher in the filesystem (e.g. ~/package-lock.json). A wrong
  // root changes module resolution and forks wagmi into two WagmiContexts,
  // breaking the /_not-found static prerender. Pin the root to the monorepo
  // (one level up from app/) so resolution is deterministic locally and on
  // Vercel. import.meta.dirname is app/, so its parent is the repo root.
  turbopack: {
    root: path.join(import.meta.dirname, ".."),
  },
};

// Vercel BotID requires the Next config to be wrapped so it can install the
// first-party proxy/rewrites that serve the BotID challenge script and route
// verification. Without this wrapper the <BotIdClient> signal collection and
// the server-side checkBotId() in /api/faucet are degraded — the faucet's
// bot-abuse protection only fully engages once the config is wrapped.
export default withBotId(nextConfig);
