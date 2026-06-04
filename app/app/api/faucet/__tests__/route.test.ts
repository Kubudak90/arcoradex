import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// ---------------------------------------------------------------------------
// Mocks. The faucet route imports viem (clients), viem/accounts (signer),
// botid/server (bot check) and @arcoralabs/dex-sdk (chain). We stub all of
// them so the handler runs in-process with no network. `writeContract` is the
// knob each test turns to simulate a clean batch, a mid-batch failure, or a
// total failure on the first token.
// ---------------------------------------------------------------------------

const writeContract = vi.fn();
const getTransactionCount = vi.fn(async () => 0);
const waitForTransactionReceipt = vi.fn(async () => ({ status: "success" }));

vi.mock("viem", async (importOriginal) => {
  const actual = await importOriginal<typeof import("viem")>();
  return {
    ...actual,
    createPublicClient: () => ({ getTransactionCount, waitForTransactionReceipt }),
    createWalletClient: () => ({ writeContract }),
    http: () => ({}),
  };
});

vi.mock("viem/accounts", () => ({
  privateKeyToAccount: () => ({
    address: "0xA400dBafeEb4e14B2836B5D7D040DbB4DcA164E4" as `0x${string}`,
  }),
}));

// botid is dynamic; default to "not a bot". Individual tests can re-stub.
const checkBotId = vi.fn(async () => ({ isBot: false }));
vi.mock("botid/server", () => ({ checkBotId: () => checkBotId() }));

// Only `arcTestnet` is consumed from the SDK by the route.
vi.mock("@arcoralabs/dex-sdk", () => ({
  arcTestnet: { id: 5042002, name: "Arc Testnet" },
}));

const RECIPIENT = "0x1111111111111111111111111111111111111111";
const IP = "203.0.113.9";

function mkReq(body: unknown): Request {
  return new Request("https://app.test/api/faucet", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-forwarded-for": IP,
    },
    body: JSON.stringify(body),
  });
}

// The route module holds module-level state (cooldown store + in-flight sets).
// We re-import a fresh copy per test so claims don't leak across cases.
async function loadRoute() {
  vi.resetModules();
  return import("../route");
}

