// Faucet rate-limit primitives. Extracted from the /api/faucet route so the
// cooldown + in-flight reservation logic is reachable from unit tests and can
// swap storage backends.
//
// M-3 (audit 2026-05-31): the cooldown AND the in-flight mutex used to live in
// per-serverless-instance memory (a Map + two module Sets). On Vercel each
// concurrent function invocation has its own instance, so two requests for the
// same recipient/IP landing on different instances both passed the check and
// both ran the 7-tx mint loop — the cooldown was best-effort at best. We now
// route through a CooldownStore abstraction with two backends, selected by env:
//
//   - UpstashCooldownStore  (UPSTASH_REDIS_REST_URL + UPSTASH_REDIS_REST_TOKEN
//     present): cross-instance + atomic. Reservation uses `SET key val NX PX`
//     (set-if-not-exists with a TTL) so only one invocation can hold a slot.
//   - MemoryCooldownStore    (dev/test fallback): a single-instance Map. Same
//     interface, no atomicity guarantees across instances — fine locally.
//
// Keys: per-recipient ADDRESS and per-client IP for the 24h cooldown, an
// in-flight reservation key per address/IP, and a single global hourly
// mint-budget counter that caps total claims/hour regardless of who asks.

export const COOLDOWN_MS = 24 * 60 * 60 * 1000;

// Global cap on faucet batches per rolling hour, across all addresses/IPs.
// A blunt circuit-breaker: if the faucet key is abused (or a bug loops), the
// hourly budget bounds the blast radius even when per-key limits are evaded.
export const HOURLY_BUDGET = 200;
export const BUDGET_WINDOW_SEC = 60 * 60;

// ---------------------------------------------------------------------------
// Store abstraction (async). All methods return Promises so the Upstash REST
// backend (network round-trip) and the in-memory backend share one interface.
// ---------------------------------------------------------------------------
export interface CooldownStore {
  /** Last-claim epoch-ms for `key`, or undefined if unset/expired. */
  get(key: string): Promise<number | undefined>;
  /** Record a claim timestamp for `key`, expiring after `ttlMs`. */
  set(key: string, value: number, ttlMs: number): Promise<void>;
  /** Remove `key` (claim rollback). */
  delete(key: string): Promise<void>;
  /**
   * Atomically reserve `key` for `ttlMs`. Returns true if the caller won the
   * slot (key did not exist), false if it was already held. Cross-instance
   * atomic on Upstash via `SET ... NX PX`.
   */
  reserve(key: string, ttlMs: number): Promise<boolean>;
  /** Release a previously-reserved key. */
  release(key: string): Promise<void>;
  /**
   * Increment `key` and ensure it expires after `windowSec` (set on first
   * increment). Returns the new counter value. Used for the hourly budget.
   */
  incrWithTtl(key: string, windowSec: number): Promise<number>;
  /** Decrement `key` (budget refund). No-op below zero is acceptable. */
  decr(key: string): Promise<void>;
}

interface MemoryEntry {
  value: number;
  expiresAt: number;
}

export class MemoryCooldownStore implements CooldownStore {
  private map = new Map<string, MemoryEntry>();
  private counters = new Map<string, MemoryEntry>();

  private live(m: Map<string, MemoryEntry>, key: string, now: number): MemoryEntry | undefined {
    const e = m.get(key);
    if (e === undefined) return undefined;
    if (e.expiresAt <= now) {
      m.delete(key);
      return undefined;
    }
    return e;
  }

  async get(key: string): Promise<number | undefined> {
    const e = this.live(this.map, key, Date.now());
    return e?.value;
  }

  async set(key: string, value: number, ttlMs: number): Promise<void> {
    this.map.set(key, { value, expiresAt: Date.now() + ttlMs });
  }

  async delete(key: string): Promise<void> {
    this.map.delete(key);
  }

  async reserve(key: string, ttlMs: number): Promise<boolean> {
    const now = Date.now();
    if (this.live(this.map, key, now) !== undefined) return false;
    this.map.set(key, { value: now, expiresAt: now + ttlMs });
    return true;
  }

  async release(key: string): Promise<void> {
    this.map.delete(key);
  }

