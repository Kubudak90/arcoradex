// ArcoraDEX CumulativeDeviationGuard recorder.
//
// Reads each per-token OracleAggregator's latestRoundData(), scales the
// 8-decimal answer to 1e18, and calls CumulativeDeviationGuard.record(token,
// price1e18). The guard is event-only: this produces the PriceObserved /
// CircuitBreakerTripped event stream that off-chain monitoring consumes.
//
// record() is permissionless; this signs with the keeper EOA (already funded).
//
// L-4 (audit 2026-05-31): every tx carries an explicit gas-fee ceiling, an
// explicitly-managed nonce, and a confirmation timeout; the transport supports a
// fallback RPC; and a startup balance check warns/aborts a low keeper. The
// on-chain reads run through the same fallback transport, so a single hung RPC
// fails over rather than stalling the oneshot.
//
// Designed to run from a systemd timer on the VPS (Type=oneshot every 30 min).

import {
    createPublicClient,
    createWalletClient,
    parseAbi,
    defineChain,
    formatEther,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
    resolveRpcUrls,
    buildTransport,
    resolveGasCeiling,
    numEnv,
    DEFAULT_TX_TIMEOUT_MS,
    DEFAULT_MIN_BALANCE_ETHER,
    DEFAULT_ABORT_BALANCE_ETHER,
} from "./lib.mjs";

const DEFAULT_RPC = "https://rpc.testnet.arc.network";

const arcTestnet = defineChain({
    id: 5042002,
    name: "Arc Testnet",
    nativeCurrency: { name: "Arc", symbol: "ARC", decimals: 18 },
    rpcUrls: {
        default: {
            http: resolveRpcUrls({
                primary: process.env.ARC_TESTNET_RPC,
                fallback: process.env.ARC_TESTNET_RPC_FALLBACK,
                defaultRpc: DEFAULT_RPC,
            }),
        },
    },
});

// I-11 (audit 2026-05-31): GUARD and REGISTRY are sourced from env
// (GUARD_ADDRESS / REGISTRY_ADDRESS) instead of hardcoded constants, matching
// multi-feed-push.mjs's env-sourcing. A Registry or CumulativeDeviationGuard
// redeploy (the no-proxy "redeploy + migrate" model) would otherwise silently
// leave this script recording into the OLD contracts. The literals below are the
// current live addresses, kept only as documented defaults; set the env vars on
// the VPS to make a migration a config change, not a code change.
const GUARD = process.env.GUARD_ADDRESS || "0x035447f8d97A23fFfC32aa8bFb8ffDbC7B94E608";

// Registry address — aggregators are resolved from here at startup so the
// script automatically tracks whatever oracle the Registry currently points at.
// This survives any future oracle migration (e.g. V1→V2 aggregators after P3.5)
// with no code change, PROVIDED the Registry address itself is current (hence
// I-11: source it from env so a Registry redeploy is also covered).
const REGISTRY = process.env.REGISTRY_ADDRESS || "0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB";

const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;

// Token list — aggregator field is resolved from Registry.tokenInfo() at startup.
const TOKENS = [
    { symbol: "USDC",  token: "0x3BFa09fF6467639f0981948385bA1018Ac07d22C" },
    { symbol: "USDT",  token: "0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B" },
    { symbol: "PYUSD", token: "0xfdB2c86d010698401f0b969348DC58b6659B96a3" },
    { symbol: "DAI",   token: "0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE" },
    { symbol: "EURC",  token: "0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD" },
    { symbol: "TRYC",  token: "0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61" },
    { symbol: "BRLC",  token: "0xa13c0935A98e2c175b31A4054f698819271a8FfC" },
];

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

const REGISTRY_ABI = parseAbi([
    // tokenInfo(address token) -> (uint8 decimals, bool isActive, address usdOracle, uint16 maxOracleDeviationBps, uint32 maxStaleSeconds)
    "function tokenInfo(address token) view returns (uint8 decimals, bool isActive, address usdOracle, uint16 maxOracleDeviationBps, uint32 maxStaleSeconds)",
]);
const AGG_ABI = parseAbi([
    "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
]);
const GUARD_ABI = parseAbi([
    "function record(address token, uint256 price1e18) external",
]);

const TX_TIMEOUT_MS = numEnv(process.env.KEEPER_TX_TIMEOUT_MS, DEFAULT_TX_TIMEOUT_MS);

const ts = () => new Date().toISOString();
const log = (msg) => console.log(`[arcoradex-guard-record] ${ts()} ${msg}`);

