// Shared keeper helpers — pure logic + small network/tx hardening utilities.
//
// The PURE functions in this file (band/peg/drift decisions, the per-tick
// maxDevBps ratchet) carry NO network dependency so they can be unit-tested with
// `node --test` without hitting an RPC, Vault, or CoinGecko.
//
// The network/tx helpers (fetchJson with AbortController timeout, buildTransport
// with fallback RPCs, gas-ceiling resolution) are also kept here so both
// multi-feed-push.mjs and guard-record.mjs share one hardened path (L-3 fetch
// timeouts, L-4 gas ceiling / nonce / confirmation timeout / fallback RPC /
// balance check).

import { http, fallback } from "viem";

// ---------------------------------------------------------------------------
// Constants / env-tunable defaults (L-4)
// ---------------------------------------------------------------------------

// Per-request fetch timeout (CoinGecko / FX upstreams). Env: KEEPER_FETCH_TIMEOUT_MS.
export const DEFAULT_FETCH_TIMEOUT_MS = 12_000;

// waitForTransactionReceipt wall-clock timeout. Env: KEEPER_TX_TIMEOUT_MS.
export const DEFAULT_TX_TIMEOUT_MS = 90_000;

// Per-tx fee ceiling (gwei). The keeper will NEVER sign a tx whose maxFeePerGas
// exceeds this, capping the damage an RPC misbehaving on fee suggestion can do.
// Env: KEEPER_MAX_FEE_GWEI / KEEPER_MAX_PRIORITY_GWEI.
export const DEFAULT_MAX_FEE_GWEI = 50;
export const DEFAULT_MAX_PRIORITY_GWEI = 2;

// Startup balance floor (in ARC / ether units). Below this the keeper warns;
// below the abort floor it exits non-zero before signing anything.
// Env: KEEPER_MIN_BALANCE_ETHER / KEEPER_ABORT_BALANCE_ETHER.
export const DEFAULT_MIN_BALANCE_ETHER = 0.05;
export const DEFAULT_ABORT_BALANCE_ETHER = 0.005;

// ---------------------------------------------------------------------------
// L-3: fetch with an AbortController timeout so a hung upstream surfaces as a
// per-batch error the existing handlers already log + skip (rather than blocking
// the whole oneshot until systemd's start-timeout SIGKILLs it).
// ---------------------------------------------------------------------------

/// Fetches a URL with an AbortController-backed timeout and parses JSON.
/// Throws on non-2xx, on a JSON parse failure, or on timeout (AbortError).
export async function fetchJson(url, { headers, timeoutMs = DEFAULT_FETCH_TIMEOUT_MS } = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
        const res = await fetch(url, { headers, signal: controller.signal });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return await res.json();
    } finally {
        clearTimeout(timer);
    }
}

// ---------------------------------------------------------------------------
// L-4: transport with fallback RPCs.
// ---------------------------------------------------------------------------

/// Parses the RPC env into an ordered list of endpoints. Accepts a
/// comma-separated ARC_TESTNET_RPC list plus an optional ARC_TESTNET_RPC_FALLBACK.
/// Dedupes while preserving order. `defaultRpc` is appended last as a backstop.
export function resolveRpcUrls({ primary, fallback: fallbackRpc, defaultRpc } = {}) {
    const list = [];
    const push = (v) => {
        if (!v) return;
        for (const part of String(v).split(",")) {
            const url = part.trim();
            if (url && !list.includes(url)) list.push(url);
        }
    };
    push(primary);
    push(fallbackRpc);
    push(defaultRpc);
    return list;
}

/// Builds a viem transport from a list of RPC URLs. A single URL uses a plain
/// http() transport; multiple URLs use viem's fallback() (auto-retry + failover).
export function buildTransport(urls) {
    if (!urls || urls.length === 0) {
        throw new Error("buildTransport: no RPC URLs resolved");
    }
    if (urls.length === 1) return http(urls[0]);
    return fallback(urls.map((u) => http(u)));
}

// ---------------------------------------------------------------------------
// L-4: gas-ceiling resolution (pure).
// ---------------------------------------------------------------------------

