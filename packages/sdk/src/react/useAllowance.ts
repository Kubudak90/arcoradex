"use client";
import { useEffect, useState } from "react";
import { useReadContract } from "wagmi";
import { useArcoraDex } from "./useArcoraDex";
import { erc20Abi } from "../abi/erc20";
import { ensureAllowance } from "../allowance";

export interface UseAllowanceArgs {
  token?: `0x${string}`;
  spender?: `0x${string}`;
  amount?: bigint;
}

export interface UseAllowanceResult {
  isApprovalNeeded: boolean | null;
  ensureAllowance: (exactApproval?: boolean) => Promise<{ approveHash?: `0x${string}` }>;
  isPending: boolean;
  error: Error | null;
}

export function useAllowance(args: UseAllowanceArgs): UseAllowanceResult {
  const sdk = useArcoraDex();
  const owner = sdk.account?.address;

  const { data: allowanceData, refetch } = useReadContract({
    address: args.token,
    abi: erc20Abi,
    functionName: "allowance",
    args: owner && args.spender ? [owner, args.spender] : undefined,
    query: { enabled: !!owner && !!args.token && !!args.spender },
  });

  const isApprovalNeeded =
    allowanceData !== undefined && args.amount !== undefined
      ? (allowanceData as bigint) < args.amount
      : null;

  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  async function ensureAllowanceFn(
    exactApproval = false,
  ): Promise<{ approveHash?: `0x${string}` }> {
    if (!args.token || !args.spender || args.amount === undefined) {
      throw new Error(
        "useAllowance: token, spender, and amount must all be defined to call ensureAllowance.",
      );
    }
    setIsPending(true);
    setError(null);
    try {
      const result = await ensureAllowance(
        sdk,
        args.token,
        args.spender,
        args.amount,
        exactApproval,
      );
      await refetch();
      return result;
    } catch (e) {
      setError(e as Error);
      throw e;
    } finally {
      setIsPending(false);
    }
  }

  // Refetch allowance whenever the args change.
  useEffect(() => {
    if (owner && args.token && args.spender) refetch();
  }, [owner, args.token, args.spender, refetch]);

  return { isApprovalNeeded, ensureAllowance: ensureAllowanceFn, isPending, error };
}
