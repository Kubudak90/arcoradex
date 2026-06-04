// Pure-helper unit tests for the keeper price-sanity + ratchet logic.
// Run: `node --test` (no network).

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    decidePriceSanity,
    clampToMaxDev,
    priceTo1e8,
} from "../lib.mjs";

const usdFeed = { band: { min: 0.95, max: 1.05 }, peg: 1.0, maxPegDriftBps: 200 };
const fxFeedNoPeg = { band: { min: 1.0, max: 1.3 }, peg: null, maxPegDriftBps: null };

test("decidePriceSanity: in-band, on peg → ok", () => {
    assert.deepEqual(decidePriceSanity(1.0, usdFeed), { ok: true });
    assert.deepEqual(decidePriceSanity(1.005, usdFeed), { ok: true });
});

test("decidePriceSanity: missing/non-numeric → no-value", () => {
    assert.equal(decidePriceSanity(undefined, usdFeed).reason, "no-value");
    assert.equal(decidePriceSanity(NaN, usdFeed).reason, "no-value");
    assert.equal(decidePriceSanity("1.0", usdFeed).reason, "no-value");
});

test("decidePriceSanity: outside band → out-of-band", () => {
    assert.equal(decidePriceSanity(0.94, usdFeed).reason, "out-of-band");
    assert.equal(decidePriceSanity(1.06, usdFeed).reason, "out-of-band");
});

test("decidePriceSanity: in-band but beyond peg-drift → peg-drift", () => {
    // peg=1.0, cap=200bps (2%). 1.03 is in band [0.95,1.05] but 300bps off peg.
    const d = decidePriceSanity(1.03, usdFeed);
    assert.equal(d.reason, "peg-drift");
    assert.ok(Math.abs(d.driftBps - 300) < 1e-6);
});

test("decidePriceSanity: just under the peg-drift cap is allowed (strict >)", () => {
    // 1.019 = 190bps off peg=1.0; cap is 200 → not over → ok. (1.02 lands at
    // 200.0000…017 bps under IEEE-754, so it trips — the strict > test means the
    // exact boundary is float-epsilon sensitive, which is fine for an advisory cap.)
    assert.deepEqual(decidePriceSanity(1.019, usdFeed), { ok: true });
});

test("decidePriceSanity: null peg skips peg-drift (band only)", () => {
    assert.deepEqual(decidePriceSanity(1.25, fxFeedNoPeg), { ok: true });
    assert.equal(decidePriceSanity(1.31, fxFeedNoPeg).reason, "out-of-band");
});

test("clampToMaxDev: within tolerance passes uncapped", () => {
    const prev = priceTo1e8(1.0); // 1e8
    const target = priceTo1e8(1.002); // +20bps, maxDev 50bps
    const { newAnswer, capped } = clampToMaxDev(prev, target, 50);
    assert.equal(capped, false);
    assert.equal(newAnswer, target);
});

test("clampToMaxDev: over tolerance clamps up to +maxDev", () => {
    const prev = priceTo1e8(1.0); // 1e8
    const target = priceTo1e8(1.10); // +1000bps, maxDev 50bps
    const { newAnswer, capped } = clampToMaxDev(prev, target, 50);
    assert.equal(capped, true);
    // +50bps of 1e8 = 500000
    assert.equal(newAnswer, prev + 500_000n);
});

test("clampToMaxDev: over tolerance clamps down to -maxDev", () => {
    const prev = priceTo1e8(1.0);
    const target = priceTo1e8(0.90); // -1000bps
    const { newAnswer, capped } = clampToMaxDev(prev, target, 50);
    assert.equal(capped, true);
    assert.equal(newAnswer, prev - 500_000n);
});

test("clampToMaxDev: prev<=0 (no anchor) passes through", () => {
    const target = priceTo1e8(1.0);
    assert.deepEqual(clampToMaxDev(0n, target, 50), { newAnswer: target, capped: false });
    assert.deepEqual(clampToMaxDev(-5n, target, 50), { newAnswer: target, capped: false });
});

test("priceTo1e8: rounds to 8 decimals", () => {
    assert.equal(priceTo1e8(1.0), 100_000_000n);
    assert.equal(priceTo1e8(0.03), 3_000_000n);
    assert.equal(priceTo1e8(1.23456789), 123_456_789n);
});
