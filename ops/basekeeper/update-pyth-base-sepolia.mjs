// UpdatePythBaseSepolia — pull Hermes update data for the 3 Sepolia feed ids and call each
// adapter's updatePyth{value: fee}. Run before the deploy bootstrap and on a timer (the
// adapters' pythMaxStaleSeconds is 24h on testnet, so a daily-or-faster pull keeps them safe).
//
// Post-2026-07-31 NOTE: Hermes requires HERMES_API_KEY. Pre-upgrade it is keyless.
//
// Required env:
//   KEEPER_PRIVATE_KEY  — signs updatePyth; needs a little Sepolia ETH for gas + the Pyth fee
//   ADAPTER_USDC / ADAPTER_USDT / ADAPTER_EURC — the deployed adapter addresses (from the ledger)
// Optional env:
//   BASE_SEPOLIA_RPC, BASE_SEPOLIA_RPC_FALLBACK, HERMES_API_KEY, HERMES_BASE_URL
import { createPublicClient, createWalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
    resolveGasCeiling,
    numEnv,
    resolveRpcUrls,
    buildTransport,
    DEFAULT_TX_TIMEOUT_MS,
} from "../keepalive/lib.mjs";
import { baseSepolia, FEED_IDS, ADAPTER_ABI, PYTH_ABI, fetchHermesUpdates } from "./lib.mjs";

// Base Sepolia public RPC backstop. Mirrors the Arc keeper's DEFAULT_RPC pattern so a missing
// BASE_SEPOLIA_RPC still resolves to a working endpoint.
const DEFAULT_RPC = "https://sepolia.base.org";

const ts = () => new Date().toISOString();
const log = (m) => console.log(`[base-pyth-keeper] ${ts()} ${m}`);
const TX_TIMEOUT_MS = numEnv(process.env.KEEPER_TX_TIMEOUT_MS, DEFAULT_TX_TIMEOUT_MS);

async function main() {
    const pkRaw = process.env.KEEPER_PRIVATE_KEY;
    if (!pkRaw) { log("KEEPER_PRIVATE_KEY missing — abort"); process.exit(2); }
    const pk = pkRaw.startsWith("0x") ? pkRaw : `0x${pkRaw}`;
    const account = privateKeyToAccount(pk);

    const adapters = {
        USDC: process.env.ADAPTER_USDC,
        USDT: process.env.ADAPTER_USDT,
        EURC: process.env.ADAPTER_EURC,
    };
    for (const [sym, addr] of Object.entries(adapters)) {
        if (!addr) { log(`ADAPTER_${sym} missing — abort`); process.exit(2); }
    }

    // L-4 hardening (reused from ops/keepalive/lib.mjs): a comma-separated BASE_SEPOLIA_RPC list
    // and/or BASE_SEPOLIA_RPC_FALLBACK builds a viem fallback() transport (auto-retry + failover);
    // the public sepolia.base.org RPC is appended last as a backstop.
    const transport = buildTransport(
        resolveRpcUrls({
            primary: process.env.BASE_SEPOLIA_RPC,
            fallback: process.env.BASE_SEPOLIA_RPC_FALLBACK,
            defaultRpc: DEFAULT_RPC,
        }),
    );

    const publicClient = createPublicClient({ chain: baseSepolia, transport });
    const walletClient = createWalletClient({ account, chain: baseSepolia, transport });
    const gasCeiling = resolveGasCeiling(process.env);
    const apiKey = process.env.HERMES_API_KEY || undefined;

    // One Hermes pull covers all 3 ids; the same blob set updates each feed on-chain.
    let blobs;
    try {
        blobs = await fetchHermesUpdates(Object.values(FEED_IDS), { apiKey });
    } catch (err) {
        log(`Hermes fetch failed: ${err?.message || err} — abort`);
        process.exit(1);
    }
    log(`fetched ${blobs.length} Hermes blob(s)`);

    let updated = 0, errored = 0;
    for (const [sym, adapter] of Object.entries(adapters)) {
        try {
            // The adapter forwards the Pyth fee; query it from the adapter's Pyth contract.
            const pyth = await publicClient.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "PYTH" });
            const fee = await publicClient.readContract({ address: pyth, abi: PYTH_ABI, functionName: "getUpdateFee", args: [blobs] });
            const hash = await walletClient.writeContract({
                address: adapter,
                abi: ADAPTER_ABI,
                functionName: "updatePyth",
                args: [blobs],
                value: fee,
                maxFeePerGas: gasCeiling.maxFeePerGas,
                maxPriorityFeePerGas: gasCeiling.maxPriorityFeePerGas,
            });
            await publicClient.waitForTransactionReceipt({ hash, timeout: TX_TIMEOUT_MS });
            log(`${sym}: updatePyth fee=${fee} tx=${hash}`);
            updated++;
        } catch (err) {
            log(`${sym}: ERROR ${err?.message || err}`);
            errored++;
        }
    }
    log(`done updated=${updated} errored=${errored}`);
    if (errored > 0) process.exit(1);
}

main().catch((err) => { log(`fatal: ${err?.message || err}`); process.exit(1); });
