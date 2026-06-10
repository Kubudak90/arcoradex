import type { Account, Chain, PublicClient, Transport, WalletClient } from "viem";
import { createPublicClient, createWalletClient } from "viem";
import { DEFAULT_ADDRESSES_V2 } from "./addresses.v2";
import type { ArcoraDexAddresses } from "./addresses";
import { reserveHealth } from "./actions/v2/reserveHealth";
import { maxSwapOut } from "./actions/v2/maxSwapOut";
import { maxWithdraw } from "./actions/v2/maxWithdraw";
import { quoteSwapV2 } from "./actions/v2/quoteSwapV2";
import { quoteWithdrawV2 } from "./actions/v2/quoteWithdrawV2";
import { getTokensV2 } from "./actions/v2/getTokensV2";
import { getPoolStatsV2 } from "./actions/v2/getPoolStatsV2";
import { swapV2, type SwapV2Args } from "./actions/v2/swapV2";
import { depositV2, type DepositV2Args } from "./actions/v2/depositV2";
import { withdrawSingleV2 } from "./actions/v2/withdrawSingleV2";
import { withdrawProportionalV2 } from "./actions/v2/withdrawProportionalV2";
import * as fmt from "./format";
import * as slip from "./slippage";
import * as present from "./present";

export interface CreateArcoraDexV2Params {
  chain: Chain;
  transport: Transport;
  walletClient?: WalletClient;
  account?: Account;
  addresses?: ArcoraDexAddresses;
}

export interface ArcoraDexClientV2 {
  chain: Chain;
  publicClient: PublicClient;
  walletClient?: WalletClient;
  account?: Account;
  addresses: ArcoraDexAddresses;

  reserveHealth: (tokenOut: `0x${string}`) => ReturnType<typeof reserveHealth>;
  maxSwapOut: (tokenOut: `0x${string}`) => ReturnType<typeof maxSwapOut>;
  maxWithdraw: (tokenOut: `0x${string}`, account: `0x${string}`) => ReturnType<typeof maxWithdraw>;
  quoteSwapV2: (a: Parameters<typeof quoteSwapV2>[1]) => ReturnType<typeof quoteSwapV2>;
  quoteWithdrawV2: (a: Parameters<typeof quoteWithdrawV2>[1]) => ReturnType<typeof quoteWithdrawV2>;
  getTokens: (a?: Parameters<typeof getTokensV2>[1]) => ReturnType<typeof getTokensV2>;
  getPoolStats: () => ReturnType<typeof getPoolStatsV2>;

  swap: (a: SwapV2Args) => ReturnType<typeof swapV2>;
  deposit: (a: DepositV2Args) => ReturnType<typeof depositV2>;
  withdrawSingle: (a: Parameters<typeof withdrawSingleV2>[1]) => ReturnType<typeof withdrawSingleV2>;
  withdrawProportional: (a: Parameters<typeof withdrawProportionalV2>[1]) => ReturnType<typeof withdrawProportionalV2>;

  format: typeof fmt;
  slippage: typeof slip;
  present: typeof present;
}

export function createArcoraDexV2(params: CreateArcoraDexV2Params): ArcoraDexClientV2 {
  const addresses =
    params.addresses ??
    DEFAULT_ADDRESSES_V2[params.chain.id] ??
    (() => {
      throw new Error(
        `No default ArcoraDexAddresses for chainId ${params.chain.id}; pass { addresses } explicitly.`,
      );
    })();

  const publicClient = createPublicClient({ chain: params.chain, transport: params.transport });
  const walletClient = params.walletClient
    ? params.walletClient
    : params.account
      ? createWalletClient({ chain: params.chain, transport: params.transport, account: params.account })
      : undefined;
  const account = (walletClient?.account ?? params.account) as Account | undefined;

  const client: ArcoraDexClientV2 = {
    chain: params.chain,
    publicClient,
    walletClient,
    account,
    addresses,

    reserveHealth: (t) => reserveHealth(client, t),
    maxSwapOut: (t) => maxSwapOut(client, t),
    maxWithdraw: (t, acc) => maxWithdraw(client, t, acc),
    quoteSwapV2: (a) => quoteSwapV2(client, a),
    quoteWithdrawV2: (a) => quoteWithdrawV2(client, a),
    getTokens: (a) => getTokensV2(client, a),
    getPoolStats: () => getPoolStatsV2(client),

    swap: (a) => swapV2(client, a),
    deposit: (a) => depositV2(client, a),
    withdrawSingle: (a) => withdrawSingleV2(client, a),
    withdrawProportional: (a) => withdrawProportionalV2(client, a),

    format: fmt,
    slippage: slip,
    present,
  };
  return client;
}
