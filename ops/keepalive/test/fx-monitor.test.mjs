// Pure-helper unit tests for L-2 FX reference-drift and the guard-monitor
// dedupe/debounce + re-validation decision. Run: `node --test` (no network).

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    decideFxReferenceDrift,
    decidePage,
    newPageState,
} from "../lib.mjs";

// --- L-2: FX reference-drift decision ----------------------------------------

test("decideFxReferenceDrift: sources agree within tolerance → ok", () => {
    // 0.030 vs 0.0303: drift = |0.030-0.0303|/0.0303*1e4 ≈ 99bps (relative to the
    // reference), tol 200 → ok.
    const d = decideFxReferenceDrift(0.030, 0.0303, 200);
    assert.equal(d.ok, true);
    assert.ok(d.driftBps < 200 && d.driftBps > 90, `unexpected driftBps=${d.driftBps}`);
});

test("decideFxReferenceDrift: sources disagree beyond tolerance → ref-drift", () => {
    // true ~0.030 but CoinGecko poisoned to 0.090 → ~19800bps drift
    const d = decideFxReferenceDrift(0.090, 0.030, 200);
    assert.equal(d.ok, false);
    assert.equal(d.reason, "ref-drift");
    assert.ok(d.driftBps > 200);
});

test("decideFxReferenceDrift: missing/zero reference → no-reference (fail safe)", () => {
    assert.equal(decideFxReferenceDrift(0.030, undefined, 200).reason, "no-reference");
    assert.equal(decideFxReferenceDrift(0.030, 0, 200).reason, "no-reference");
    assert.equal(decideFxReferenceDrift(0.030, NaN, 200).reason, "no-reference");
});

test("decideFxReferenceDrift: missing primary value → no-value", () => {
    assert.equal(decideFxReferenceDrift(undefined, 0.030, 200).reason, "no-value");
    assert.equal(decideFxReferenceDrift(0, 0.030, 200).reason, "no-value");
});

test("decideFxReferenceDrift: just under tolerance is allowed (strict >)", () => {
    // ~190bps drift vs cap 200 → ok. (The exact 200bps boundary is float-epsilon
    // sensitive under the strict > test; fine for an advisory cross-check.)
    const d = decideFxReferenceDrift(0.03057, 0.030, 200);
    assert.equal(d.ok, true);
});

// --- guard-monitor: dedupe/debounce + re-validation -------------------------

const TOK = "0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61";
const evt = (deviationBps = 9999) => ({ token: TOK, deviationBps, timestamp: 0 });

test("decidePage: confirmed deviation → page, records dedupe slot", () => {
    const state = newPageState();
    const d = decidePage(evt(), { confirmed: true }, state, 1_000_000, 60_000);
    assert.equal(d.page, true);
    assert.equal(d.reason, "confirmed-deviation");
    assert.equal(state.lastPagedAt.get(TOK.toLowerCase()), 1_000_000);
});

test("decidePage: spam (unconfirmed by independent feed) → NO page", () => {
    const state = newPageState();
    const d = decidePage(evt(), { confirmed: false }, state, 1_000_000, 60_000);
    assert.equal(d.page, false);
    assert.equal(d.reason, "unconfirmed-by-independent-feed");
});

test("decidePage: spam does NOT consume the dedupe slot (cannot suppress a later real page)", () => {
    const state = newPageState();
    // A flood of unconfirmed (spam) events first…
    for (let i = 0; i < 5; i++) {
        decidePage(evt(), { confirmed: false }, state, 1_000_000 + i, 60_000);
    }
    assert.equal(state.lastPagedAt.has(TOK.toLowerCase()), false);
    // …then a genuine confirmed event still pages.
    const real = decidePage(evt(), { confirmed: true }, state, 1_000_100, 60_000);
    assert.equal(real.page, true);
});

test("decidePage: confirmed but within cooldown → debounced (no duplicate page)", () => {
    const state = newPageState();
    const first = decidePage(evt(), { confirmed: true }, state, 1_000_000, 60_000);
    assert.equal(first.page, true);
    const second = decidePage(evt(), { confirmed: true }, state, 1_000_000 + 30_000, 60_000);
    assert.equal(second.page, false);
    assert.equal(second.reason, "debounced");
});

test("decidePage: confirmed after cooldown elapses → pages again", () => {
    const state = newPageState();
    decidePage(evt(), { confirmed: true }, state, 1_000_000, 60_000);
    const again = decidePage(evt(), { confirmed: true }, state, 1_000_000 + 60_001, 60_000);
    assert.equal(again.page, true);
});

test("decidePage: independent==null treated as unconfirmed", () => {
    const state = newPageState();
    const d = decidePage(evt(), null, state, 1_000_000, 60_000);
    assert.equal(d.page, false);
    assert.equal(d.reason, "unconfirmed-by-independent-feed");
});

test("decidePage: per-token dedupe is independent across tokens", () => {
    const state = newPageState();
    const other = { token: "0xa13c0935A98e2c175b31A4054f698819271a8FfC", deviationBps: 9999, timestamp: 0 };
    assert.equal(decidePage(evt(), { confirmed: true }, state, 1_000_000, 60_000).page, true);
    // Different token, same instant → still pages (separate cooldown).
    assert.equal(decidePage(other, { confirmed: true }, state, 1_000_000, 60_000).page, true);
});
