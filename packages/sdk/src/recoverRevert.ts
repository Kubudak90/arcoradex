import type { Abi, PublicClient, TransactionReceipt } from "viem";
import { ArcoraDexError, parseContractError } from "./errors";

export interface SimulationCall {
  address: `0x${string}`;
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
  account: `0x${string}`;
}

/**
 * Re-simulate a write call against the block where it reverted, surface the
 * recovered revert reason as an `ArcoraDexError`, and rethrow. Always throws.
 *
 * Why this exists: viem's `writeContract` does NOT simulate before sending
 * when called through the wagmi mock connector or most live wallet connectors
 * (the simulate hook is only attached on the local `privateKeyToAccount` path).
 * If the transaction reverts, `waitForTransactionReceipt` returns a receipt
 * with `status: "reverted"` and an empty `logs` array — the SDK then loses the
 * typed revert reason. Re-simulating at the receipt's block reproduces the
 * exact pre-revert state so `parseContractError` can turn it into one of the
 * typed errors (`EarlyWithdrawError`, `OracleStaleError`, etc.).
 */
export async function recoverRevertReason(
  publicClient: PublicClient,
  receipt: TransactionReceipt,
  call: SimulationCall,
): Promise<never> {
  try {
    await publicClient.simulateContract({
      address: call.address,
      abi: call.abi,
      functionName: call.functionName,
      args: call.args as readonly unknown[],
      account: call.account,
      blockNumber: receipt.blockNumber,
    });
  } catch (e) {
    throw parseContractError(e);
  }
  // Simulation didn't reproduce the revert — surface a generic but
  // diagnostically useful error rather than swallowing it.
  throw new ArcoraDexError(
    `Transaction reverted (hash ${receipt.transactionHash}) but the cause could not be reproduced via simulation.`,
  );
}

/**
 * No-op if `receipt.status === "success"`. Otherwise re-simulates the call
 * via `recoverRevertReason` and throws.
 */
export async function assertReceiptOk(
  publicClient: PublicClient,
  receipt: TransactionReceipt,
  call: SimulationCall,
): Promise<void> {
  if (receipt.status === "reverted") {
    await recoverRevertReason(publicClient, receipt, call);
  }
}
