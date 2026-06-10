"use client";
import { useQuery } from "@tanstack/react-query";
import { useArcoraDexV2 } from "@arcoralabs/dex-sdk/react/v2";
import { poolAbiV2 } from "@arcoralabs/dex-sdk/v2";
import { parseAbi } from "viem";

/**
 * GF-1 — live Base Sepolia governance addresses (the source of truth for the
 * read-only protocol/governance status panel). These are the deployed
 * OpenZeppelin TimelockController + two Gnosis Safes that own the V2 system.
 */
export const GOV_ADDRESSES = {
  /** OZ TimelockController — getMinDelay() should read 172800 (48h). */
  timelock: "0x62Bf16e9921A1b9C2d8ec58e84b155AE9c9FbaD6" as const,
  /** Governance Safe (proposer/executor of timelocked ops). */
  govSafe: "0x262d4069348093D1Fe8860EEB7483ce1FEd068d2" as const,
  /** Pause-Guardian Safe (the emergency pause multisig). */
  pgSafe: "0x1516Bc7e614ba71AE95dD226df7F783FeD32c01c" as const,
} as const;

const timelockAbi = parseAbi(["function getMinDelay() view returns (uint256)"]);
const safeAbi = parseAbi([
  "function getThreshold() view returns (uint256)",
  "function getOwners() view returns (address[])",
]);

export interface SafeInfo {
  address: `0x${string}`;
  threshold: number | null;
  owners: `0x${string}`[] | null;
}

export interface GovernanceState {
  paused: boolean | null;
  /** Pool's on-chain pauseGuardian() — should equal the PG Safe. */
  pauseGuardian: `0x${string}` | null;
  timelock: `0x${string}`;
  /** getMinDelay() in seconds (expect 172800 = 48h). */
  minDelaySeconds: bigint | null;
  govSafe: SafeInfo;
  pgSafe: SafeInfo;
}

/**
 * Reads the GF-1 governance surface from the live addresses: the Pool's paused
 * flag + pauseGuardian, the Timelock's getMinDelay(), and each Safe's threshold
 * + owners. All read-only; the panel links each address to BaseScan.
 *
 * Failures are tolerated per-field (a Safe that doesn't expose getOwners, an RPC
 * hiccup) — the panel shows "—" rather than blanking the whole card.
 */
export function useGovernance(): { gov: GovernanceState | null; isFetching: boolean } {
  const sdk = useArcoraDexV2();

  const { data, isFetching } = useQuery({
    queryKey: ["arcora", "v2", "governance", sdk.chain.id],
    refetchInterval: 30_000,
    queryFn: async (): Promise<GovernanceState> => {
      const pc = sdk.publicClient;
      const readSafe = async (address: `0x${string}`): Promise<SafeInfo> => {
        const [threshold, owners] = await Promise.all([
          pc
            .readContract({ address, abi: safeAbi, functionName: "getThreshold" })
            .then((t) => Number(t))
            .catch(() => null),
          pc
            .readContract({ address, abi: safeAbi, functionName: "getOwners" })
            .then((o) => o as `0x${string}`[])
            .catch(() => null),
        ]);
        return { address, threshold, owners };
      };

      const [paused, pauseGuardian, minDelaySeconds, govSafe, pgSafe] = await Promise.all([
        pc
          .readContract({ address: sdk.addresses.pool, abi: poolAbiV2, functionName: "paused" })
          .catch(() => null),
        pc
          .readContract({ address: sdk.addresses.pool, abi: poolAbiV2, functionName: "pauseGuardian" })
          .then((a) => a as `0x${string}`)
          .catch(() => null),
        pc
          .readContract({ address: GOV_ADDRESSES.timelock, abi: timelockAbi, functionName: "getMinDelay" })
          .catch(() => null),
        readSafe(GOV_ADDRESSES.govSafe),
        readSafe(GOV_ADDRESSES.pgSafe),
      ]);

      return {
        paused,
        pauseGuardian,
        timelock: GOV_ADDRESSES.timelock,
        minDelaySeconds,
        govSafe,
        pgSafe,
      };
    },
  });

  return { gov: data ?? null, isFetching };
}