async function main() {
    const pk = process.env.KEEPER_PRIVATE_KEY;
    if (!pk) {
        log("KEEPER_PRIVATE_KEY missing — abort");
        process.exit(2);
    }
    // I-11: fail loudly if GUARD/REGISTRY (env or default) are not valid addresses.
    if (!ADDR_RE.test(GUARD)) {
        log(`GUARD_ADDRESS invalid (${GUARD}) — set a 0x-40-hex address — abort`);
        process.exit(2);
    }
    if (!ADDR_RE.test(REGISTRY)) {
        log(`REGISTRY_ADDRESS invalid (${REGISTRY}) — set a 0x-40-hex address — abort`);
        process.exit(2);
    }
    log(`using GUARD=${GUARD} REGISTRY=${REGISTRY}`);
    const account = privateKeyToAccount(pk.startsWith("0x") ? pk : "0x" + pk);

    const transport = buildTransport(
        resolveRpcUrls({
            primary: process.env.ARC_TESTNET_RPC,
            fallback: process.env.ARC_TESTNET_RPC_FALLBACK,
            defaultRpc: DEFAULT_RPC,
        }),
    );
    const publicClient = createPublicClient({ chain: arcTestnet, transport });
    const walletClient = createWalletClient({ account, chain: arcTestnet, transport });

    const gasCeiling = resolveGasCeiling(process.env);

    // L-4: startup balance check + explicit pending nonce (re-priceable / no
    // cross-run collision).
    const minBalance = numEnv(process.env.KEEPER_MIN_BALANCE_ETHER, DEFAULT_MIN_BALANCE_ETHER);
    const abortBalance = numEnv(process.env.KEEPER_ABORT_BALANCE_ETHER, DEFAULT_ABORT_BALANCE_ETHER);
    const nonceRef = { value: 0 };
    try {
        const balWei = await publicClient.getBalance({ address: account.address });
        const balEth = Number(formatEther(balWei));
        if (balEth < abortBalance) {
            log(`keeper ${account.address} balance ${balEth} ARC < abort floor ${abortBalance} — abort`);
            process.exit(2);
        }
        if (balEth < minBalance) {
            log(`WARN: keeper ${account.address} balance ${balEth} ARC < ${minBalance} — top up soon`);
        }
        nonceRef.value = await publicClient.getTransactionCount({ address: account.address, blockTag: "pending" });
    } catch (err) {
        log(`startup check failed: ${err?.message || err} — abort`);
        process.exit(2);
    }

    let recorded = 0;
    let errored = 0;

    // Resolve each token's aggregator from the Registry at startup.
    // This means the script automatically uses whatever oracle the Registry
    // currently points at — no code change needed after an oracle migration.
    log("resolving aggregators from Registry…");
    const tokens = [];
    for (const t of TOKENS) {
        try {
            const info = await publicClient.readContract({
                address: REGISTRY, abi: REGISTRY_ABI, functionName: "tokenInfo",
                args: [t.token],
            });
            const [, isActive, usdOracle] = info;
            if (!isActive) {
                log(`${t.symbol}: ERROR token is !isActive in Registry — skipping`);
                errored++;
                continue;
            }
            if (!usdOracle || usdOracle.toLowerCase() === ZERO_ADDRESS) {
                log(`${t.symbol}: ERROR usdOracle resolved to address(0) — skipping`);
                errored++;
                continue;
            }
            log(`${t.symbol}: aggregator=${usdOracle}`);
            tokens.push({ ...t, aggregator: usdOracle });
        } catch (err) {
            log(`${t.symbol}: ERROR resolving tokenInfo — ${err?.message || err}`);
            errored++;
        }
    }

    for (const t of tokens) {
        try {
            // latestRoundData() reverts if the aggregator's sources diverge or
            // are all unavailable — treat that as an errored token, not a hard stop.
            const round = await publicClient.readContract({
                address: t.aggregator, abi: AGG_ABI, functionName: "latestRoundData",
            });
            const answer = round[1]; // int256, 8-decimal
            if (answer <= 0n) throw new Error(`aggregator answer <= 0 (${answer})`);
            const price1e18 = answer * 10_000_000_000n; // 1e8 -> 1e18

            // L-4: explicit nonce + fee ceiling + confirmation timeout. Consume
            // the nonce ONLY after the send resolves — a writeContract that
            // throws (before a tx enters the mempool) must NOT advance the local
            // counter, or the gap would make every later tx in this run fail
            // until it fills.
            const nonce = nonceRef.value;
            const hash = await walletClient.writeContract({
                address: GUARD, abi: GUARD_ABI, functionName: "record",
                args: [t.token, price1e18],
                nonce,
                maxFeePerGas: gasCeiling.maxFeePerGas,
                maxPriorityFeePerGas: gasCeiling.maxPriorityFeePerGas,
            });
            nonceRef.value += 1; // tx is in the mempool — the nonce is now spent.
            await publicClient.waitForTransactionReceipt({ hash, timeout: TX_TIMEOUT_MS });
            log(`${t.symbol}: recorded price1e18=${price1e18} (nonce=${nonce}) tx=${hash}`);
            recorded++;
        } catch (err) {
            log(`${t.symbol}: ERROR ${err?.message || err}`);
            errored++;
        }
    }

    log(`done recorded=${recorded} errored=${errored}`);
    if (errored > 0) process.exit(1);
}

main().catch((err) => {
    log(`fatal: ${err?.message || err}`);
    process.exit(1);
});
