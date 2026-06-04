// ArcoraDEX CumulativeDeviationGuard monitor.
//
// Pipeline (audit 2026-05-31, the missing "guard → monitor → guardian" leg):
// the on-chain CumulativeDeviationGuard is event-only and PERMISSIONLESS. Its
// CircuitBreakerTripped / PriceObserved events are UNTRUSTED hints — anyone can
// call record() to spam events or anchor a window (see the contract's
// "Permissionless-record trust boundary" NatSpec). This monitor therefore:
//
//   1. Polls CircuitBreakerTripped logs over a recent block range (poll model so
//      it works on a systemd timer like the other keeper units; getLogs avoids a
//      long-lived subscription).
//   2. RE-VALIDATES each flagged token's price against an INDEPENDENT trusted
//      feed (CoinGecko, the same source the keeper trusts off-chain) before
//      deciding to page. An event the independent feed does not confirm is
//      treated as spam and dropped.
//   3. DEBOUNCES per-token so a spammed event stream cannot flood pages, and so
//      a spammed (unconfirmed) event can neither page NOR suppress a later
//      genuine page (the confirmation gate is checked before the dedupe slot is
//      consumed — see lib.decidePage).
//   4. Emits a MANUAL-IN-THE-LOOP alert: structured log + optional webhook
//      (ALERT_WEBHOOK_URL) + a non-zero exit code when it pages. It does NOT
//      auto-submit a pause — pausing remains a human Pause-Guardian Safe action.
//
// Run from a systemd timer (arcoradex-guard-monitor.{service,timer}) or ad hoc.