describe("POST /api/faucet", () => {
  beforeEach(() => {
    process.env.FAUCET_PRIVATE_KEY = "0x" + "1".repeat(64);
    delete process.env.NEXT_PUBLIC_APP_URL;
    writeContract.mockReset();
    getTransactionCount.mockReset().mockResolvedValue(0);
    waitForTransactionReceipt.mockReset().mockResolvedValue({ status: "success" });
    checkBotId.mockReset().mockResolvedValue({ isBot: false });
    // I-12 logs the raw error server-side via console.error; suppress it so the
    // expected-failure tests don't spam the runner output.
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("M-2: a partial mint failure still records the claim (immediate re-POST is rate-limited)", async () => {
    const { POST } = await loadRoute();

    // First token succeeds, second throws → at least one tx broadcast, so the
    // claim must NOT be rolled back.
    let calls = 0;
    writeContract.mockImplementation(async () => {
      calls += 1;
      if (calls >= 2) throw new Error("RPC: nonce too low; insufficient funds 0xdeadbeef");
      return ("0x" + "a".repeat(64)) as `0x${string}`;
    });

    const res1 = await POST(mkReq({ address: RECIPIENT }));
    expect(res1.status).toBe(502);

    // Re-POST immediately: the partial-failure claim was recorded, so this is
    // blocked by the rate limiter (NOT another 7-tx batch).
    const res2 = await POST(mkReq({ address: RECIPIENT }));
    expect(res2.status).toBe(429);
  });

  it("I-12: the 502 body is generic and never leaks raw RPC/viem text", async () => {
    const { POST } = await loadRoute();

    writeContract.mockImplementation(async () => {
      throw new Error("RPC: nonce too low; insufficient funds 0xdeadbeef");
    });

    const res = await POST(mkReq({ address: RECIPIENT }));
    const body = (await res.json()) as { ok: boolean; error: string };

    expect(res.status).toBe(502);
    expect(body.ok).toBe(false);
    expect(body.error).toBe("Faucet mint failed, please try again later.");
    // No raw error detail.
    expect(body.error).not.toContain("nonce");
    expect(body.error).not.toContain("0xdeadbeef");
    expect(body.error).not.toContain("RPC");
  });

  it("M-2: a total failure on the FIRST token rolls the claim back (retry allowed)", async () => {
    const { POST } = await loadRoute();

    // Every writeContract throws → zero tokens broadcast → rollback. A retry
    // should be allowed to proceed (and fail again the same way), NOT 429.
    writeContract.mockImplementation(async () => {
      throw new Error("RPC: connection refused");
    });

    const res1 = await POST(mkReq({ address: RECIPIENT }));
    expect(res1.status).toBe(502);

    const res2 = await POST(mkReq({ address: RECIPIENT }));
    // Still a mint failure (502), NOT a cooldown lockout (429): the claim was
    // rolled back because nothing broadcast.
    expect(res2.status).toBe(502);
  });

  it("happy path: all tokens broadcast → 200 with tx hashes and the claim is recorded", async () => {
    const { POST } = await loadRoute();

    let n = 0;
    writeContract.mockImplementation(async () => {
      n += 1;
      return ("0x" + n.toString(16).padStart(64, "0")) as `0x${string}`;
    });

    const res1 = await POST(mkReq({ address: RECIPIENT }));
    const body1 = (await res1.json()) as { ok: boolean; txHashes: Record<string, string> };
    expect(res1.status).toBe(200);
    expect(body1.ok).toBe(true);
    expect(Object.keys(body1.txHashes).length).toBeGreaterThan(0);

    // Re-POST is rate-limited.
    const res2 = await POST(mkReq({ address: RECIPIENT }));
    expect(res2.status).toBe(429);
  });
});

describe("L-11: origin allowlist fail-closed in production", () => {
  const ORIGINAL_NODE_ENV = process.env.NODE_ENV;
  const ORIGINAL_VERCEL_ENV = process.env.VERCEL_ENV;

  // Next narrows process.env.NODE_ENV to a readonly union; cast through a
  // mutable record so the test can flip it between prod/dev.
  const mutableEnv = process.env as Record<string, string | undefined>;

  beforeEach(() => {
    process.env.FAUCET_PRIVATE_KEY = "0x" + "1".repeat(64);
    delete process.env.NEXT_PUBLIC_APP_URL;
    writeContract.mockReset().mockImplementation(async () => ("0x" + "a".repeat(64)) as `0x${string}`);
    getTransactionCount.mockReset().mockResolvedValue(0);
    waitForTransactionReceipt.mockReset().mockResolvedValue({ status: "success" });
    checkBotId.mockReset().mockResolvedValue({ isBot: false });
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
    // Restore env (assignment works in the node test env).
    mutableEnv.NODE_ENV = ORIGINAL_NODE_ENV;
    if (ORIGINAL_VERCEL_ENV === undefined) delete process.env.VERCEL_ENV;
    else process.env.VERCEL_ENV = ORIGINAL_VERCEL_ENV;
  });

  it("prod (VERCEL_ENV=production) + unset allowlist → 403", async () => {
    process.env.VERCEL_ENV = "production";
    delete process.env.NEXT_PUBLIC_APP_URL;
    const { POST } = await loadRoute();

    const res = await POST(mkReq({ address: RECIPIENT }));
    const body = (await res.json()) as { ok: boolean; error: string };
    expect(res.status).toBe(403);
    expect(body.ok).toBe(false);
    // The mint loop must NOT have run — fail-closed before broadcasting.
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("prod (NODE_ENV=production) + unset allowlist → 403", async () => {
    mutableEnv.NODE_ENV = "production";
    delete process.env.VERCEL_ENV;
    delete process.env.NEXT_PUBLIC_APP_URL;
    const { POST } = await loadRoute();

    const res = await POST(mkReq({ address: RECIPIENT }));
    expect(res.status).toBe(403);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("dev + unset allowlist → request is allowed (origin check skipped)", async () => {
    mutableEnv.NODE_ENV = "development";
    delete process.env.VERCEL_ENV;
    delete process.env.NEXT_PUBLIC_APP_URL;
    const { POST } = await loadRoute();

    const res = await POST(mkReq({ address: RECIPIENT }));
    // Not 403 — the dev path is permissive and proceeds to mint.
    expect(res.status).toBe(200);
    expect(writeContract).toHaveBeenCalled();
  });

  it("prod + matching allowlist origin → allowed", async () => {
    process.env.VERCEL_ENV = "production";
    process.env.NEXT_PUBLIC_APP_URL = "https://app.test";
    const { POST } = await loadRoute();

    const req = new Request("https://app.test/api/faucet", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-forwarded-for": IP,
        origin: "https://app.test",
      },
      body: JSON.stringify({ address: RECIPIENT }),
    });
    const res = await POST(req);
    expect(res.status).toBe(200);
  });
});
