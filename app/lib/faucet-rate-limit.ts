// Faucet rate-limit primitives. Extracted from the /api/faucet route so the
// cooldown logic is reachable from unit tests and can swap backends if/when
// we move off in-memory storage.
//
// Storage posture: this module exports an in-memory store keyed by both
// recipient address AND client IP. On Vercel Fluid Compute the Map persists
// across requests handled by the same instance, but cold starts (or multiple
// concurrent instances) reset it — accepted tradeoff for a testnet faucet.
// The per-IP key is what stops a single client from spamming with fresh
// wallets; the per-address key is the human-meaningful 24h limit.

export const COOLDOWN_MS = 24 * 60 * 60 * 1000;

export interface CooldownStore {
  get(key: string): number | undefined;
  set(key: string, value: number): void;
}

export class MemoryCooldownStore implements CooldownStore {
  private map = new Map<string, number>();
  get(key: string): number | undefined {
    return this.map.get(key);
  }
  set(key: string, value: number): void {
    this.map.set(key, value);
  }
}

export type BlockedBy = "address" | "ip";

export interface RateLimitOk {
  ok: true;
}

export interface RateLimitBlocked {
  ok: false;
  blockedBy: BlockedBy;
  retryAfterSec: number;
}

export type RateLimitResult = RateLimitOk | RateLimitBlocked;

function addrKey(recipient: string): string {
  return `addr:${recipient.toLowerCase()}`;
}

function ipKey(ip: string): string {
  return `ip:${ip}`;
}

export function checkRateLimit(
  store: CooldownStore,
  recipient: string,
  ip: string | undefined,
  now: number = Date.now(),
  cooldownMs: number = COOLDOWN_MS,
): RateLimitResult {
  const lastAddr = store.get(addrKey(recipient));
  if (lastAddr !== undefined && now - lastAddr < cooldownMs) {
    return {
      ok: false,
      blockedBy: "address",
      retryAfterSec: Math.ceil((cooldownMs - (now - lastAddr)) / 1000),
    };
  }
  if (ip) {
    const lastIp = store.get(ipKey(ip));
    if (lastIp !== undefined && now - lastIp < cooldownMs) {
      return {
        ok: false,
        blockedBy: "ip",
        retryAfterSec: Math.ceil((cooldownMs - (now - lastIp)) / 1000),
      };
    }
  }
  return { ok: true };
}

export function recordClaim(
  store: CooldownStore,
  recipient: string,
  ip: string | undefined,
  now: number = Date.now(),
): void {
  store.set(addrKey(recipient), now);
  if (ip) store.set(ipKey(ip), now);
}

// Resolve the first IP from x-forwarded-for (Vercel sets this), falling back
// to x-real-ip. Returns undefined when no usable header is present — callers
// treat that as "no per-IP cap enforced", which is the same posture as before.
export function extractClientIp(request: Request): string | undefined {
  const fwd = request.headers.get("x-forwarded-for");
  if (fwd) {
    const first = fwd.split(",")[0]?.trim();
    if (first) return first;
  }
  const real = request.headers.get("x-real-ip");
  if (real) {
    const trimmed = real.trim();
    if (trimmed) return trimmed;
  }
  return undefined;
}