/// Resolves the per-tx fee ceiling from env (gwei) into wei BigInts. Returns
/// { maxFeePerGas, maxPriorityFeePerGas } suitable to spread into writeContract.
/// Pure: takes an env-like object so it is unit-testable.
export function resolveGasCeiling(env = {}) {
    const feeGwei = numEnv(env.KEEPER_MAX_FEE_GWEI, DEFAULT_MAX_FEE_GWEI);
    const prioGwei = numEnv(env.KEEPER_MAX_PRIORITY_GWEI, DEFAULT_MAX_PRIORITY_GWEI);
    // gwei may be fractional; scale to wei via 1e9 then round.
    const maxFeePerGas = BigInt(Math.round(feeGwei * 1e9));
    let maxPriorityFeePerGas = BigInt(Math.round(prioGwei * 1e9));
    // Priority fee can never exceed the max fee.
    if (maxPriorityFeePerGas > maxFeePerGas) maxPriorityFeePerGas = maxFeePerGas;
    return { maxFeePerGas, maxPriorityFeePerGas };
}

/// Coerces an env string to a positive finite number, falling back when unset
/// or invalid. Exported for reuse by the keeper scripts.
export function numEnv(raw, fallbackVal) {
    if (raw === undefined || raw === null || raw === "") return fallbackVal;
    const n = Number(raw);
    return Number.isFinite(n) && n > 0 ? n : fallbackVal;
}

// ---------------------------------------------------------------------------
// Pure price-sanity decision logic (band + peg-drift). Shared by the keeper and
// the unit tests. Returns a structured decision instead of logging/skipping so
// the caller controls side effects.
// ---------------------------------------------------------------------------

/// Decides whether a fetched USD value is acceptable for a feed given its band
/// and (optional) peg/maxPegDriftBps. Returns:
///   { ok: true }                                   — push allowed
///   { ok: false, reason: "no-value" }              — missing/non-numeric
///   { ok: false, reason: "out-of-band", ... }      — outside [min,max]
///   { ok: false, reason: "peg-drift", driftBps }   — drifts beyond maxPegDriftBps
export function decidePriceSanity(usd, feed) {
    if (typeof usd !== "number" || !Number.isFinite(usd)) {
        return { ok: false, reason: "no-value" };
    }
    if (usd < feed.band.min || usd > feed.band.max) {
        return { ok: false, reason: "out-of-band", band: feed.band, usd };
    }
    if (feed.peg !== null && feed.peg !== undefined && feed.peg > 0 &&
        feed.maxPegDriftBps !== null && feed.maxPegDriftBps !== undefined) {
        const driftBps = (Math.abs(usd - feed.peg) * 10_000) / feed.peg;
        if (driftBps > feed.maxPegDriftBps) {
            return { ok: false, reason: "peg-drift", driftBps, peg: feed.peg, maxPegDriftBps: feed.maxPegDriftBps };
        }
    }
    return { ok: true };
}

// ---------------------------------------------------------------------------
// Per-tick maxDevBps ratchet/clamp math (pure). Mirrors the registry's
// per-token maxOracleDeviationBps: caps |new - prev| ≤ prev × maxDevBps / 10000.
// Works in 1e8 BigInt fixed-point exactly like the on-chain answer.
// ---------------------------------------------------------------------------

/// Clamps `targetAnswer` to within `maxDevBps` of `prev` (all 1e8 BigInts).
/// Returns { newAnswer, capped }. When prev <= 0 there is no prior anchor, so
/// the target passes through uncapped.
export function clampToMaxDev(prev, targetAnswer, maxDevBps) {
    if (prev <= 0n) return { newAnswer: targetAnswer, capped: false };
    const maxDeltaAbs = (prev * BigInt(maxDevBps)) / 10_000n;
    const delta = targetAnswer > prev ? targetAnswer - prev : prev - targetAnswer;
    if (delta > maxDeltaAbs) {
        const newAnswer = targetAnswer > prev ? prev + maxDeltaAbs : prev - maxDeltaAbs;
        return { newAnswer, capped: true };
    }
    return { newAnswer: targetAnswer, capped: false };
}

/// Converts a USD float to the feed's 1e8 fixed-point BigInt.
export const priceTo1e8 = (usd) => BigInt(Math.round(usd * 1e8));
