import { describe, it, expect, vi } from "vitest";
import { ensureAllowance } from "@/allowance";
import { UntrustedSpenderError } from "@/errors";

const POOL = "0xpoOL00000000000000000000000000000000aaaa" as `0x${string}`;
const LP = "0x1111111111111111111111111111111111111111" as `0x${string}`;
const TOKEN = "0x2222222222222222222222222222222222222222" as `0x${string}`;
const OWNER = "0x3333333333333333333333333333333333333333" as `0x${string}`;

// Builds a stub ArcoraDexClient whose publicClient.readContract returns scripted
// values. `minter` is what LP.MINTER() returns — the canonical-pool anchor (I-9).
function makeStub(opts: {
  minter: `0x${string}`;
  allowance?: bigint;
  approve?: ReturnType<typeof vi.fn>;
}) {
  const approve = opts.approve ?? vi.fn(async () => "0xapprovehash");
  return {
    chain: { id: 1 },
    account: { address: OWNER },
    addresses: { pool: POOL },
    walletClient: { writeContract: approve },
    publicClient: {
      readContract: async (req: { functionName: string }) => {
        switch (req.functionName) {
          case "allowance":
            return opts.allowance ?? 0n;
          case "LP":
            return LP;
          case "MINTER":
            return opts.minter;
          default:
            throw new Error(`unexpected read: ${req.functionName}`);
        }
      },
      waitForTransactionReceipt: async () => ({}),
    },
  } as never;
}

describe("ensureAllowance canonical-pool check (I-9)", () => {
  it("throws UntrustedSpenderError when LP.MINTER() != pool (no approval sent)", async () => {
    const approve = vi.fn(async () => "0xapprovehash" as `0x${string}`);
    const stub = makeStub({
      minter: "0x9999999999999999999999999999999999999999",
      approve,
    });
    await expect(
      ensureAllowance(stub, TOKEN, POOL, 1_000n, false),
    ).rejects.toBeInstanceOf(UntrustedSpenderError);
    // Critically: no approve tx was broadcast.
    expect(approve).not.toHaveBeenCalled();
  });

  it("approves (unlimited by default) when LP.MINTER() === pool", async () => {
    const approve = vi.fn(async () => "0xapprovehash" as `0x${string}`);
    const stub = makeStub({ minter: POOL, approve });
    const res = await ensureAllowance(stub, TOKEN, POOL, 1_000n, false);
    expect(res.approveHash).toBe("0xapprovehash");
    expect(approve).toHaveBeenCalledTimes(1);
  });

  it("skips the approve+check entirely when existing allowance is sufficient", async () => {
    const approve = vi.fn(async () => "0xapprovehash" as `0x${string}`);
    const stub = makeStub({ minter: POOL, allowance: 10_000n, approve });
    const res = await ensureAllowance(stub, TOKEN, POOL, 1_000n, false);
    expect(res).toEqual({});
    expect(approve).not.toHaveBeenCalled();
  });
});
