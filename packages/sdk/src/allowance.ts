import { getAddress, maxUint256 } from "viem";
import type { ArcoraDexClient } from "./client";
import { erc20Abi } from "./abi/erc20";
import { poolAbi } from "./abi/pool";
import { lpAbi } from "./abi/lp";
import { MissingAccountError, UntrustedSpenderError } from "./errors";

export interface EnsureAllowanceResult {
  approveHash?: `0x${string}`;
}

/**
 * Reads the ERC-20 allowance for `spender`; if it is below `required`, sends an
 * `approve` tx and waits for its receipt.
 *
 * ⚠️ UNLIMITED-APPROVAL DEFAULT (I-9, audit 2026-05-31): when
 * `exactApproval` is `false` (the DEFAULT), this approves `maxUint256` — an
 * UNLIMITED, never-expiring allowance to `spender`. This is a deliberate UX
 * trade-off (one approval covers all future swaps/deposits without re-prompting
 * the wallet) but it means the spender can pull the FULL token balance at any
 * later time. Callers that want a bounded approval (only `required`) MUST pass
 * `exactApproval: true`.
 *
 * To bound the blast radius of that unlimited approval, this function will only
 * approve to a CANONICAL ArcoraDex pool: before sending the approve it verifies
 * `spender` is a real pool by reading the pool's LP token and asserting
 * `LP.MINTER() === spender` (the LP's minter is, by construction, its own pool).
 * On mismatch it throws {@link UntrustedSpenderError} and sends NO approval.
 * The anchor check only runs when `spender === client.addresses.pool`; other
 * spenders are passed through unchecked (the SDK only ever calls this with the
 * configured pool).
 */
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

  // I-9: anchor-check the spender before approving (especially an unlimited
  // approval). Only enforced for the configured pool spender.
  if (eqAddr(spender, client.addresses.pool)) {
    await assertCanonicalPool(client, spender);
  }

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

function eqAddr(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

/**
 * Verifies `pool` is a canonical ArcoraDex pool: read its LP token, then read
 * that LP's immutable `MINTER()` and require it to equal `pool`. Any read
 * failure or mismatch throws {@link UntrustedSpenderError}.
 */
async function assertCanonicalPool(
  client: ArcoraDexClient,
  pool: `0x${string}`,
): Promise<void> {
  let lp: `0x${string}`;
  try {
    lp = await client.publicClient.readContract({
      address: pool,
      abi: poolAbi,
      functionName: "LP",
    });
  } catch {
    throw new UntrustedSpenderError(pool, "pool.LP() is not readable");
  }

  let minter: `0x${string}`;
  try {
    minter = await client.publicClient.readContract({
      address: lp,
      abi: lpAbi,
      functionName: "MINTER",
    });
  } catch {
    throw new UntrustedSpenderError(pool, "LP.MINTER() is not readable");
  }

  if (!eqAddr(minter, pool)) {
    throw new UntrustedSpenderError(
      pool,
      `LP(${getAddress(lp)}).MINTER()=${getAddress(minter)} != pool`,
    );
  }
}
