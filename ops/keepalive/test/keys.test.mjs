// Pure-helper unit tests for the H-2 primary/secondary key split:
// normalisation, distinctness enforcement, and wallet-selection-by-role.
// Run: `node --test` (no network).

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    normalizePk,
    assertDistinctKeys,
    selectWalletForRole,
} from "../lib.mjs";

const A = "0x" + "11".repeat(32);
const B = "0x" + "22".repeat(32);

test("normalizePk: adds 0x prefix and lowercases", () => {
    assert.equal(normalizePk("AB".repeat(32)), "0x" + "ab".repeat(32));
    assert.equal(normalizePk("0xAB" + "cd".repeat(31)), ("0xab" + "cd".repeat(31)));
    assert.equal(normalizePk("  " + A + "  "), A);
});

test("normalizePk: empty/falsy → null", () => {
    assert.equal(normalizePk(""), null);
    assert.equal(normalizePk(undefined), null);
    assert.equal(normalizePk(null), null);
});

test("assertDistinctKeys: distinct keys → normalised pair", () => {
    const { primaryPk, secondaryPk } = assertDistinctKeys(A, B);
    assert.equal(primaryPk, A);
    assert.equal(secondaryPk, B);
});

test("assertDistinctKeys: normalises before comparing (same key diff casing/prefix) → throws", () => {
    const upperNoPrefix = "11".repeat(32).toUpperCase();
    assert.throws(() => assertDistinctKeys(A, upperNoPrefix), /must differ/);
});

test("assertDistinctKeys: equal keys → throws (H-2)", () => {
    assert.throws(() => assertDistinctKeys(A, A), /must differ.*H-2/s);
});

test("assertDistinctKeys: missing primary → throws", () => {
    assert.throws(() => assertDistinctKeys(undefined, B), /KEEPER_PRIMARY_KEY missing/);
});

test("assertDistinctKeys: missing secondary → throws", () => {
    assert.throws(() => assertDistinctKeys(A, ""), /KEEPER_SECONDARY_KEY missing/);
});

test("selectWalletForRole: primary feed → primary wallet, secondary → secondary", () => {
    const wallets = { primary: { id: "P" }, secondary: { id: "S" } };
    assert.equal(selectWalletForRole("primary", wallets).id, "P");
    assert.equal(selectWalletForRole("secondary", wallets).id, "S");
});

test("selectWalletForRole: unknown role → throws", () => {
    const wallets = { primary: {}, secondary: {} };
    assert.throws(() => selectWalletForRole("tertiary", wallets), /unknown feed role/);
});
