import { test } from "node:test";
import assert from "node:assert/strict";
import { parseHermesBlobs, fetchHermesUpdates, FEED_IDS } from "../lib.mjs";

test("parseHermesBlobs prefixes 0x and returns all entries", () => {
    const out = parseHermesBlobs({ binary: { encoding: "hex", data: ["abcd", "0x1234"] } });
    assert.deepEqual(out, ["0xabcd", "0x1234"]);
});

test("parseHermesBlobs throws on empty", () => {
    assert.throws(() => parseHermesBlobs({ binary: { data: [] } }), /empty binary.data/);
    assert.throws(() => parseHermesBlobs({}), /empty binary.data/);
});

test("fetchHermesUpdates builds the v2 ids[] query and returns prefixed blobs", async () => {
    let captured;
    const fakeFetch = async (url) => {
        captured = url;
        return { ok: true, json: async () => ({ binary: { encoding: "hex", data: ["dead"] } }) };
    };
    const out = await fetchHermesUpdates(Object.values(FEED_IDS), { fetchImpl: fakeFetch });
    assert.deepEqual(out, ["0xdead"]);
    assert.match(captured, /\/v2\/updates\/price\/latest\?/);
    assert.match(captured, /ids%5B%5D=0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a/);
    assert.match(captured, /encoding=hex/);
});

test("fetchHermesUpdates throws on non-200", async () => {
    const fakeFetch = async () => ({ ok: false, status: 503 });
    await assert.rejects(() => fetchHermesUpdates(["0x00"], { fetchImpl: fakeFetch }), /Hermes HTTP 503/);
});
