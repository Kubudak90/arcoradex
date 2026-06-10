import { decodeEventLog, type Log } from "viem";
import type { ArcoraDexClientV2 } from "../../clientV2";
import type {
  WithdrawProportionalResult,
  WithdrewProportionalEvent,
} from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { deadline as defaultDeadline } from "../../slippage";
import { MissingAccountError } from "../../errors";
import { parseContractErrorV2 } from "../../errors.v2";
import { assertReceiptOk } from "../../recoverRevert";

export interface WithdrawProportionalV2Args {
  lpAmount: bigint;
  deadline?: bigint;
}

/**
 * The §11 oracle-unsafe fallback. Per §8.3/§11 it requires NO USD valuation, NO
 * token selection, NO `minOut`, and remains available when an oracle is unsafe
 * or the pool is paused — so it deliberately calls NO quote/max/oracle/floor
 * path. This is the path the app switches to on `OracleUnsafeError`.
 */
export async function withdrawProportionalV2(
  client: ArcoraDexClientV2,
  args: WithdrawProportionalV2Args,
): Promise<WithdrawProportionalResult> {
  if (!client.walletClient || !client.account) throw new MissingAccountError();
  const dl = args.deadline ?? defaultDeadline();

  let hash: `0x${string}`;
  try {
    hash = await client.walletClient.writeContract({
      chain: client.chain,
      account: client.account,
      address: client.addresses.pool,
      abi: poolAbiV2,
      functionName: "withdrawProportional",
      args: [args.lpAmount, dl],
    });
  } catch (e) {
    throw parseContractErrorV2(e);
  }

  const receipt = await client.publicClient.waitForTransactionReceipt({ hash });
  // H-4 (audit 2026-05-24): recover typed revert reason from reverted receipts.
  await assertReceiptOk(client.publicClient, receipt, {
    address: client.addresses.pool,
    abi: poolAbiV2,
    functionName: "withdrawProportional",
    args: [args.lpAmount, dl],
    account: client.account.address,
  });
  const event = decodeWithdrewProportional(receipt.logs as Log[], client.addresses.pool);
  // NOTE: `amounts[]` is the function RETURN, not an event field. The event only
  // carries `lpBurned`, so the per-token basket cannot be recovered from the
  // receipt logs. The anvil integration test (Task 9) reads it via
  // `simulateContract` before the write to assert the basket; here it defaults
  // to `[]` (documented, not a stub).
  return { hash, receipt, amounts: [], event };
}

function decodeWithdrewProportional(
  logs: Log[],
  pool: `0x${string}`,
): WithdrewProportionalEvent {
  for (const log of logs) {
    if (log.address.toLowerCase() !== pool.toLowerCase()) continue;
    try {
      const d = decodeEventLog({ abi: poolAbiV2, data: log.data, topics: log.topics });
      if (d.eventName === "WithdrewProportional") {
        const a = d.args;
        return {
          user: a.user,
          lpBurned: a.lpBurned,
          blockNumber: log.blockNumber!,
          txHash: log.transactionHash!,
          logIndex: log.logIndex!,
        };
      }
    } catch {
      // not the right log shape; keep scanning
    }
  }
  throw new Error("V2 WithdrewProportional event not found in receipt logs.");
}
