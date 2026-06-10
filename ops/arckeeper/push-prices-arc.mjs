// Arc V2 keeper — push a fresh setPrice(token, peg, true) per token so each
// MockOracleAdapterV2Settable reads `safe`. The mock adapter has no intrinsic
// staleness, but a periodic refresh (a) keeps the on-chain price + timestamp
// current for parity with the Base Pyth keeper cadence and (b) lets the operator
// drive the §11 oracle-failure drill simply by STOPPING the keeper + flipping
// safe=false via the writer key.
//
// Required env:
//   KEEPER_PRIVATE_KEY  — the adapter `writer`; needs a little Arc USDC for gas
//   ADAPTER_USDC / ADAPTER_USDT / ADAPTER_EURC — deployed adapter addresses (from the ledger)
//   TOKEN_USDC / TOKEN_USDT / TOKEN_EURC       — deployed token addresses (from the ledger)
// Optional env:
//   ARC_TESTNET_RPC, ARC_TESTNET_RPC_FALLBACK, KEEPER_MAX_FEE_GWEI, KEEPER_TX_TIMEOUT_MS
import { createPublicClient, createWalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
    resolveGasCeiling,
    numEnv,
    DEFAULT_TX_TIMEOUT_MS,
    buildTransport,
    resolveRpcUrls,
} from "../keepalive/lib.mjs";
import { arcTestnet, ADAPTER_ABI, buildPushList } from "./lib.mjs";

const ts = () => new Date().toISOString();
const log = (m) => console.log(`[arc-v2-keeper] ${ts()} ${m}`);
const TX_TIMEOUT_MS = numEnv(process.env.KEEPER_TX_TIMEOUT_MS, DEFAULT_TX_TIMEOUT_MS);

async function main() {
    const pkRaw = process.env.KEEPER_PRIVATE_KEY;
    if (!pkRaw) {
        log("KEEPER_PRIVATE_KEY missing — abort");
        process.exit(2);
    }
    const pk = pkRaw.startsWith("0x") ? pkRaw : `0x${pkRaw}`;
    const account = privateKeyToAccount(pk);

    const pushes = buildPushList(process.env);
    if (pushes.length === 0) {
        log("no ADAPTER_*/TOKEN_* env present — abort");
        process.exit(2);
    }

    const transport = buildTransport(
        resolveRpcUrls({
            primary: process.env.ARC_TESTNET_RPC,
            fallback: process.env.ARC_TESTNET_RPC_FALLBACK,
            defaultRpc: "https://rpc.testnet.arc.network",
        }),
    );
    const publicClient = createPublicClient({ chain: arcTestnet, transport });
    const walletClient = createWalletClient({ account, chain: arcTestnet, transport });
    const gasCeiling = resolveGasCeiling(process.env);

    let pushed = 0,
        errored = 0;
    for (const { symbol, adapter, token, price1e18 } of pushes) {
        try {
            const hash = await walletClient.writeContract({
                address: adapter,
                abi: ADAPTER_ABI,
                functionName: "setPrice",
                args: [token, price1e18, true],
                maxFeePerGas: gasCeiling.maxFeePerGas,
                maxPriorityFeePerGas: gasCeiling.maxPriorityFeePerGas,
            });
            await publicClient.waitForTransactionReceipt({ hash, timeout: TX_TIMEOUT_MS });
            log(`${symbol}: setPrice ${price1e18} safe=true tx=${hash}`);
            pushed++;
        } catch (err) {
            log(`${symbol}: ERROR ${err?.message || err}`);
            errored++;
        }
    }
    log(`done pushed=${pushed} errored=${errored}`);
    if (errored > 0) process.exit(1);
}

main().catch((err) => {
    log(`fatal: ${err?.message || err}`);
    process.exit(1);
});
