import { describe, it, expect, vi } from "vitest";
import { subscribeSwaps } from "@/subscriptions/subscribeSwaps";
import { subscribePoolStats } from "@/subscriptions/subscribePoolStats";

const POOL = "0xpoOL00000000000000000000000000000000aaaa" as `0x${string}`;
const USER = "0x1111111111111111111111111111111111111111" as `0x${string}`;
const TIN = "0x2222222222222222222222222222222222222222" as `0x${string}`;
const TOUT = "0x3333333333333333333333333333333333333333" as `0x${string}`;

function swapLog(txHash: string, logIndex: number, removed = false) {
  return {
    args: {
      user: USER,
      tokenIn: TIN,
      tokenOut: TOUT,
      amountIn: 1n,
      amountOut: 1n,
      lpFeeUsd1e18: 0n,
      protocolFeeAmtOut: 0n,
      recipient: USER,
    },
    blockNumber: 1n,
    transactionHash: txHash,
    logIndex,
    removed,
  };
}

// Captures the watchContractEvent params so a test can drive onLogs/onError.
function makeCapturingClient() {
  let captured: { onLogs: (logs: unknown[]) => void; onError?: (e: Error) => void } | undefined;
  const stub = {
    addresses: { pool: POOL },
    publicClient: {
      watchContractEvent: (params: {
        onLogs: (logs: unknown[]) => void;
        onError?: (e: Error) => void;
      }) => {
        captured = params;
        return () => {};
      },
    },
  } as never;
  return { stub, getCaptured: () => captured! };
}

describe("subscribeSwaps dedupe + reorg (audit 2026-05-31)", () => {
  it("invokes the handler once per (txHash, logIndex), ignoring duplicate deliveries", () => {
    const { stub, getCaptured } = makeCapturingClient();
    const handler = vi.fn();
    subscribeSwaps(stub, handler);

    const { onLogs } = getCaptured();
    onLogs([swapLog("0xaaa", 0)]);
    onLogs([swapLog("0xaaa", 0)]); // duplicate poll delivery
    onLogs([swapLog("0xaaa", 1)]); // different logIndex, same tx → distinct

    expect(handler).toHaveBeenCalledTimes(2);
  });

  it("skips removed (reorg) logs and re-fires if the tx is later re-included", () => {
    const { stub, getCaptured } = makeCapturingClient();
    const handler = vi.fn();
    subscribeSwaps(stub, handler);

    const { onLogs } = getCaptured();
    onLogs([swapLog("0xbbb", 0)]); // fires (1)
    onLogs([swapLog("0xbbb", 0, true)]); // reorg rollback → no fire, forget key
    onLogs([swapLog("0xbbb", 0)]); // re-included on canonical chain → fires (2)

    expect(handler).toHaveBeenCalledTimes(2);
  });

  it("forwards onError to the watcher", () => {
    const { stub, getCaptured } = makeCapturingClient();
    const onError = vi.fn();
    subscribeSwaps(stub, vi.fn(), { onError });

    const cap = getCaptured();
    expect(cap.onError).toBe(onError);
    cap.onError!(new Error("rpc down"));
    expect(onError).toHaveBeenCalledOnce();
  });
});

describe("subscribePoolStats onError (audit 2026-05-31)", () => {
  it("routes a failing per-block refresh to onError instead of swallowing", async () => {
    let blockCb: (() => Promise<void>) | undefined;
    const stub = {
      addresses: { pool: POOL },
      publicClient: {
        // getPoolStats reads these; make them throw to simulate an RPC failure.
        readContract: async () => {
          throw new Error("boom");
        },
        watchBlockNumber: (params: { onBlockNumber: () => Promise<void> }) => {
          blockCb = params.onBlockNumber;
          return () => {};
        },
      },
    } as never;

    const handler = vi.fn();
    const onError = vi.fn();
    subscribePoolStats(stub, handler, { onError });

    await blockCb!();

    expect(handler).not.toHaveBeenCalled();
    expect(onError).toHaveBeenCalledOnce();
    expect(onError.mock.calls[0]![0]).toBeInstanceOf(Error);
  });
});
