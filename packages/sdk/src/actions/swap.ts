import { decodeEventLog } from "viem";
import type { Log } from "viem";
import type { ArcoraDexClient } from "../client";
import type { SwapResult, SwappedEvent } from "../types";
import { poolAbi } from "../abi/pool";
import { ensureAllowance } from "../allowance";
import { minOut, deadline as defaultDeadline } from "../slippage";
import { quoteSwap } from "./quoteSwap";
import { MissingAccountError, parseContractError } from "../errors";

export interface SwapArgs {
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  amountIn: bigint;
  slippageBps: number;
  deadline?: bigint;
  recipient?: `0x${string}`;
  exactApproval?: boolean;
}

export async function swap(client: ArcoraDexClient, args: SwapArgs): Promise<SwapResult> {
  if (!client.walletClient || !client.account) throw new MissingAccountError();

  const { approveHash } = await ensureAllowance(
    client,
    args.tokenIn,
    client.addresses.pool,
    args.amountIn,
    args.exactApproval ?? false,
  );

  const quoted = await quoteSwap(client, {
    tokenIn: args.tokenIn,
    tokenOut: args.tokenOut,
    amountIn: args.amountIn,
  });
  const minAmountOut = minOut(quoted, args.slippageBps);
  const dl = args.deadline ?? defaultDeadline();
  const recipient = args.recipient ?? client.account.address;

  let hash: `0x${string}`;
  try {
    hash = await client.walletClient.writeContract({
      chain: client.chain,
      account: client.account,
      address: client.addresses.pool,
      abi: poolAbi,
      functionName: "swap",
      args: [args.tokenIn, args.tokenOut, args.amountIn, minAmountOut, dl, recipient],
    });
  } catch (e) {
    throw parseContractError(e);
  }

  const receipt = await client.publicClient.waitForTransactionReceipt({ hash });
  const event = decodeSwappedEvent(receipt.logs as Log[], client.addresses.pool);
  const result: SwapResult = { hash, receipt, amountOut: event.amountOut, event };
  if (approveHash) result.approveHash = approveHash;
  return result;
}

function decodeSwappedEvent(logs: Log[], pool: `0x${string}`): SwappedEvent {
  for (const log of logs) {
    if (log.address.toLowerCase() !== pool.toLowerCase()) continue;
    try {
      const decoded = decodeEventLog({
        abi: poolAbi,
        data: log.data,
        topics: log.topics,
      });
      if (decoded.eventName === "Swapped") {
        const a = decoded.args;
        return {
          user: a.user,
          tokenIn: a.tokenIn,
          tokenOut: a.tokenOut,
          amountIn: a.amountIn,
          amountOut: a.amountOut,
          lpFeeUsd1e18: a.lpFeeUsd1e18,
          protocolFeeAmtOut: a.protocolFeeAmtOut,
          recipient: a.recipient,
          blockNumber: log.blockNumber!,
          txHash: log.transactionHash!,
          logIndex: log.logIndex!,
        };
      }
    } catch {
      // not the right log shape; keep scanning
    }
  }
  throw new Error("Swapped event not found in receipt logs.");
}
