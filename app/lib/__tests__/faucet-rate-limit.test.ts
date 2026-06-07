import { afterEach, describe, expect, it, vi } from "vitest";
import {
  COOLDOWN_MS,
  MemoryCooldownStore,
  FailClosedStore,
  UpstashCooldownStore,
  FetchUpstashRedis,
  createCooldownStore,
  checkRateLimit,
  consumeHourlyBudget,
  extractClientIp,
  recordClaim,
  refundHourlyBudget,
  releaseInflight,
  reserveInflight,
  rollbackClaim,
} from "../faucet-rate-limit";

const ADDR = "0x0000000000000000000000000000000000001234";
const ADDR_LOWER = "0x0000000000000000000000000000000000001234";
const ADDR_OTHER = "0x0000000000000000000000000000000000005678";
const IP_A = "10.0.0.1";
const IP_B = "10.0.0.2";

describe("checkRateLimit", () => {
  it("returns ok when neither recipient nor IP has claimed", async () => {
    const store = new MemoryCooldownStore();
    const r = await checkRateLimit(store, ADDR, IP_A);
    expect(r.ok).toBe(true);
  });

  it("blocks by address when same recipient claimed within cooldown", async () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    await recordClaim(store, ADDR, IP_A, t0);
    const r = await checkRateLimit(store, ADDR, IP_B, t0 + 1_000);
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.blockedBy).toBe("address");
      expect(r.retryAfterSec).toBeGreaterThan(0);
    }
  });

  it("blocks by IP when a different recipient claimed from same IP within cooldown", async () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    await recordClaim(store, ADDR_OTHER, IP_A, t0);
    const r = await checkRateLimit(store, ADDR, IP_A, t0 + 1_000);
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.blockedBy).toBe("ip");
    }
  });

  it("releases after cooldown elapses for both keys", async () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    await recordClaim(store, ADDR, IP_A, t0);
    const r = await checkRateLimit(store, ADDR, IP_A, t0 + COOLDOWN_MS + 1);
    expect(r.ok).toBe(true);
  });

  it("address-blocked even when IP is undefined (no per-IP cap)", async () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    await recordClaim(store, ADDR, undefined, t0);
    const r = await checkRateLimit(store, ADDR, undefined, t0 + 1_000);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.blockedBy).toBe("address");
  });

  it("is case-insensitive on recipient address", async () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    await recordClaim(store, ADDR.toUpperCase(), IP_A, t0);
    const r = await checkRateLimit(store, ADDR_LOWER, IP_B, t0 + 1_000);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.blockedBy).toBe("address");
  });

  it("retryAfterSec shrinks as time advances", async () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    await recordClaim(store, ADDR, IP_A, t0);
    const r1 = await checkRateLimit(store, ADDR, IP_A, t0 + 1_000);
    const r2 = await checkRateLimit(store, ADDR, IP_A, t0 + 10 * 60 * 1000);
    if (r1.ok || r2.ok) throw new Error("expected both blocked");
    expect(r2.retryAfterSec).toBeLessThan(r1.retryAfterSec);
  });
});

describe("rollbackClaim (M-2)", () => {
  it("undoes a recorded claim so a retry is allowed", async () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    await recordClaim(store, ADDR, IP_A, t0);
    expect((await checkRateLimit(store, ADDR, IP_A, t0 + 1_000)).ok).toBe(false);
    await rollbackClaim(store, ADDR, IP_A);
    expect((await checkRateLimit(store, ADDR, IP_A, t0 + 1_000)).ok).toBe(true);
  });
});

describe("reserveInflight (M-3 atomic reserve-or-fail)", () => {
  it("first reserve wins, a second concurrent reserve for the same address fails", async () => {
    const store = new MemoryCooldownStore();
    const a = await reserveInflight(store, ADDR, IP_A);
    expect(a.ok).toBe(true);
    // Same address, different IP: still blocked by the address slot.
    const b = await reserveInflight(store, ADDR, IP_B);
    expect(b.ok).toBe(false);
    expect(b.acquired).toEqual([]);
  });

  it("a second reserve for the same IP (different address) fails", async () => {
    const store = new MemoryCooldownStore();
    const a = await reserveInflight(store, ADDR, IP_A);
    expect(a.ok).toBe(true);
    const b = await reserveInflight(store, ADDR_OTHER, IP_A);
    expect(b.ok).toBe(false);
  });

  it("releasing the reservation lets a new reserve succeed", async () => {
    const store = new MemoryCooldownStore();
    const a = await reserveInflight(store, ADDR, IP_A);
    expect(a.ok).toBe(true);
    await releaseInflight(store, a.acquired);
    const b = await reserveInflight(store, ADDR, IP_A);
    expect(b.ok).toBe(true);
  });

  it("does not leak the address slot when the IP slot is already held", async () => {
    const store = new MemoryCooldownStore();
    // Hold IP_A via ADDR_OTHER.
    const held = await reserveInflight(store, ADDR_OTHER, IP_A);
    expect(held.ok).toBe(true);
    // ADDR tries with the held IP_A — should fail AND not leave ADDR's slot set.
    const blocked = await reserveInflight(store, ADDR, IP_A);
    expect(blocked.ok).toBe(false);
    // Release the holder, then ADDR with a fresh IP should succeed (proving
    // ADDR's address slot was rolled back, not leaked).
    await releaseInflight(store, held.acquired);
    const ok = await reserveInflight(store, ADDR, IP_B);
    expect(ok.ok).toBe(true);
  });
});

