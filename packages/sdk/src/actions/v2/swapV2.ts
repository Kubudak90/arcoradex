import { decodeEventLog, type Log } from "viem";
import type { ArcoraDexClientV2 } from "../../clientV2";
import type { ArcoraDexClient } from "../../client";
import type { SwapResultV2, SwappedEventV2 } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { ensureAllowance } from "../../allowance";
import { minOut, deadline as defaultDeadline } from "../../slippage";
import { quoteSwapV2 } from "./quoteSwapV2";
import { MissingAccountError } from "../../errors";
import { parseContractErrorV2 } from "../../errors.v2";
import { assertReceiptOk } from "../../recoverRevert";

export interface SwapV2Args {
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  amountIn: bigint;
  slippageBps: number;
  deadline?: bigint;
  recipient?: `0x${string}`;
  exactApproval?: boolean;
}

export async function swapV2(
  client: ArcoraDexClientV2,
  args: SwapV2Args,
): Promise<SwapResultV2> {
  if (!client.walletClient || !client.account) throw new MissingAccountError();

  // `ensureAllowance` is the AUDITED V1 helper, reused byte-for-byte (it only
  // reads the structural fields — walletClient/account/publicClient/addresses/
  // chain — that ArcoraDexClientV2 shares). Its param is nominally typed to the
  // V1 ArcoraDexClient, so we narrow through the shared structural subset.
  const { approveHash } = await ensureAllowance(
    client as unknown as ArcoraDexClient,
    args.tokenIn,
    client.addresses.pool,
    args.amountIn,
    args.exactApproval ?? false,
  );

  // §9: refresh the quote immediately before submission.
  const quote = await quoteSwapV2(client, {
    tokenIn: args.tokenIn,
    tokenOut: args.tokenOut,
    amountIn: args.amountIn,
  });
  const minAmountOut = minOut(quote.amountOut, args.slippageBps);
  const dl = args.deadline ?? defaultDeadline();
  const recipient = args.recipient ?? client.account.address;

  let hash: `0x${string}`;
  try {
    hash = await client.walletClient.writeContract({
      chain: client.chain,
      account: client.account,
      address: client.addresses.pool,
      abi: poolAbiV2,
      functionName: "swap",
      args: [args.tokenIn, args.tokenOut, args.amountIn, minAmountOut, dl, recipient],
    });
  } catch (e) {
    throw parseContractErrorV2(e);
  }

  const receipt = await client.publicClient.waitForTransactionReceipt({ hash });
  // H-4 (audit 2026-05-24): recover typed revert reason from reverted receipts.
  // See packages/sdk/src/recoverRevert.ts for the why.
  await assertReceiptOk(client.publicClient, receipt, {
    address: client.addresses.pool,
    abi: poolAbiV2,
    functionName: "swap",
    args: [args.tokenIn, args.tokenOut, args.amountIn, minAmountOut, dl, recipient],
    account: client.account.address,
  });
  const event = decodeSwappedV2(receipt.logs as Log[], client.addresses.pool);
  const result: SwapResultV2 = { hash, receipt, amountOut: event.amountOut, event };
  if (approveHash) result.approveHash = approveHash;
  return result;
}

function decodeSwappedV2(logs: Log[], pool: `0x${string}`): SwappedEventV2 {
  for (const log of logs) {
    if (log.address.toLowerCase() !== pool.toLowerCase()) continue;
    try {
      const d = decodeEventLog({ abi: poolAbiV2, data: log.data, topics: log.topics });
      if (d.eventName === "Swapped") {
        const a = d.args;
        return {
          user: a.user,
          tokenIn: a.tokenIn,
          tokenOut: a.tokenOut,
          amountIn: a.amountIn,
          amountOut: a.amountOut,
          feeUsd1e18: a.feeUsd1e18,
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
  throw new Error("V2 Swapped event not found in receipt logs.");
}
