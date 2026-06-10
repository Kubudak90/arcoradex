import { test } from "node:test";
import assert from "node:assert/strict";
import { buildPushList, PEGS_1E18 } from "../lib.mjs";

test("buildPushList returns one entry per fully-configured token", () => {
    const env = {
        ADAPTER_USDC: "0xaUSDC",
        TOKEN_USDC: "0xtUSDC",
        ADAPTER_USDT: "0xaUSDT",
        TOKEN_USDT: "0xtUSDT",
        ADAPTER_EURC: "0xaEURC",
        TOKEN_EURC: "0xtEURC",
    };
    const out = buildPushList(env);
    assert.equal(out.length, 3);
    const usdc = out.find((p) => p.symbol === "USDC");
    assert.equal(usdc.adapter, "0xaUSDC");
    assert.equal(usdc.token, "0xtUSDC");
    assert.equal(usdc.price1e18, 1_000000000000000000n);
    const eurc = out.find((p) => p.symbol === "EURC");
    assert.equal(eurc.price1e18, 1_150000000000000000n);
});

test("buildPushList skips a token missing its adapter or token address", () => {
    const env = { ADAPTER_USDC: "0xaUSDC" }; // no TOKEN_USDC
    assert.equal(buildPushList(env).length, 0);
});

test("PEGS_1E18 matches the orchestrator _cfg() pegs", () => {
    assert.equal(PEGS_1E18.USDC, 1_000000000000000000n);
    assert.equal(PEGS_1E18.USDT, 1_000000000000000000n);
    assert.equal(PEGS_1E18.EURC, 1_150000000000000000n);
});
