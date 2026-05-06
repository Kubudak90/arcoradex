"use client";
import { useReadContract, useReadContracts } from "wagmi";
import { registryAbi } from "@/lib/abi/registry";
import { erc20Abi } from "@/lib/abi/erc20";
import { REGISTRY_ADDRESS, tokenLabel } from "@/lib/contracts";
import { useMemo } from "react";

export interface TokenRow {
  address: `0x${string}`;
  symbol: string;
  name: string;
  decimals: number;
  isActive: boolean;
  oracle: `0x${string}`;
  deviationBps: number;
}

/** Reads the registry's full token list (active + inactive) plus their TokenInfo. */
export function useTokens() {
  const { data: lengthRaw, isLoading: lenLoading } = useReadContract({
    address: REGISTRY_ADDRESS,
    abi: registryAbi,
    functionName: "tokensLength",
  });

  const length = lengthRaw ? Number(lengthRaw) : 0;

  // Step 1: pull the addresses
  const { data: addressData } = useReadContracts({
    contracts: Array.from({ length }, (_, i) => ({
      address: REGISTRY_ADDRESS,
      abi: registryAbi,
      functionName: "tokens" as const,
      args: [BigInt(i)] as const,
    })),
    query: { enabled: length > 0 },
  });

  const addresses = useMemo(
    () =>
      (addressData ?? [])
        .map((r) => (r.status === "success" ? (r.result as `0x${string}`) : null))
        .filter((a): a is `0x${string}` => !!a),
    [addressData]
  );

  // Step 2: pull TokenInfo for each
  const { data: infoData, isLoading: infoLoading } = useReadContracts({
    contracts: addresses.map((a) => ({
      address: REGISTRY_ADDRESS,
      abi: registryAbi,
      functionName: "tokenInfo" as const,
      args: [a] as const,
    })),
    query: { enabled: addresses.length > 0 },
  });

  const tokens: TokenRow[] = useMemo(() => {
    if (!addresses.length || !infoData) return [];
    return addresses.flatMap((address, i) => {
      const r = infoData[i];
      if (r.status !== "success") return [];
      const info = r.result as {
        decimals: number;
        isActive: boolean;
        usdOracle: `0x${string}`;
        maxOracleDeviationBps: number;
      };
      const meta = tokenLabel(address);
      return [
        {
          address,
          symbol: meta.symbol,
          name: meta.name,
          decimals: Number(info.decimals),
          isActive: info.isActive,
          oracle: info.usdOracle,
          deviationBps: Number(info.maxOracleDeviationBps),
        },
      ];
    });
  }, [addresses, infoData]);

  const activeTokens = useMemo(() => tokens.filter((t) => t.isActive), [tokens]);

  return {
    tokens,
    activeTokens,
    isLoading: lenLoading || infoLoading,
  };
}

/** Read the user's balance + allowance for a specific token. */
export function useTokenAccount(token: `0x${string}` | undefined, owner: `0x${string}` | undefined, spender: `0x${string}`) {
  const enabled = !!token && !!owner;
  const { data, refetch } = useReadContracts({
    contracts: enabled
      ? [
          { address: token!, abi: erc20Abi, functionName: "balanceOf", args: [owner!] },
          { address: token!, abi: erc20Abi, functionName: "allowance", args: [owner!, spender] },
        ]
      : [],
    query: { enabled },
  });
  const balance = data?.[0]?.status === "success" ? (data[0].result as bigint) : 0n;
  const allowance = data?.[1]?.status === "success" ? (data[1].result as bigint) : 0n;
  return { balance, allowance, refetch };
}
