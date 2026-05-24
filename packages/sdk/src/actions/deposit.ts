import { decodeEventLog } from "viem";
import type { Log } from "viem";
import type { ArcoraDexClient } from "../client";
import type { DepositResult, DepositedEvent } from "../types";
import { poolAbi } from "../abi/pool";
import { ensureAllowance } from "../allowance";
import { minOut, deadline as defaultDeadline } from "../slippage";
import { quoteDeposit } from "./quoteDeposit";
import { MissingAccountError, parseContractError } from "../errors";
import { assertReceiptOk } from "../recoverRevert";

export interface DepositArgs {
  token: `0x${string}`;
  amount: bigint;
  slippageBps: number;
  deadline?: bigint;
  exactApproval?: boolean;
}

export async function deposit(
  client: ArcoraDexClient,
  args: DepositArgs,
): Promise<DepositResult> {
  if (!client.walletClient || !client.account) throw new MissingAccountError();

  const { approveHash } = await ensureAllowance(
    client,
    args.token,
    client.addresses.pool,
    args.amount,
    args.exactApproval ?? false,
  );

  const quoted = await quoteDeposit(client, { token: args.token, amount: args.amount });
  const minLpOut = minOut(quoted, args.slippageBps);
  const dl = args.deadline ?? defaultDeadline();

  let hash: `0x${string}`;
  try {
    hash = await client.walletClient.writeContract({
      chain: client.chain,
      account: client.account,
      address: client.addresses.pool,
      abi: poolAbi,
      functionName: "deposit",
      args: [args.token, args.amount, minLpOut, dl],
    });
  } catch (e) {
    throw parseContractError(e);
  }

  const receipt = await client.publicClient.waitForTransactionReceipt({ hash });
  // H-4 (audit 2026-05-24): recover typed revert reason from reverted receipts.
  // See packages/sdk/src/recoverRevert.ts for the why.
  await assertReceiptOk(client.publicClient, receipt, {
    address: client.addresses.pool,
    abi: poolAbi,
    functionName: "deposit",
    args: [args.token, args.amount, minLpOut, dl],
    account: client.account.address,
  });
  const event = decodeDepositedEvent(receipt.logs as Log[], client.addresses.pool);
  const result: DepositResult = { hash, receipt, lpMinted: event.lpMinted, event };
  if (approveHash) result.approveHash = approveHash;
  return result;
}

function decodeDepositedEvent(logs: Log[], pool: `0x${string}`): DepositedEvent {
  for (const log of logs) {
    if (log.address.toLowerCase() !== pool.toLowerCase()) continue;
    try {
      const decoded = decodeEventLog({ abi: poolAbi, data: log.data, topics: log.topics });
      if (decoded.eventName === "Deposited") {
        const a = decoded.args;
        return {
          user: a.user,
          token: a.token,
          amountIn: a.amountIn,
          lpMinted: a.lpMinted,
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
  throw new Error("Deposited event not found in receipt logs.");
}
