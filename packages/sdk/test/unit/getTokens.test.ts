import { describe, it, expect } from "vitest";
import { getTokens } from "@/actions/getTokens";

// I-8 (audit 2026-05-31): the Registry TokenInfo struct's 5th field
// (uint32 maxStaleSeconds) must round-trip through the SDK decode into
// TokenInfo.maxStaleSeconds. We stub publicClient.readContract so this is a
// pure unit test (no anvil/forge): it returns the decoded tuple viem would
// produce for the 5-field struct, plus the helper reads getTokens makes.
describe("getTokens decode (I-8)", () => {
  it("captures maxStaleSeconds from the TokenInfo struct", async () => {
    const TOKEN = "0x1111111111111111111111111111111111111111" as const;
    const ORACLE = "0x2222222222222222222222222222222222222222" as const;

    const stub = {
      addresses: { registry: "0xregistry" },
      publicClient: {
        // viem decodes a `struct ... returns (TokenInfo)` into an object with
        // the named fields; we mirror that shape here.
        readContract: async (req: {
          functionName: string;
          args?: readonly unknown[];
        }) => {
          switch (req.functionName) {
            case "tokensLength":
              return 1n;
            case "tokens":
              return TOKEN;
            case "tokenInfo":
              return {
                decimals: 6,
                isActive: true,
                usdOracle: ORACLE,
                maxOracleDeviationBps: 150,
                maxStaleSeconds: 14_400,
              };
            case "symbol":
              return "EURC";
            case "name":
              return "Euro Coin";
            default:
              throw new Error(`unexpected read: ${req.functionName}`);
          }
        },
      },
    } as never;

    const tokens = await getTokens(stub);
    expect(tokens).toHaveLength(1);
    const t = tokens[0]!;
    expect(t.decimals).toBe(6);
    expect(t.isActive).toBe(true);
    expect(t.oracle).toBe(ORACLE);
    expect(t.maxOracleDeviationBps).toBe(150);
    // The field under test:
    expect(t.maxStaleSeconds).toBe(14_400);
  });
});
