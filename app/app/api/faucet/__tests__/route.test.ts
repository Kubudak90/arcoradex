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

// The chain-aware route consumes `baseSepolia` + `arcTestnet` from the SDK V2
// entrypoint (chain object + default RPC per supported chain id).
vi.mock("@arcoralabs/dex-sdk/v2", () => ({
  baseSepolia: {
    id: 84532,
    name: "Base Sepolia",
    rpcUrls: { default: { http: ["https://base-sepolia-rpc.publicnode.com"] } },
  },
  arcTestnet: {
    id: 5042002,
    name: "Arc Testnet",
    rpcUrls: { default: { http: ["https://rpc.testnet.arc.network"] } },
  },
}));

// Route tests exercise the HANDLER with a working store. The real backend
// selection — including M-3 production fail-closed when no cross-instance store
// is configured — is unit-tested in lib/__tests__/faucet-rate-limit.test.ts.
// Force the in-memory store here so prod-env route tests don't fail closed on
// the (deploy-time) @upstash/redis dependency, which the route loads via a CJS
// require() that vi.mock cannot intercept.
vi.mock("@/lib/faucet-rate-limit", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/faucet-rate-limit")>();
  return { ...actual, createCooldownStore: () => new actual.MemoryCooldownStore() };
});

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

describe("chain-aware minting (Base Sepolia 84532 + Arc testnet 5042002)", () => {
  const BASE_TOKEN_ADDRESSES = [
    "0x3a98d8adC295d90171e9DA93D411dEa95674c867", // USDC
    "0x7110315D229C7CE655399703ACbA8E67f1d5C0c0", // USDT
    "0x4b1F2D659DAD4B791414fF4323bCd17C218b8bD7", // EURC
  ];
  const ARC_TOKEN_ADDRESSES = [
    "0x168655bc42265d8721AD6BCe20435919A0160B79", // USDC
    "0xD05FE3e0A38508b182143E1eBf69C657a87cBe22", // USDT
    "0xb1D82C6ba72CfE115Baa0Cd33De78224D9370Eea", // EURC
  ];

  beforeEach(() => {
    process.env.FAUCET_PRIVATE_KEY = "0x" + "1".repeat(64);
    delete process.env.NEXT_PUBLIC_APP_URL;
    let n = 0;
    writeContract.mockReset().mockImplementation(async () => {
      n += 1;
      return ("0x" + n.toString(16).padStart(64, "0")) as `0x${string}`;
    });
    getTransactionCount.mockReset().mockResolvedValue(0);
    waitForTransactionReceipt.mockReset().mockResolvedValue({ status: "success" });
    checkBotId.mockReset().mockResolvedValue({ isBot: false });
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("omitted chainId defaults to Base Sepolia (back-compat)", async () => {
    const { POST } = await loadRoute();

    const res = await POST(mkReq({ address: RECIPIENT }));
    const body = (await res.json()) as { ok: boolean; chainId: number };
    expect(res.status).toBe(200);
    expect(body.chainId).toBe(84532);

    const minted = writeContract.mock.calls.map((c) => (c[0] as { address: string }).address);
    expect(minted).toEqual(BASE_TOKEN_ADDRESSES);
    for (const call of writeContract.mock.calls) {
      expect((call[0] as { chain: { id: number } }).chain.id).toBe(84532);
    }
  });

  it("explicit chainId 84532 mints the Base token set", async () => {
    const { POST } = await loadRoute();

    const res = await POST(mkReq({ address: RECIPIENT, chainId: 84532 }));
    const body = (await res.json()) as { ok: boolean; chainId: number };
    expect(res.status).toBe(200);
    expect(body.ok).toBe(true);
    expect(body.chainId).toBe(84532);

    const minted = writeContract.mock.calls.map((c) => (c[0] as { address: string }).address);
    expect(minted).toEqual(BASE_TOKEN_ADDRESSES);
  });

  it("chainId 5042002 mints the ARC token set on the Arc chain", async () => {
    const { POST } = await loadRoute();

    const res = await POST(mkReq({ address: RECIPIENT, chainId: 5042002 }));
    const body = (await res.json()) as {
      ok: boolean;
      chainId: number;
      txHashes: Record<string, string>;
    };
    expect(res.status).toBe(200);
    expect(body.ok).toBe(true);
    expect(body.chainId).toBe(5042002);
    expect(Object.keys(body.txHashes).sort()).toEqual(["EURC", "USDC", "USDT"]);

    const minted = writeContract.mock.calls.map((c) => (c[0] as { address: string }).address);
    expect(minted).toEqual(ARC_TOKEN_ADDRESSES);
    for (const call of writeContract.mock.calls) {
      expect((call[0] as { chain: { id: number } }).chain.id).toBe(5042002);
    }
  });

  it("unsupported chainId → 400 and nothing is broadcast", async () => {
    const { POST } = await loadRoute();

    const res = await POST(mkReq({ address: RECIPIENT, chainId: 11155111 }));
    const body = (await res.json()) as { ok: boolean; error: string };
    expect(res.status).toBe(400);
    expect(body.ok).toBe(false);
    expect(body.error).toContain("Unsupported chain");
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("non-numeric chainId → 400 and nothing is broadcast", async () => {
    const { POST } = await loadRoute();

    const res = await POST(mkReq({ address: RECIPIENT, chainId: "84532" }));
    expect(res.status).toBe(400);
    expect(writeContract).not.toHaveBeenCalled();
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
    delete process.env.UPSTASH_REDIS_REST_URL;
    delete process.env.UPSTASH_REDIS_REST_TOKEN;
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
    // createCooldownStore is mocked to the in-memory store (see top), so this
    // isolates the L-11 ORIGIN check from M-3 backend selection.
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
