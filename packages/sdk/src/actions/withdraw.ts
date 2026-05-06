import { decodeEventLog } from "viem";
import type { Log } from "viem";
import type { ArcoraDexClient } from "../client";
import type { WithdrawResult, WithdrewEvent } from "../types";
import { poolAbi } from "../abi/pool";
import { minOut, deadline as defaultDeadline } from "../slippage";
import { quoteWithdraw } from "./quoteWithdraw";
import { MissingAccountError, parseContractError } from "../errors";

export interface WithdrawArgs {
  tokenOut: `0x${string}`;
  lpAmount: bigint;
  slippageBps: number;
  deadline?: bigint;
}

export async function withdraw(
  client: ArcoraDexClient,
  args: WithdrawArgs,
): Promise<WithdrawResult> {
  if (!client.walletClient || !client.account) throw new MissingAccountError();

  const quoted = await quoteWithdraw(client, {
    tokenOut: args.tokenOut,
    lpAmount: args.lpAmount,
  });
  const minTokenOut = minOut(quoted.amountOut, args.slippageBps);
  const dl = args.deadline ?? defaultDeadline();

  let hash: `0x${string}`;
  try {
    hash = await client.walletClient.writeContract({
      chain: client.chain,
      account: client.account,
      address: client.addresses.pool,
      abi: poolAbi,
      functionName: "withdraw",
      args: [args.tokenOut, args.lpAmount, minTokenOut, dl],
    });
  } catch (e) {
    throw parseContractError(e);
  }

  const receipt = await client.publicClient.waitForTransactionReceipt({ hash });
  const event = decodeWithdrewEvent(receipt.logs as Log[], client.addresses.pool);
  return { hash, receipt, amountOut: event.amountOut, event };
}

function decodeWithdrewEvent(logs: Log[], pool: `0x${string}`): WithdrewEvent {
  for (const log of logs) {
    if (log.address.toLowerCase() !== pool.toLowerCase()) continue;
    try {
      const decoded = decodeEventLog({ abi: poolAbi, data: log.data, topics: log.topics });
      if (decoded.eventName === "Withdrew") {
        const a = decoded.args;
        return {
          user: a.user,
          tokenOut: a.tokenOut,
          lpBurned: a.lpBurned,
          amountOut: a.amountOut,
          protocolFee: a.protocolFee,
          navBefore1e18: a.navBefore1e18,
          navAfter1e18: a.navAfter1e18,
          blockNumber: log.blockNumber!,
          txHash: log.transactionHash!,
          logIndex: log.logIndex!,
        };
      }
    } catch {
      // not the right log shape
    }
  }
  throw new Error("Withdrew event not found in receipt logs.");
}