import {
    createPublicClient,
    parseAbi,
    parseAbiItem,
    defineChain,
    formatUnits,
} from "viem";
import {
    fetchJson,
    resolveRpcUrls,
    buildTransport,
    decideFxReferenceDrift,
    decidePage,
    newPageState,
    numEnv,
    DEFAULT_FETCH_TIMEOUT_MS,
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

// Sourced from env (I-11 consistency); falls back to current live addresses.
const GUARD = process.env.GUARD_ADDRESS || "0x035447f8d97A23fFfC32aa8bFb8ffDbC7B94E608";
const REGISTRY = process.env.REGISTRY_ADDRESS || "0x9914436E5245bF3c0d4D4338e0a8b8F5Ab5505aB";
const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;

// token -> { symbol, coingeckoId?|coingeckoVsCurrency? } so the monitor can
// independently re-quote the flagged token. Mirrors the keeper's price map.
const TOKENS = [
    { symbol: "USDC",  token: "0x3BFa09fF6467639f0981948385bA1018Ac07d22C", hardPeg: 1.0 },
    { symbol: "USDT",  token: "0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B", coingeckoId: "tether" },
    { symbol: "PYUSD", token: "0xfdB2c86d010698401f0b969348DC58b6659B96a3", coingeckoId: "paypal-usd" },
    { symbol: "DAI",   token: "0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE", coingeckoId: "dai" },
    { symbol: "EURC",  token: "0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD", coingeckoVsCurrency: "eur" },
    { symbol: "TRYC",  token: "0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61", coingeckoVsCurrency: "try" },
    { symbol: "BRLC",  token: "0xa13c0935A98e2c175b31A4054f698819271a8FfC", coingeckoVsCurrency: "brl" },
];

const TOKEN_BY_ADDR = new Map(TOKENS.map((t) => [t.token.toLowerCase(), t]));

const TRIPPED_EVENT = parseAbiItem(
    "event CircuitBreakerTripped(address indexed token, uint256 deviationBps, uint256 timestamp)",
);
const REGISTRY_ABI = parseAbi([
    "function tokenInfo(address token) view returns (uint8 decimals, bool isActive, address usdOracle, uint16 maxOracleDeviationBps, uint32 maxStaleSeconds)",
]);
const AGG_ABI = parseAbi([
    "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
]);

// How far back to scan for events each run, and the per-token page cooldown.
const LOOKBACK_BLOCKS = BigInt(Math.round(numEnv(process.env.GUARD_MONITOR_LOOKBACK_BLOCKS, 2000)));
const PAGE_COOLDOWN_MS = numEnv(process.env.GUARD_MONITOR_COOLDOWN_MS, 60 * 60 * 1000); // 1h
// Tolerance (bps) for "does the independent feed confirm the on-chain deviation".
// We re-derive the on-chain price from the aggregator and compare to the
// independent off-chain quote; agreement WITHIN tolerance means the on-chain
// value is trustworthy → the trip is real if it also exceeds the deviation cap.
const CONFIRM_TOLERANCE_BPS = numEnv(process.env.GUARD_MONITOR_CONFIRM_TOLERANCE_BPS, 300);
const FETCH_TIMEOUT_MS = numEnv(process.env.KEEPER_FETCH_TIMEOUT_MS, DEFAULT_FETCH_TIMEOUT_MS);

const ts = () => new Date().toISOString();
const log = (msg) => console.log(`[arcoradex-guard-monitor] ${ts()} ${msg}`);

/// Independently quote one token's USD price from CoinGecko (the off-chain
/// trusted source). Returns a number or undefined. Hardened by fetchJson timeout.
async function independentQuote(meta, apiKey) {
    if (meta.hardPeg !== undefined && !meta.coingeckoId && !meta.coingeckoVsCurrency) {
        return meta.hardPeg; // hard-pegged (USDC)
    }
    const headers = apiKey ? { "x-cg-pro-api-key": apiKey } : undefined;
    try {
        if (meta.coingeckoId) {
            const url = `https://api.coingecko.com/api/v3/simple/price?ids=${meta.coingeckoId}&vs_currencies=usd`;
            const json = await fetchJson(url, { headers, timeoutMs: FETCH_TIMEOUT_MS });
            const usd = json?.[meta.coingeckoId]?.usd;
            return typeof usd === "number" ? usd : undefined;
        }
        if (meta.coingeckoVsCurrency) {
            const url = `https://api.coingecko.com/api/v3/simple/price?ids=usd&vs_currencies=${meta.coingeckoVsCurrency}`;
            const json = await fetchJson(url, { headers, timeoutMs: FETCH_TIMEOUT_MS });
            const rate = json?.usd?.[meta.coingeckoVsCurrency];
            return typeof rate === "number" && rate !== 0 ? 1 / rate : undefined;
        }
    } catch (err) {
        log(`${meta.symbol}: independent quote ERROR ${err?.message || err}`);
    }
    return undefined;
}

/// Reads the on-chain aggregator price (1e8) for a token and returns it as USD.
async function onChainUsd(publicClient, token) {
    try {
        const info = await publicClient.readContract({
            address: REGISTRY, abi: REGISTRY_ABI, functionName: "tokenInfo", args: [token],
        });
        const usdOracle = info[2];
        if (!usdOracle || usdOracle.toLowerCase() === "0x0000000000000000000000000000000000000000") return undefined;
        const round = await publicClient.readContract({
            address: usdOracle, abi: AGG_ABI, functionName: "latestRoundData",
        });
        const answer = round[1]; // 1e8
        if (answer <= 0n) return undefined;
        return Number(formatUnits(answer, 8));
    } catch (err) {
        log(`onChainUsd(${token}) ERROR ${err?.message || err}`);
        return undefined;
    }
}

/// Emits the page alert: structured log + optional webhook POST. Manual-in-the-
/// loop: surfaces to a human Pause-Guardian operator, never auto-pauses.
async function emitAlert(payload) {
    log(`PAGE ${JSON.stringify(payload)}`);
    const webhook = process.env.ALERT_WEBHOOK_URL;
    if (!webhook) return;
    // POST to a webhook (e.g. Slack/Upstash/PagerDuty-compatible), AbortController-
    // bounded so a hung webhook never stalls the run.
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    try {
        const res = await fetch(webhook, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ text: `ArcoraDEX guard PAGE: ${JSON.stringify(payload)}` }),
            signal: controller.signal,
        });
        if (!res.ok) log(`webhook POST non-2xx: HTTP ${res.status}`);
    } catch (err) {
        log(`webhook POST ERROR ${err?.message || err}`);
    } finally {
        clearTimeout(timer);
    }
}

