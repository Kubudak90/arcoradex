// ArcoraDEX multi-feed price keeper (renamed from arcora-v07-feeds).
//
// Pulls 6 USD prices from CoinGecko (USDC stays hardcoded at peg = $1.0000)
// and pushes each price to both the primary and the P3 secondary
// MockChainlinkFeedV2 feed on Arc testnet. Skips pushes when the on-chain
// answer is already current, and rejects fetched prices that fall outside
// per-feed sanity bands.
//
// Designed to run from a systemd timer on the VPS (Type=oneshot every 30 min).

import {
    createPublicClient,
    createWalletClient,
    http,
    parseAbi,
    defineChain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const arcTestnet = defineChain({
    id: 5042002,
    name: "Arc Testnet",
    nativeCurrency: { name: "Arc", symbol: "ARC", decimals: 18 },
    rpcUrls: {
        default: { http: [process.env.ARC_TESTNET_RPC || "https://rpc.testnet.arc.network"] },
    },
});

// Each feed has either:
//   - hardcodedAnswer1e8: skip CoinGecko, always push this answer
//   - coingeckoId: fetch USD/<id> directly
//   - coingeckoVsCurrency: fetch USD vs <currency> and invert (for FX legs
//     where CoinGecko prices the foreign currency rather than the stable)
//
// `maxDevBps` mirrors the registry's per-token maxOracleDeviationBps.
// The keeper caps each push so |new - prev| ≤ prev × maxDevBps / 10000.
// This lets the registry stay on production-grade tolerances (50 bps for
// USD pegs, 150 bps for FX pegs) without bricking swaps when the live
// market drifts faster than one tick: the keeper takes multiple ticks
// to walk the on-chain answer toward the true price.
const FEEDS = [
    { symbol: "USDC",  feed: process.env.FEED_USDC,  secondary: process.env.P3_SECONDARY_USDC,  hardcodedAnswer1e8: 100_000_000n, band: { min: 1.00, max: 1.00 }, maxDevBps: 50,  peg: 1.00, maxPegDriftBps: 200 },
    { symbol: "USDT",  feed: process.env.FEED_USDT,  secondary: process.env.P3_SECONDARY_USDT,  coingeckoId: "tether",          band: { min: 0.95, max: 1.05 }, maxDevBps: 50,  peg: 1.00, maxPegDriftBps: 200 },
    { symbol: "PYUSD", feed: process.env.FEED_PYUSD, secondary: process.env.P3_SECONDARY_PYUSD, coingeckoId: "paypal-usd",      band: { min: 0.95, max: 1.05 }, maxDevBps: 50,  peg: 1.00, maxPegDriftBps: 200 },
    { symbol: "DAI",   feed: process.env.FEED_DAI,   secondary: process.env.P3_SECONDARY_DAI,   coingeckoId: "dai",             band: { min: 0.95, max: 1.05 }, maxDevBps: 50,  peg: 1.00, maxPegDriftBps: 200 },
    { symbol: "EURC",  feed: process.env.FEED_EURC,  secondary: process.env.P3_SECONDARY_EURC,  coingeckoVsCurrency: "eur",     band: { min: 1.00, max: 1.30 }, maxDevBps: 150, peg: null, maxPegDriftBps: null },
    { symbol: "TRYC",  feed: process.env.FEED_TRYC,  secondary: process.env.P3_SECONDARY_TRYC,  coingeckoVsCurrency: "try",     band: { min: 0.01, max: 0.10 }, maxDevBps: 150, peg: null, maxPegDriftBps: null },
    { symbol: "BRLC",  feed: process.env.FEED_BRLC,  secondary: process.env.P3_SECONDARY_BRLC,  coingeckoVsCurrency: "brl",     band: { min: 0.10, max: 0.30 }, maxDevBps: 150, peg: null, maxPegDriftBps: null },
];

const FEED_ABI = parseAbi([
    "function setAnswer(int256 newAnswer) external",
    "function latestAnswer() view returns (int256)",
    "function latestUpdatedAt() view returns (uint256)",
]);

// Push setAnswer even when the value is unchanged if the on-chain timestamp
// is older than this. The pool reverts swaps when oracle age exceeds
// 1 hour (MAX_STALE_SECONDS); 30 min keeps a comfortable margin for the
// next 30-min keeper tick.
const REFRESH_THRESHOLD_SECONDS = 30 * 60;

const ts = () => new Date().toISOString();
const log = (msg) => console.log(`[arcoradex-feeds] ${ts()} ${msg}`);

const priceTo1e8 = (usd) => BigInt(Math.round(usd * 1e8));

/// Fetches all USD prices in (at most) two batched CoinGecko calls — one for
/// stable→USD ids, one for USD→fiat-currency vs_currencies. Returns a map
/// keyed by feed symbol. A failed batch leaves its symbols absent from the
/// map so per-feed error handling in main() surfaces the gap cleanly.
async function fetchAllPrices(feeds, apiKey) {
    const headers = apiKey ? { "x-cg-pro-api-key": apiKey } : undefined;
    const out = new Map();

    const ids        = feeds.filter((f) => f.coingeckoId).map((f) => f.coingeckoId);
    const currencies = feeds.filter((f) => f.coingeckoVsCurrency).map((f) => f.coingeckoVsCurrency);

    for (const f of feeds) {
        if (f.hardcodedAnswer1e8 !== undefined) {
            out.set(f.symbol, Number(f.hardcodedAnswer1e8) / 1e8);
        }
    }

    if (ids.length > 0) {
        try {
            const url = `https://api.coingecko.com/api/v3/simple/price?ids=${ids.join(",")}&vs_currencies=usd`;
            const res = await fetch(url, { headers });
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            const json = await res.json();
            for (const f of feeds) {
                if (!f.coingeckoId) continue;
                const usd = json[f.coingeckoId]?.usd;
                if (typeof usd === "number") out.set(f.symbol, usd);
            }
        } catch (err) {
            log(`batch usd-prices: ERROR ${err?.message || err}`);
        }
    }

    if (currencies.length > 0) {
        try {
            const url = `https://api.coingecko.com/api/v3/simple/price?ids=usd&vs_currencies=${currencies.join(",")}`;
            const res = await fetch(url, { headers });
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            const json = await res.json();
            for (const f of feeds) {
                if (!f.coingeckoVsCurrency) continue;
                const rate = json.usd?.[f.coingeckoVsCurrency];
                if (typeof rate === "number" && rate !== 0) out.set(f.symbol, 1 / rate);
            }
        } catch (err) {
            log(`batch fx-rates: ERROR ${err?.message || err}`);
        }
    }

    return out;
}

/// Pushes one band-checked USD price to a single feed address. Encapsulates
/// the per-address logic (deviation cap vs that feed's own on-chain `prev`,
/// staleness-refresh, skip-when-current). Returns "updated" | "skipped" | "errored".
async function pushFeedAddress(publicClient, walletClient, label, feedAddr, usd, maxDevBps) {
    try {
        const targetAnswer = priceTo1e8(usd);
        const [prev, lastUpdated] = await Promise.all([
            publicClient.readContract({ address: feedAddr, abi: FEED_ABI, functionName: "latestAnswer" }),
            publicClient.readContract({ address: feedAddr, abi: FEED_ABI, functionName: "latestUpdatedAt" }),
        ]);
        const ageSeconds = Math.floor(Date.now() / 1000) - Number(lastUpdated);

        // Cap each push so the swap-time PriceGuard never reverts. The
        // pool compares against lastAcceptedPrice (set on the prior swap),
        // not the prior oracle answer, so capping vs `prev` is a strict
        // upper bound on the deviation any swap can observe.
        let newAnswer = targetAnswer;
        let capped = false;
        if (prev > 0n) {
            const maxDeltaAbs = (prev * BigInt(maxDevBps)) / 10_000n;
            const delta = targetAnswer > prev ? targetAnswer - prev : prev - targetAnswer;
            if (delta > maxDeltaAbs) {
                newAnswer = targetAnswer > prev ? prev + maxDeltaAbs : prev - maxDeltaAbs;
                capped = true;
            }
        }

        if (prev === newAnswer && ageSeconds < REFRESH_THRESHOLD_SECONDS) {
            log(`${label}: unchanged at ${prev}, fresh (${ageSeconds}s)`);
            return "skipped";
        }
        const hash = await walletClient.writeContract({
            address: feedAddr,
            abi: FEED_ABI,
            functionName: "setAnswer",
            args: [newAnswer],
        });
        await publicClient.waitForTransactionReceipt({ hash });
        const reason = capped
            ? `capped@${maxDevBps}bps (target=${targetAnswer})`
            : prev === newAnswer ? "refresh" : "value";
        log(`${label}: ${prev} -> ${newAnswer} (usd=${usd}, ${reason}, age=${ageSeconds}s) tx=${hash}`);
        return capped ? "capped-updated" : "updated";
    } catch (err) {
        log(`${label}: ERROR ${err?.message || err}`);
        return "errored";
    }
}

async function main() {
    const pk = process.env.KEEPER_PRIVATE_KEY;
    if (!pk) {
        log("KEEPER_PRIVATE_KEY missing — abort");
        process.exit(2);
    }
    const apiKey = process.env.COINGECKO_API_KEY || undefined;

    const account = privateKeyToAccount(pk);
    const publicClient = createPublicClient({ chain: arcTestnet, transport: http() });
    const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http() });

    let updated = 0;
    let skipped = 0;
    let errored = 0;
    let capped = 0;
    const cappedFeedsThisRun = new Map(); // symbol -> { primary: bool, secondary: bool }

    const prices = await fetchAllPrices(FEEDS, apiKey);

    for (const f of FEEDS) {
        const usd = prices.get(f.symbol);
        if (typeof usd !== "number") {
            log(`${f.symbol}: ERROR price source returned no value (likely 429 or upstream gap) — skip both feeds`);
            errored += 2;
            continue;
        }
        if (usd < f.band.min || usd > f.band.max) {
            log(`${f.symbol}: price ${usd} outside band [${f.band.min}, ${f.band.max}] — skip both feeds`);
            skipped += 2;
            continue;
        }
        if (f.peg !== null && f.peg > 0 && f.maxPegDriftBps !== null) {
            const driftBps = Math.abs(usd - f.peg) * 10_000 / f.peg;
            if (driftBps > f.maxPegDriftBps) {
                log(`${f.symbol}: usd=${usd} drifts ${driftBps.toFixed(1)} bps from peg=${f.peg} (cap=${f.maxPegDriftBps} bps) — skip both feeds`);
                errored += 2;
                continue;
            }
        }
        for (const [role, addr] of [["primary", f.feed], ["secondary", f.secondary]]) {
            const label = `${f.symbol} ${role}`;
            if (!addr) {
                log(`${label}: feed address env missing — skip`);
                errored++;
                continue;
            }
            const outcome = await pushFeedAddress(publicClient, walletClient, label, addr, usd, f.maxDevBps);
            if (outcome === "updated") {
                updated++;
            } else if (outcome === "skipped") {
                skipped++;
            } else if (outcome === "capped-updated") {
                updated++;
                capped++;
                const entry = cappedFeedsThisRun.get(f.symbol) ?? { primary: false, secondary: false };
                entry[role] = true;
                cappedFeedsThisRun.set(f.symbol, entry);
            } else {
                errored++;
            }
        }
    }

    const bothCapped = [...cappedFeedsThisRun.entries()]
        .filter(([, v]) => v.primary && v.secondary)
        .map(([s]) => s);
    if (bothCapped.length > 0) {
        log(`WARN: both primary and secondary capped this run for: ${bothCapped.join(", ")} — sustained live drift > maxDevBps`);
    }
    log(`done updated=${updated} skipped=${skipped} errored=${errored} capped=${capped}`);
    if (errored > 0 || bothCapped.length > 0) process.exit(1);
}

main().catch((err) => {
    log(`fatal: ${err?.message || err}`);
    process.exit(1);
});
