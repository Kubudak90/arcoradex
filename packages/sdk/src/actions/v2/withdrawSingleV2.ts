import { decodeEventLog, type Log } from "viem";
import type { ArcoraDexClientV2 } from "../../clientV2";
import type { WithdrawSingleResult, WithdrewSingleEvent } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { minOut, deadline as defaultDeadline } from "../../slippage";
import { quoteWithdrawV2 } from "./quoteWithdrawV2";
import { maxWithdraw } from "./maxWithdraw";
import { MissingAccountError } from "../../errors";
import { parseContractErrorV2, ReserveFloorBreachedError } from "../../errors.v2";
import { assertReceiptOk } from "../../recoverRevert";

export interface WithdrawSingleV2Args {
  tokenOut: `0x${string}`;
  lpAmount: bigint;
  slippageBps: number;
  deadline?: bigint;
}

export async function withdrawSingleV2(
  client: ArcoraDexClientV2,
  args: WithdrawSingleV2Args,
): Promise<WithdrawSingleResult> {
  if (!client.walletClient || !client.account) throw new MissingAccountError();

  // §9: never submit an over-max single-token withdrawal (contract floor is the
  // final enforcement; this is the client-side guard the app's Max relies on).
  const max = await maxWithdraw(client, args.tokenOut, client.account.address);
  if (args.lpAmount > max.lpAmount) throw new ReserveFloorBreachedError(args.tokenOut);

  // §9: refresh the quote immediately before submission.
  const quote = await quoteWithdrawV2(client, {
    tokenOut: args.tokenOut,
    lpAmount: args.lpAmount,
  });
  const minTokenOut = minOut(quote.amountOut, args.slippageBps);
  const dl = args.deadline ?? defaultDeadline();

  let hash: `0x${string}`;
  try {
    hash = await client.walletClient.writeContract({
      chain: client.chain,
      account: client.account,
      address: client.addresses.pool,
      abi: poolAbiV2,
      functionName: "withdrawSingle",
      args: [args.tokenOut, args.lpAmount, minTokenOut, dl],
    });
  } catch (e) {
    throw parseContractErrorV2(e);
  }

  const receipt = await client.publicClient.waitForTransactionReceipt({ hash });
  // H-4 (audit 2026-05-24): recover typed revert reason from reverted receipts.
  await assertReceiptOk(client.publicClient, receipt, {
    address: client.addresses.pool,
    abi: poolAbiV2,
    functionName: "withdrawSingle",
    args: [args.tokenOut, args.lpAmount, minTokenOut, dl],
    account: client.account.address,
  });
  const event = decodeWithdrewSingle(receipt.logs as Log[], client.addresses.pool);
  return { hash, receipt, amountOut: event.amountOut, event };
}

function decodeWithdrewSingle(logs: Log[], pool: `0x${string}`): WithdrewSingleEvent {
  for (const log of logs) {
    if (log.address.toLowerCase() !== pool.toLowerCase()) continue;
    try {
      const d = decodeEventLog({ abi: poolAbiV2, data: log.data, topics: log.topics });
      if (d.eventName === "WithdrewSingle") {
        const a = d.args;
        return {
          user: a.user,
          tokenOut: a.tokenOut,
          lpBurned: a.lpBurned,
          amountOut: a.amountOut,
          protocolFee: a.protocolFee,
          feeUsd1e18: a.feeUsd1e18,
          blockNumber: log.blockNumber!,
          txHash: log.transactionHash!,
          logIndex: log.logIndex!,
        };
      }
    } catch {
      // not the right log shape; keep scanning
    }
  }
  throw new Error("V2 WithdrewSingle event not found in receipt logs.");
}
