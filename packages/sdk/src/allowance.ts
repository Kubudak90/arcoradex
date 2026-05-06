import { maxUint256 } from "viem";
import type { ArcoraDexClient } from "./client";
import { erc20Abi } from "./abi/erc20";
import { MissingAccountError } from "./errors";

export interface EnsureAllowanceResult {
  approveHash?: `0x${string}`;
}

/** Reads allowance; if insufficient, sends an approve tx and waits for receipt. */
export async function ensureAllowance(
  client: ArcoraDexClient,
  token: `0x${string}`,
  spender: `0x${string}`,
  required: bigint,
  exactApproval = false,
): Promise<EnsureAllowanceResult> {
  if (!client.walletClient || !client.account) throw new MissingAccountError();

  const owner = client.account.address;
  const allowance = await client.publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [owner, spender],
  });
  if (allowance >= required) return {};

  const approveAmount = exactApproval ? required : maxUint256;
  const approveHash = await client.walletClient.writeContract({
    chain: client.chain,
    account: client.account,
    address: token,
    abi: erc20Abi,
    functionName: "approve",
    args: [spender, approveAmount],
  });
  await client.publicClient.waitForTransactionReceipt({ hash: approveHash });
  return { approveHash };
}
