import { decodeEventLog, type Log } from "viem";
import type { ArcoraDexClientV2 } from "../../clientV2";
import type { ArcoraDexClient } from "../../client";
import type { DepositResultV2 } from "../../types.v2";
import { poolAbiV2 } from "../../abi/v2/pool";
import { ensureAllowance } from "../../allowance";
import { deadline as defaultDeadline } from "../../slippage";
import { MissingAccountError } from "../../errors";
import { parseContractErrorV2 } from "../../errors.v2";
import { assertReceiptOk } from "../../recoverRevert";

export interface DepositV2Args {
  token: `0x${string}`;
  amount: bigint;
  /**
   * Minimum LP shares to mint (slippage floor). The V2 pool exposes NO deposit
   * quote view (only `quoteSwapV2`/`quoteWithdrawV2`), so — unlike V1 `deposit`
   * — there is no re-quote here to derive this; the caller supplies it (and the
   * contract enforces it via `InsufficientLpOut`). Pass `0n` to disable.
   */
  minLpOut: bigint;
  deadline?: bigint;
  exactApproval?: boolean;
}

export async function depositV2(
  client: ArcoraDexClientV2,
  args: DepositV2Args,
): Promise<DepositResultV2> {
  if (!client.walletClient || !client.account) throw new MissingAccountError();

  // `ensureAllowance` is the AUDITED V1 helper, reused byte-for-byte (it only
  // reads the structural fields shared with ArcoraDexClientV2). Narrow through
  // the shared structural subset; see swapV2.ts for the same pattern.
  const { approveHash } = await ensureAllowance(
    client as unknown as ArcoraDexClient,
    args.token,
    client.addresses.pool,
    args.amount,
    args.exactApproval ?? false,
  );

  const dl = args.deadline ?? defaultDeadline();

  let hash: `0x${string}`;
  try {
    hash = await client.walletClient.writeContract({
      chain: client.chain,
      account: client.account,
      address: client.addresses.pool,
      abi: poolAbiV2,
      functionName: "deposit",
      args: [args.token, args.amount, args.minLpOut, dl],
    });
  } catch (e) {
    throw parseContractErrorV2(e);
  }

  const receipt = await client.publicClient.waitForTransactionReceipt({ hash });
  // H-4 (audit 2026-05-24): recover typed revert reason from reverted receipts
  // (DepositCapExceeded, InsufficientLpOut, …). See recoverRevert.ts.
  await assertReceiptOk(client.publicClient, receipt, {
    address: client.addresses.pool,
    abi: poolAbiV2,
    functionName: "deposit",
    args: [args.token, args.amount, args.minLpOut, dl],
    account: client.account.address,
  });
  const lpMinted = decodeDepositedV2(receipt.logs as Log[], client.addresses.pool);
  const result: DepositResultV2 = { hash, receipt, lpMinted };
  if (approveHash) result.approveHash = approveHash;
  return result;
}

function decodeDepositedV2(logs: Log[], pool: `0x${string}`): bigint {
  for (const log of logs) {
    if (log.address.toLowerCase() !== pool.toLowerCase()) continue;
    try {
      const d = decodeEventLog({ abi: poolAbiV2, data: log.data, topics: log.topics });
      if (d.eventName === "Deposited") return d.args.lpMinted;
    } catch {
      // not the right log shape; keep scanning
    }
  }
  throw new Error("V2 Deposited event not found in receipt logs.");
}
