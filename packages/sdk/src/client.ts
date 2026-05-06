import type { Account, Chain, PublicClient, Transport, WalletClient } from "viem";
import { createPublicClient, createWalletClient } from "viem";
import { DEFAULT_ADDRESSES, type ArcoraDexAddresses } from "./addresses";
import { quoteSwap } from "./actions/quoteSwap";
import { quoteDeposit } from "./actions/quoteDeposit";
import { quoteWithdraw } from "./actions/quoteWithdraw";
import { getPoolStats } from "./actions/getPoolStats";
import { getTokens } from "./actions/getTokens";
import { getReserves } from "./actions/getReserves";
import { getPosition } from "./actions/getPosition";
import { getProtocolFees } from "./actions/getProtocolFees";
import { swap, type SwapArgs } from "./actions/swap";
import { deposit, type DepositArgs } from "./actions/deposit";
import { withdraw, type WithdrawArgs } from "./actions/withdraw";
import * as fmt from "./format";
import * as slip from "./slippage";
import { tokenLabel } from "./tokens/label";
import { subscribeSwaps, type Unsubscribe } from "./subscriptions/subscribeSwaps";
import { subscribeDeposited } from "./subscriptions/subscribeDeposited";
import { subscribeWithdrew } from "./subscriptions/subscribeWithdrew";
import { subscribePoolStats } from "./subscriptions/subscribePoolStats";

export interface CreateArcoraDexParams {
  chain: Chain;
  transport: Transport;
  account?: Account;
  addresses?: ArcoraDexAddresses;
}

export interface ArcoraDexClient {
  chain: Chain;
  publicClient: PublicClient;
  walletClient?: WalletClient;
  account?: Account;
  addresses: ArcoraDexAddresses;

  quoteSwap: (a: Parameters<typeof quoteSwap>[1]) => ReturnType<typeof quoteSwap>;
  quoteDeposit: (a: Parameters<typeof quoteDeposit>[1]) => ReturnType<typeof quoteDeposit>;
  quoteWithdraw: (a: Parameters<typeof quoteWithdraw>[1]) => ReturnType<typeof quoteWithdraw>;
  getPoolStats: () => ReturnType<typeof getPoolStats>;
  getTokens: (a?: Parameters<typeof getTokens>[1]) => ReturnType<typeof getTokens>;
  getReserves: () => ReturnType<typeof getReserves>;
  getPosition: (addr: `0x${string}`) => ReturnType<typeof getPosition>;
  getProtocolFees: (token: `0x${string}`) => ReturnType<typeof getProtocolFees>;

  swap: (a: SwapArgs) => ReturnType<typeof swap>;
  deposit: (a: DepositArgs) => ReturnType<typeof deposit>;
  withdraw: (a: WithdrawArgs) => ReturnType<typeof withdraw>;

  subscribeSwaps:     (h: Parameters<typeof subscribeSwaps>[1],     o?: Parameters<typeof subscribeSwaps>[2])     => Unsubscribe;
  subscribeDeposited: (h: Parameters<typeof subscribeDeposited>[1], o?: Parameters<typeof subscribeDeposited>[2]) => Unsubscribe;
  subscribeWithdrew:  (h: Parameters<typeof subscribeWithdrew>[1],  o?: Parameters<typeof subscribeWithdrew>[2])  => Unsubscribe;
  subscribePoolStats: (h: Parameters<typeof subscribePoolStats>[1])                                                => Unsubscribe;

  format: typeof fmt & { tokenLabel: typeof tokenLabel };
  slippage: typeof slip;
}

export function createArcoraDex(params: CreateArcoraDexParams): ArcoraDexClient {
  const addresses =
    params.addresses ??
    DEFAULT_ADDRESSES[params.chain.id] ??
    (() => {
      throw new Error(
        `No default ArcoraDexAddresses for chainId ${params.chain.id}; pass { addresses } explicitly.`,
      );
    })();

  const publicClient = createPublicClient({ chain: params.chain, transport: params.transport });
  const walletClient = params.account
    ? createWalletClient({ chain: params.chain, transport: params.transport, account: params.account })
    : undefined;

  const client: ArcoraDexClient = {
    chain: params.chain,
    publicClient,
    walletClient,
    account: params.account,
    addresses,

    quoteSwap: (a) => quoteSwap(client, a),
    quoteDeposit: (a) => quoteDeposit(client, a),
    quoteWithdraw: (a) => quoteWithdraw(client, a),
    getPoolStats: () => getPoolStats(client),
    getTokens: (a) => getTokens(client, a),
    getReserves: () => getReserves(client),
    getPosition: (addr) => getPosition(client, addr),
    getProtocolFees: (token) => getProtocolFees(client, token),

    swap: (a) => swap(client, a),
    deposit: (a) => deposit(client, a),
    withdraw: (a) => withdraw(client, a),

    subscribeSwaps:     (h, o) => subscribeSwaps(client, h, o),
    subscribeDeposited: (h, o) => subscribeDeposited(client, h, o),
    subscribeWithdrew:  (h, o) => subscribeWithdrew(client, h, o),
    subscribePoolStats: (h)    => subscribePoolStats(client, h),

    format: { ...fmt, tokenLabel },
    slippage: slip,
  };
  return client;
}