describe("consumeHourlyBudget (M-3 global cap)", () => {
  it("allows up to `budget` and blocks the (budget+1)th", async () => {
    const store = new MemoryCooldownStore();
    const budget = 3;
    const r1 = await consumeHourlyBudget(store, budget);
    const r2 = await consumeHourlyBudget(store, budget);
    const r3 = await consumeHourlyBudget(store, budget);
    const r4 = await consumeHourlyBudget(store, budget);
    expect([r1.ok, r2.ok, r3.ok]).toEqual([true, true, true]);
    expect(r4.ok).toBe(false);
    expect(r4.count).toBe(4);
  });

  it("refund undoes a consume so the slot is reusable", async () => {
    const store = new MemoryCooldownStore();
    const budget = 1;
    // Consume the only slot, then refund it (as the route does on a zero-mint
    // rollback). A subsequent consume must succeed because the count is back
    // to zero.
    expect((await consumeHourlyBudget(store, budget)).count).toBe(1);
    await refundHourlyBudget(store);
    const again = await consumeHourlyBudget(store, budget);
    expect(again.count).toBe(1);
    expect(again.ok).toBe(true);
  });
});

describe("extractClientIp", () => {
  function mkReq(headers: Record<string, string>): Request {
    return new Request("https://example.test/api/faucet", {
      method: "POST",
      headers,
    });
  }

  it("takes the first IP from x-forwarded-for", () => {
    const ip = extractClientIp(mkReq({ "x-forwarded-for": "203.0.113.5, 10.0.0.1" }));
    expect(ip).toBe("203.0.113.5");
  });

  it("trims whitespace in x-forwarded-for entries", () => {
    const ip = extractClientIp(mkReq({ "x-forwarded-for": "  203.0.113.5  ,  10.0.0.1  " }));
    expect(ip).toBe("203.0.113.5");
  });

  it("falls back to x-real-ip when x-forwarded-for is missing", () => {
    const ip = extractClientIp(mkReq({ "x-real-ip": "198.51.100.7" }));
    expect(ip).toBe("198.51.100.7");
  });

  it("returns undefined when no IP header is present", () => {
    const ip = extractClientIp(mkReq({}));
    expect(ip).toBeUndefined();
  });

  it("ignores empty x-forwarded-for and falls back", () => {
    const ip = extractClientIp(mkReq({ "x-forwarded-for": "", "x-real-ip": "198.51.100.7" }));
    expect(ip).toBe("198.51.100.7");
  });
});

