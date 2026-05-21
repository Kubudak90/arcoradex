import { describe, expect, it } from "vitest";
import {
  COOLDOWN_MS,
  MemoryCooldownStore,
  checkRateLimit,
  extractClientIp,
  recordClaim,
} from "../faucet-rate-limit";

const ADDR = "0x0000000000000000000000000000000000001234";
const ADDR_LOWER = "0x0000000000000000000000000000000000001234";
const ADDR_OTHER = "0x0000000000000000000000000000000000005678";
const IP_A = "10.0.0.1";
const IP_B = "10.0.0.2";

describe("checkRateLimit", () => {
  it("returns ok when neither recipient nor IP has claimed", () => {
    const store = new MemoryCooldownStore();
    const r = checkRateLimit(store, ADDR, IP_A);
    expect(r.ok).toBe(true);
  });

  it("blocks by address when same recipient claimed within cooldown", () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    recordClaim(store, ADDR, IP_A, t0);
    const r = checkRateLimit(store, ADDR, IP_B, t0 + 1_000);
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.blockedBy).toBe("address");
      expect(r.retryAfterSec).toBeGreaterThan(0);
    }
  });

  it("blocks by IP when a different recipient claimed from same IP within cooldown", () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    recordClaim(store, ADDR_OTHER, IP_A, t0);
    const r = checkRateLimit(store, ADDR, IP_A, t0 + 1_000);
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.blockedBy).toBe("ip");
    }
  });

  it("releases after cooldown elapses for both keys", () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    recordClaim(store, ADDR, IP_A, t0);
    const r = checkRateLimit(store, ADDR, IP_A, t0 + COOLDOWN_MS + 1);
    expect(r.ok).toBe(true);
  });

  it("address-blocked even when IP is undefined (no per-IP cap)", () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    recordClaim(store, ADDR, undefined, t0);
    const r = checkRateLimit(store, ADDR, undefined, t0 + 1_000);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.blockedBy).toBe("address");
  });

  it("is case-insensitive on recipient address", () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    recordClaim(store, ADDR.toUpperCase(), IP_A, t0);
    const r = checkRateLimit(store, ADDR_LOWER, IP_B, t0 + 1_000);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.blockedBy).toBe("address");
  });

  it("retryAfterSec shrinks as time advances", () => {
    const store = new MemoryCooldownStore();
    const t0 = 1_000_000_000;
    recordClaim(store, ADDR, IP_A, t0);
    const r1 = checkRateLimit(store, ADDR, IP_A, t0 + 1_000);
    const r2 = checkRateLimit(store, ADDR, IP_A, t0 + 10 * 60 * 1000);
    if (r1.ok || r2.ok) throw new Error("expected both blocked");
    expect(r2.retryAfterSec).toBeLessThan(r1.retryAfterSec);
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
