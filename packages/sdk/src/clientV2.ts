import type { Account, Chain, PublicClient, WalletClient } from "viem";
import type { ArcoraDexAddresses } from "./addresses";

/**
 * Forward-reference shape for the V2 client.
 *
 * NOTE (Task 6 → Task 8): this file currently declares ONLY the structural
 * `ArcoraDexClientV2` interface that the V2 write actions (`swapV2`,
 * `depositV2`, `withdrawSingleV2`, `withdrawProportionalV2`) and the read/quote
 * actions need. Task 8 replaces this file with the full version that ADDS the
 * `createArcoraDexV2` factory, the `getTokens`/`getPoolStats` bindings, and the
 * `format`/`slippage`/`present` members. The fields declared here are a strict
 * subset of that final interface, so Task 8 is purely additive over this stub.
 *
 * The interface is intentionally limited to the five structural fields the
 * write actions read (`chain`, `publicClient`, `walletClient`, `account`,
 * `addresses`); a `ReadClientV2` ({ publicClient, addresses }) is structurally
 * satisfied by it, and `ensureAllowance` consumes the same fields.
 */
export interface ArcoraDexClientV2 {
  chain: Chain;
  publicClient: PublicClient;
  walletClient?: WalletClient;
  account?: Account;
  addresses: ArcoraDexAddresses;
}