  async incrWithTtl(key: string, windowSec: number): Promise<number> {
    const now = Date.now();
    const e = this.live(this.counters, key, now);
    if (e === undefined) {
      this.counters.set(key, { value: 1, expiresAt: now + windowSec * 1000 });
      return 1;
    }
    e.value += 1;
    return e.value;
  }

  async decr(key: string): Promise<void> {
    const e = this.live(this.counters, key, Date.now());
    if (e !== undefined && e.value > 0) e.value -= 1;
  }
}

// ---------------------------------------------------------------------------
// Upstash REST backend. Written for PR-7; the live Upstash instance + env vars
// are provisioned in the deploy step (PR-9). Tests run on MemoryCooldownStore.
// `@upstash/redis` is HTTP/REST, so no persistent socket — safe for serverless.
// ---------------------------------------------------------------------------
interface UpstashRedisLike {
  get(key: string): Promise<unknown>;
  set(
    key: string,
    value: string | number,
    opts?: { nx?: boolean; px?: number },
  ): Promise<unknown>;
  del(...keys: string[]): Promise<unknown>;
  incr(key: string): Promise<number>;
  decr(key: string): Promise<number>;
  expire(key: string, seconds: number): Promise<unknown>;
}

export class UpstashCooldownStore implements CooldownStore {
  constructor(private redis: UpstashRedisLike) {}

  async get(key: string): Promise<number | undefined> {
    const raw = await this.redis.get(key);
    if (raw === null || raw === undefined) return undefined;
    const n = typeof raw === "number" ? raw : Number(raw);
    return Number.isFinite(n) ? n : undefined;
  }

  async set(key: string, value: number, ttlMs: number): Promise<void> {
    await this.redis.set(key, value, { px: ttlMs });
  }

  async delete(key: string): Promise<void> {
    await this.redis.del(key);
  }

  async reserve(key: string, ttlMs: number): Promise<boolean> {
    // SET key val NX PX ttl — returns "OK" when set, null when key existed.
    const res = await this.redis.set(key, Date.now(), { nx: true, px: ttlMs });
    return res === "OK" || res === true;
  }

  async release(key: string): Promise<void> {
    await this.redis.del(key);
  }

  async incrWithTtl(key: string, windowSec: number): Promise<number> {
    const n = await this.redis.incr(key);
    // Set the window TTL only on the first increment so the counter resets
    // hourly rather than sliding forward on every claim.
    if (n === 1) await this.redis.expire(key, windowSec);
    return n;
  }

  async decr(key: string): Promise<void> {
    await this.redis.decr(key);
  }
}

// ---------------------------------------------------------------------------
// Dependency-free Upstash REST client. The cross-instance store talks to an
// Upstash-compatible REST endpoint — hosted Upstash OR the self-hosted
// serverless-redis-http ("SRH") gateway on the ops box. The official
// `@upstash/redis` package is just a thin fetch wrapper over this same wire
// protocol (POST the command as a JSON array with a Bearer token, read the
// `{ result }` field), so we implement it inline instead of taking the
// dependency. Why this matters: adding @upstash/redis as a direct app dependency
// perturbs pnpm's peer-context resolution and forks `wagmi` into two
// WagmiProvider instances (the app's wagmi key gains a `(@upstash/redis)` peer
// marker the dex-sdk's does not), which crashes the /_not-found static prerender
// with "useConfig must be used within WagmiProvider". No dep ⇒ no fork, and the
// faucet still gets a real cross-instance backend in production. This also means
// createCooldownStore can no longer fail to load the client at runtime.
export class FetchUpstashRedis implements UpstashRedisLike {
  constructor(
    private readonly url: string,
    private readonly token: string,
  ) {}