async function main() {
    if (!ADDR_RE.test(GUARD)) { log(`GUARD_ADDRESS invalid (${GUARD}) — abort`); process.exit(2); }
    if (!ADDR_RE.test(REGISTRY)) { log(`REGISTRY_ADDRESS invalid (${REGISTRY}) — abort`); process.exit(2); }
    const apiKey = process.env.COINGECKO_API_KEY || undefined;

    const transport = buildTransport(
        resolveRpcUrls({
            primary: process.env.ARC_TESTNET_RPC,
            fallback: process.env.ARC_TESTNET_RPC_FALLBACK,
            defaultRpc: DEFAULT_RPC,
        }),
    );
    const publicClient = createPublicClient({ chain: arcTestnet, transport });

    log(`scanning CircuitBreakerTripped on GUARD=${GUARD} (lookback=${LOOKBACK_BLOCKS} blocks)`);
    const head = await publicClient.getBlockNumber();
    const fromBlock = head > LOOKBACK_BLOCKS ? head - LOOKBACK_BLOCKS : 0n;
    const logs = await publicClient.getLogs({
        address: GUARD, event: TRIPPED_EVENT, fromBlock, toBlock: head,
    });
    log(`found ${logs.length} CircuitBreakerTripped event(s) in [${fromBlock}, ${head}]`);

    const state = newPageState();
    const now = Date.now();
    let pages = 0;
    let dropped = 0;

    // Process oldest→newest so cooldown ordering is deterministic.
    for (const lg of logs) {
        const token = lg.args.token;
        const deviationBps = Number(lg.args.deviationBps ?? 0n);
        const meta = TOKEN_BY_ADDR.get(String(token).toLowerCase());
        const symbol = meta?.symbol || token;

        // Re-validate: compare the on-chain aggregator price to an INDEPENDENT
        // off-chain quote. Confirmed only if (a) we have both, and (b) they agree
        // within tolerance — i.e. the on-chain value the guard tripped on is the
        // real market value, so the deviation is genuine and not a spammed anchor.
        let confirmed = false;
        let detail = { symbol, deviationBps, reason: "no-meta" };
        if (meta) {
            const [chainUsd, indepUsd] = await Promise.all([
                onChainUsd(publicClient, token),
                independentQuote(meta, apiKey),
            ]);
            const agree = decideFxReferenceDrift(chainUsd, indepUsd, CONFIRM_TOLERANCE_BPS);
            // The independent feed confirms the on-chain price is real.
            confirmed = agree.ok === true;
            detail = {
                symbol, deviationBps, chainUsd, indepUsd,
                agreeDriftBps: agree.driftBps, confirmDecision: agree.reason || "agree",
            };
        }

        const decision = decidePage(
            { token, deviationBps, timestamp: Number(lg.args.timestamp ?? 0n) },
            { confirmed },
            state, now, PAGE_COOLDOWN_MS,
        );

        if (decision.page) {
            pages++;
            await emitAlert({ ...detail, block: lg.blockNumber?.toString(), txHash: lg.transactionHash, decision: decision.reason });
        } else {
            dropped++;
            log(`${symbol}: NO PAGE (${decision.reason})${detail.indepUsd !== undefined ? ` chainUsd=${detail.chainUsd} indepUsd=${detail.indepUsd}` : ""}`);
        }
    }

    log(`done events=${logs.length} pages=${pages} dropped=${dropped}`);
    // Non-zero exit when we paged so the systemd unit / operator notices.
    if (pages > 0) process.exit(3);
}

main().catch((err) => {
    log(`fatal: ${err?.message || err}`);
    process.exit(1);
});