describe("createCooldownStore backend selection (M-3 fail-closed)", () => {
  const SAVED = {
    url: process.env.UPSTASH_REDIS_REST_URL,
    token: process.env.UPSTASH_REDIS_REST_TOKEN,
    vercel: process.env.VERCEL_ENV,
  };
  afterEach(() => {
    // Restore env so other suites are unaffected.
    const restore = (k: "UPSTASH_REDIS_REST_URL" | "UPSTASH_REDIS_REST_TOKEN" | "VERCEL_ENV", v: string | undefined) => {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    };
    restore("UPSTASH_REDIS_REST_URL", SAVED.url);
    restore("UPSTASH_REDIS_REST_TOKEN", SAVED.token);
    restore("VERCEL_ENV", SAVED.vercel);
  });

  it("uses the in-memory store in dev/test when no Upstash creds are set", () => {
    delete process.env.UPSTASH_REDIS_REST_URL;
    delete process.env.UPSTASH_REDIS_REST_TOKEN;
    delete process.env.VERCEL_ENV;
    expect(createCooldownStore()).toBeInstanceOf(MemoryCooldownStore);
  });

  it("FAILS CLOSED in production when no cross-instance backend is configured", async () => {
    delete process.env.UPSTASH_REDIS_REST_URL;
    delete process.env.UPSTASH_REDIS_REST_TOKEN;
    process.env.VERCEL_ENV = "production";
    const store = createCooldownStore();
    // Must NOT silently use the per-instance Memory store (that would re-open M-3).
    expect(store).toBeInstanceOf(FailClosedStore);
    expect(store).not.toBeInstanceOf(MemoryCooldownStore);
    // Every operation throws at request time, so the faucet refuses to serve.
    await expect(store.get("k")).rejects.toThrow(/cross-instance faucet store is required/);
    await expect(store.reserve("k", 1000)).rejects.toThrow(/cross-instance/);
    await expect(store.incrWithTtl("k", 60)).rejects.toThrow(/cross-instance/);
  });

  it("uses the cross-instance Upstash store (NOT fail-closed) when REST creds are set", () => {
    process.env.UPSTASH_REDIS_REST_URL = "http://example.test:18079";
    process.env.UPSTASH_REDIS_REST_TOKEN = "tok";
    process.env.VERCEL_ENV = "production";
    const store = createCooldownStore();
    // Regression for the deferred-dep bug: creds present must yield a real
    // cross-instance backend, not a FailClosedStore (which the old dynamic
    // `require("@upstash/redis")` produced when the package wasn't installed,
    // 500-ing the live faucet).
    expect(store).toBeInstanceOf(UpstashCooldownStore);
    expect(store).not.toBeInstanceOf(FailClosedStore);
  });
});

describe("FetchUpstashRedis (dependency-free Upstash REST client)", () => {
  function mockFetch(result: unknown) {
    const calls: { url: string; body: unknown; auth: string | null }[] = [];
    const fn = vi.fn(async (url: string, init: RequestInit) => {
      calls.push({
        url,
        body: JSON.parse(init.body as string),
        auth: new Headers(init.headers).get("authorization"),
      });
      return new Response(JSON.stringify({ result }), { status: 200 });
    });
    return { fn, calls };
  }

  afterEach(() => vi.unstubAllGlobals());

  it("encodes SET ... NX PX as an Upstash command array with a Bearer token", async () => {
    const { fn, calls } = mockFetch("OK");
    vi.stubGlobal("fetch", fn);
    const redis = new FetchUpstashRedis("http://srh.test:18079", "secret-token");
    const res = await redis.set("k", 1717000000000, { nx: true, px: 60000 });
    expect(res).toBe("OK");
    expect(calls[0]!.url).toBe("http://srh.test:18079");
    expect(calls[0]!.auth).toBe("Bearer secret-token");
    // All args stringified, NX/PX appended in order — matches `SET k v NX PX 60000`.
    expect(calls[0]!.body).toEqual(["SET", "k", "1717000000000", "NX", "PX", "60000"]);
  });

  it("reserve() returns true via UpstashCooldownStore when SET NX succeeds, false when key exists", async () => {
    // SET NX -> "OK": slot acquired.
    const ok = mockFetch("OK");
    vi.stubGlobal("fetch", ok.fn);
    const acquired = await new UpstashCooldownStore(
      new FetchUpstashRedis("http://srh.test", "t"),
    ).reserve("inflight:k", 60000);
    expect(acquired).toBe(true);

    // SET NX -> null: key already held, slot denied.
    const denied = mockFetch(null);
    vi.stubGlobal("fetch", denied.fn);
    const blocked = await new UpstashCooldownStore(
      new FetchUpstashRedis("http://srh.test", "t"),
    ).reserve("inflight:k", 60000);
    expect(blocked).toBe(false);
  });

  it("incrWithTtl sets the window TTL only on the first increment", async () => {
    const calls: unknown[][] = [];
    let n = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: string, init: RequestInit) => {
        const body = JSON.parse(init.body as string) as unknown[];
        calls.push(body);
        // INCR returns the new counter; EXPIRE returns 1.
        const result = body[0] === "INCR" ? ++n : 1;
        return new Response(JSON.stringify({ result }), { status: 200 });
      }),
    );
    const store = new UpstashCooldownStore(new FetchUpstashRedis("http://srh.test", "t"));
    await store.incrWithTtl("budget", 3600); // n=1 -> EXPIRE
    await store.incrWithTtl("budget", 3600); // n=2 -> no EXPIRE
    const cmds = calls.map((c) => c[0]);
    expect(cmds).toEqual(["INCR", "EXPIRE", "INCR"]);
  });

  it("throws on a non-OK HTTP response (so the route fails closed)", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("nope", { status: 500 })),
    );
    const redis = new FetchUpstashRedis("http://srh.test", "t");
    await expect(redis.get("k")).rejects.toThrow(/HTTP 500/);
  });
});
