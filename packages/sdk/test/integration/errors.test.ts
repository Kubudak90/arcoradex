import { describe, it, expect, inject } from "vitest";
import { http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  createArcoraDex,
  arcTestnet,
  SlippageExceededError,
  DeadlinePassedError,
  TokenNotActiveError,
  PoolPausedError,
  InsufficientLiquidityError,
  MissingAccountError,
  parseContractError,
} from "@";

const ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: { symbol: string; address: `0x${string}`; decimals: number; feed: `0x${string}` }[];
}

const usdc = () => (inject("deployed") as DeployedAddresses).tokens.find((t) => t.symbol === "USDC")!.address;
const eurc = () => (inject("deployed") as DeployedAddresses).tokens.find((t) => t.symbol === "EURC")!.address;

const writeSdk = () => {
  const rpcUrl = inject("anvilRpcUrl") as string;
  const deployed = inject("deployed") as DeployedAddresses;
  return createArcoraDex({
    chain: arcTestnet,
    transport: http(rpcUrl),
    account: privateKeyToAccount(ANVIL_KEY),
    addresses: deployed,
  });
};

const readOnlySdk = () => {
  const rpcUrl = inject("anvilRpcUrl") as string;
  const deployed = inject("deployed") as DeployedAddresses;
  return createArcoraDex({
    chain: arcTestnet,
    transport: http(rpcUrl),
    addresses: deployed,
  });
};

describe("error path coverage", () => {
  // Direct-throw paths: trigger via real SDK calls

  it("MissingAccountError when read-only client tries swap", async () => {
    const sdk = readOnlySdk();
    await expect(
      sdk.swap({
        tokenIn: usdc(),
        tokenOut: eurc(),
        amountIn: 1_000_000n,
        slippageBps: 50,
      }),
    ).rejects.toThrow(MissingAccountError);
  });

  it("DeadlinePassedError when deadline is in the past (live revert)", async () => {
    const sdk = writeSdk();
    await expect(
      sdk.swap({
        tokenIn: usdc(),
        tokenOut: eurc(),
        amountIn: 1_000_000n,
        slippageBps: 50,
        deadline: 1n,
        // exactApproval keeps the allowance bounded so it doesn't pollute
        // the infinite-approval check in the shared Anvil instance.
        exactApproval: true,
      }),
    ).rejects.toThrow(DeadlinePassedError);
  });

  // Selector-mapped paths: verify parseContractError decodes the synthetic
  // ContractFunctionRevertedError shape into the right typed class. This is the
  // same code path the live SDK hits when the contract reverts.

  it("parseContractError decodes InsufficientOutput → SlippageExceededError", () => {
    const fake = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "InsufficientOutput", args: [99n, 100n] },
    };
    const out = parseContractError(fake);
    expect(out).toBeInstanceOf(SlippageExceededError);
    if (out instanceof SlippageExceededError) {
      expect(out.actual).toBe(99n);
      expect(out.minOut).toBe(100n);
    }
  });

  it("parseContractError decodes TokenNotActive → TokenNotActiveError", () => {
    const fake = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "TokenNotActive", args: [usdc()] },
    };
    expect(parseContractError(fake)).toBeInstanceOf(TokenNotActiveError);
  });

  it("parseContractError decodes PoolPaused → PoolPausedError (no args)", () => {
    const fake = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "PoolPaused", args: [] },
    };
    expect(parseContractError(fake)).toBeInstanceOf(PoolPausedError);
  });

  it("parseContractError decodes InsufficientLiquidity → InsufficientLiquidityError with named fields", () => {
    const fake = {
      name: "ContractFunctionRevertedError",
      data: {
        errorName: "InsufficientLiquidity",
        args: [usdc(), 5_000_000n, 1_000_000n],
      },
    };
    const out = parseContractError(fake);
    expect(out).toBeInstanceOf(InsufficientLiquidityError);
    if (out instanceof InsufficientLiquidityError) {
      expect(out.requested).toBe(5_000_000n);
      expect(out.available).toBe(1_000_000n);
    }
  });

  it("InsufficientLpOut: live deposit revert decodes to SlippageExceededError (regression test for missing ABI errors)", async () => {
    const { poolAbi } = await import("@/abi/pool");
    const { erc20Abi } = await import("@/abi/erc20");
    const sdk = writeSdk();

    // L-10 (audit 2026-06-03): the pool now measures the inbound balance delta,
    // so `safeTransferFrom` runs BEFORE the `InsufficientLpOut` slippage check.
    // We must therefore fund + approve so the transfer succeeds and the revert
    // is reached on the slippage branch (not on a transferFrom allowance error).
    // exactApproval-equivalent: approve exactly the deposit amount so we don't
    // leave a lingering MAX allowance for downstream tests.
    const mintAbi = [
      {
        type: "function",
        name: "mint",
        inputs: [
          { name: "to", type: "address" },
          { name: "amount", type: "uint256" },
        ],
        outputs: [],
        stateMutability: "nonpayable",
      },
    ] as const;
    const mintHash = await sdk.walletClient!.writeContract({
      address: usdc(),
      abi: mintAbi,
      functionName: "mint",
      args: [sdk.account!.address, 1_000_000n],
      chain: sdk.chain,
      account: sdk.account!,
    });
    await sdk.publicClient.waitForTransactionReceipt({ hash: mintHash });
    const approveHash = await sdk.walletClient!.writeContract({
      address: usdc(),
      abi: erc20Abi,
      functionName: "approve",
      args: [sdk.addresses.pool, 1_000_000n],
      chain: sdk.chain,
      account: sdk.account!,
    });
    await sdk.publicClient.waitForTransactionReceipt({ hash: approveHash });

    // Force the revert with an unreachable minLpOut. Using the full poolAbi (with the
    // InsufficientLpOut error declared) lets viem decode the selector into errorName.
    try {
      await sdk.walletClient!.writeContract({
        address: sdk.addresses.pool,
        abi: poolAbi,
        functionName: "deposit",
        args: [usdc(), 1_000_000n, 10n ** 36n, BigInt(Math.floor(Date.now() / 1000) + 60)],
        chain: sdk.chain,
        account: sdk.account!,
      });
      throw new Error("Expected revert");
    } catch (e) {
      const parsed = parseContractError(e);
      expect(parsed).toBeInstanceOf(SlippageExceededError);
    }
  }, 30_000);

  it("parseContractError unknown selector falls back to ArcoraDexError", () => {
    const fake = {
      name: "ContractFunctionRevertedError",
      data: { errorName: "MysterySelector", args: [] },
    };
    const out = parseContractError(fake);
    expect(out.message).toContain("MysterySelector");
  });
});