  // Upstash REST: POST the command as a JSON array to the base URL with a Bearer
  // token; the body is `{ "result": <value> }` on success or `{ "error": ... }`.
  private async command(args: (string | number)[]): Promise<unknown> {
    const res = await fetch(this.url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.token}`,
        "Content-Type": "application/json",
      },
      // Coerce to strings so numeric args round-trip identically to the official
      // client (Redis stores everything as strings anyway).
      body: JSON.stringify(args.map((a) => String(a))),
      cache: "no-store",
    });
    if (!res.ok) {
      throw new Error(`Upstash REST ${args[0]} failed: HTTP ${res.status}`);
    }
    const json = (await res.json()) as { result?: unknown; error?: string };
    if (json.error) throw new Error(`Upstash REST ${args[0]} error: ${json.error}`);
    return json.result ?? null;
  }

  async get(key: string): Promise<unknown> {
    return this.command(["GET", key]);
  }

  async set(
    key: string,
    value: string | number,
    opts?: { nx?: boolean; px?: number },
  ): Promise<unknown> {
    const args: (string | number)[] = ["SET", key, value];
    if (opts?.nx) args.push("NX");
    if (opts?.px !== undefined) args.push("PX", opts.px);
    // Returns "OK" when set, null when NX found an existing key — exactly what
    // UpstashCooldownStore.reserve() checks for.
    return this.command(args);
  }

  async del(...keys: string[]): Promise<unknown> {
    return this.command(["DEL", ...keys]);
  }

  async incr(key: string): Promise<number> {
    return Number(await this.command(["INCR", key]));
  }

  async decr(key: string): Promise<number> {
    return Number(await this.command(["DECR", key]));
  }

  async expire(key: string, seconds: number): Promise<unknown> {
    return this.command(["EXPIRE", key, seconds]);
  }
}

// ---------------------------------------------------------------------------
// Fail-closed store. Returned in PRODUCTION when the cross-instance backend is
// expected but unavailable (Upstash env unset, or @upstash/redis can't load).
// Construction is cheap so module load / `next build` (which runs with
// NODE_ENV=production) never throws; every OPERATION throws at request time, so
// the faucet refuses to serve on a per-instance store instead of SILENTLY
// re-opening M-3 (cross-instance rate-limit defeated). Dev/test still get the
// in-memory fallback.
// ---------------------------------------------------------------------------
export class FailClosedStore implements CooldownStore {
  constructor(private readonly reason: string) {}
  private fail(): never {
    throw new Error(this.reason);
  }
  async get(): Promise<number | undefined> {
    return this.fail();
  }
  async set(): Promise<void> {
    return this.fail();
  }
  async delete(): Promise<void> {
    return this.fail();
  }
  async reserve(): Promise<boolean> {
    return this.fail();
  }
  async release(): Promise<void> {
    return this.fail();
  }
  async incrWithTtl(): Promise<number> {
    return this.fail();
  }
  async decr(): Promise<void> {
    return this.fail();
  }
}

// Mirrors the route's L-11 production check (kept local to avoid an import
// cycle: route.ts imports from this module).
function isProductionEnv(): boolean {
  return process.env.NODE_ENV === "production" || process.env.VERCEL_ENV === "production";
}

// Backend selection. Reads env at call time so a test can flip it; in practice
// this is evaluated once per cold start.
//   - Upstash REST creds present -> cross-instance adapter (dependency-free
//     fetch client; no npm dep to install or fail to load).
//   - Production WITHOUT creds    -> FailClosedStore (never silently per-instance).
//   - Dev/test                    -> in-memory fallback.
export function createCooldownStore(): CooldownStore {
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (url && token) {
    // Cross-instance + atomic backend over the Upstash REST protocol, via the
    // built-in fetch client above. No dynamic require / no @upstash/redis dep,
    // so this can no longer fail-closed merely because a package wasn't
    // installed at deploy time — the previous deferral left the live faucet
    // returning 500s (creds set, package absent -> require threw).
    return new UpstashCooldownStore(new FetchUpstashRedis(url, token));
  }
  if (isProductionEnv()) {
    return new FailClosedStore(
      "M-3: a cross-instance faucet store is required in production. Set UPSTASH_REDIS_REST_URL and UPSTASH_REDIS_REST_TOKEN. Refusing to serve the faucet on a per-instance store.",
    );
  }
  return new MemoryCooldownStore();
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
  return `faucet:addr:${recipient.toLowerCase()}`;
}

function ipKey(ip: string): string {
  return `faucet:ip:${ip}`;
}

function reserveAddrKey(recipient: string): string {
  return `faucet:inflight:addr:${recipient.toLowerCase()}`;
}

function reserveIpKey(ip: string): string {
  return `faucet:inflight:ip:${ip}`;
}

const BUDGET_KEY = "faucet:budget:hourly";

// How long an in-flight reservation may be held before it auto-expires (so a
// crashed request can't lock a slot forever). Comfortably longer than a 7-tx
// broadcast batch on a slow testnet RPC.
export const INFLIGHT_TTL_MS = 60_000;

export async function checkRateLimit(
  store: CooldownStore,
  recipient: string,
  ip: string | undefined,
  now: number = Date.now(),
  cooldownMs: number = COOLDOWN_MS,
): Promise<RateLimitResult> {
  const lastAddr = await store.get(addrKey(recipient));
  if (lastAddr !== undefined && now - lastAddr < cooldownMs) {
    return {
      ok: false,
      blockedBy: "address",
      retryAfterSec: Math.ceil((cooldownMs - (now - lastAddr)) / 1000),
    };
  }
  if (ip) {
    const lastIp = await store.get(ipKey(ip));
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

export async function recordClaim(
  store: CooldownStore,
  recipient: string,
  ip: string | undefined,
  now: number = Date.now(),
  cooldownMs: number = COOLDOWN_MS,
): Promise<void> {
  await store.set(addrKey(recipient), now, cooldownMs);
  if (ip) await store.set(ipKey(ip), now, cooldownMs);
}

// M-2 (audit 2026-05-31): undo a recordClaim. The route records the claim
// BEFORE broadcasting so a partial mint failure still consumes the cooldown;
// this rollback is called only when ZERO tokens were broadcast, restoring the
// user's ability to retry immediately.
export async function rollbackClaim(
  store: CooldownStore,
  recipient: string,
  ip: string | undefined,
): Promise<void> {
  await store.delete(addrKey(recipient));
  if (ip) await store.delete(ipKey(ip));
}

export interface ReserveResult {
  ok: boolean;
  /** Keys that WERE acquired (so the caller can release exactly those). */
  acquired: string[];
}

// M-3: atomically reserve the in-flight slots for BOTH the address and the IP.
// If the address slot is taken we don't even try the IP. If the address slot
// is acquired but the IP slot is already held, we release the address slot and
// fail — so a partial reservation never leaks. On Upstash each reserve is a
// `SET NX PX`, making this cross-instance race-safe.
export async function reserveInflight(
  store: CooldownStore,
  recipient: string,
  ip: string | undefined,
  ttlMs: number = INFLIGHT_TTL_MS,
): Promise<ReserveResult> {
  const aKey = reserveAddrKey(recipient);
  const gotAddr = await store.reserve(aKey, ttlMs);
  if (!gotAddr) return { ok: false, acquired: [] };

  if (ip) {
    const iKey = reserveIpKey(ip);
    const gotIp = await store.reserve(iKey, ttlMs);
    if (!gotIp) {
      await store.release(aKey);
      return { ok: false, acquired: [] };
    }
    return { ok: true, acquired: [aKey, iKey] };
  }
  return { ok: true, acquired: [aKey] };
}

export async function releaseInflight(
  store: CooldownStore,
  acquired: string[],
): Promise<void> {
  await Promise.all(acquired.map((k) => store.release(k)));
}

export interface BudgetResult {
  ok: boolean;
  count: number;
}

// M-3: consume one unit of the global hourly mint budget. Returns ok=false
// once the budget for the current window is exhausted. The TTL is set on the
// first increment so the window rolls hourly.
export async function consumeHourlyBudget(
  store: CooldownStore,
  budget: number = HOURLY_BUDGET,
  windowSec: number = BUDGET_WINDOW_SEC,
): Promise<BudgetResult> {
  const count = await store.incrWithTtl(BUDGET_KEY, windowSec);
  return { ok: count <= budget, count };
}

// Refund one unit of the hourly budget when a claim is rolled back (zero
// tokens broadcast). Best-effort: a rollback only happens on total mint
// failure, so any skew is tiny and bounded by the window TTL.
export async function refundHourlyBudget(store: CooldownStore): Promise<void> {
  await store.decr(BUDGET_KEY);
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
