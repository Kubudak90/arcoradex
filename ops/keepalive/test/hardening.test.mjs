// Pure-helper unit tests for the L-3/L-4 liveness hardening helpers.
// Run: `node --test` (no network — fetchJson is exercised against a local
// throwaway HTTP server only for the timeout path).

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    resolveRpcUrls,
    resolveGasCeiling,
    numEnv,
    fetchJson,
    DEFAULT_MAX_FEE_GWEI,
} from "../lib.mjs";

test("resolveRpcUrls: single url", () => {
    assert.deepEqual(
        resolveRpcUrls({ primary: "https://a", defaultRpc: "https://a" }),
        ["https://a"],
    );
});

test("resolveRpcUrls: comma-separated list + fallback, deduped, ordered", () => {
    const urls = resolveRpcUrls({
        primary: "https://a, https://b",
        fallback: "https://b, https://c",
        defaultRpc: "https://d",
    });
    assert.deepEqual(urls, ["https://a", "https://b", "https://c", "https://d"]);
});

test("resolveRpcUrls: empty primary falls back to default", () => {
    assert.deepEqual(resolveRpcUrls({ defaultRpc: "https://d" }), ["https://d"]);
});

test("resolveGasCeiling: defaults to env-free ceiling in wei", () => {
    const g = resolveGasCeiling({});
    assert.equal(g.maxFeePerGas, BigInt(DEFAULT_MAX_FEE_GWEI) * 1_000_000_000n);
    assert.equal(g.maxPriorityFeePerGas, 2n * 1_000_000_000n);
});

test("resolveGasCeiling: env override", () => {
    const g = resolveGasCeiling({ KEEPER_MAX_FEE_GWEI: "30", KEEPER_MAX_PRIORITY_GWEI: "1" });
    assert.equal(g.maxFeePerGas, 30n * 1_000_000_000n);
    assert.equal(g.maxPriorityFeePerGas, 1n * 1_000_000_000n);
});

test("resolveGasCeiling: priority clamped to never exceed max", () => {
    const g = resolveGasCeiling({ KEEPER_MAX_FEE_GWEI: "5", KEEPER_MAX_PRIORITY_GWEI: "10" });
    assert.equal(g.maxFeePerGas, 5n * 1_000_000_000n);
    assert.equal(g.maxPriorityFeePerGas, 5n * 1_000_000_000n);
});

test("numEnv: unset/invalid/non-positive → fallback", () => {
    assert.equal(numEnv(undefined, 7), 7);
    assert.equal(numEnv("", 7), 7);
    assert.equal(numEnv("abc", 7), 7);
    assert.equal(numEnv("-3", 7), 7);
    assert.equal(numEnv("0", 7), 7);
    assert.equal(numEnv("12", 7), 12);
});

test("fetchJson: aborts on timeout (L-3)", async () => {
    const { createServer } = await import("node:http");
    // Server that accepts the connection but never responds.
    const server = createServer(() => { /* hang */ });
    await new Promise((res) => server.listen(0, "127.0.0.1", res));
    const { port } = server.address();
    try {
        await assert.rejects(
            () => fetchJson(`http://127.0.0.1:${port}/`, { timeoutMs: 100 }),
            (err) => {
                // AbortError surfaces as a generic fetch error; just confirm it threw.
                assert.ok(err);
                return true;
            },
        );
    } finally {
        server.close();
    }
});

test("fetchJson: parses JSON on 200", async () => {
    const { createServer } = await import("node:http");
    const server = createServer((req, res) => {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: 1 }));
    });
    await new Promise((res) => server.listen(0, "127.0.0.1", res));
    const { port } = server.address();
    try {
        const json = await fetchJson(`http://127.0.0.1:${port}/`, { timeoutMs: 2000 });
        assert.deepEqual(json, { ok: 1 });
    } finally {
        server.close();
    }
});

test("fetchJson: throws on non-2xx", async () => {
    const { createServer } = await import("node:http");
    const server = createServer((req, res) => { res.writeHead(503); res.end(); });
    await new Promise((res) => server.listen(0, "127.0.0.1", res));
    const { port } = server.address();
    try {
        await assert.rejects(
            () => fetchJson(`http://127.0.0.1:${port}/`, { timeoutMs: 2000 }),
            /HTTP 503/,
        );
    } finally {
        server.close();
    }
});
