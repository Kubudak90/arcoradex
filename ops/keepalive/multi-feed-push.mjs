// Arcora v0.7 multi-feed price keeper.
//
// Pulls 6 USD prices from CoinGecko (USDC stays hardcoded at peg = $1.0000)
// and pushes them into the corresponding MockChainlinkFeed contracts on Arc
// testnet. Skips pushes when the on-chain answer is already current and
// rejects fetched prices that fall outside per-feed sanity bands.
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
const FEEDS = [
    { symbol: "USDC",  feed: process.env.FEED_USDC,  hardcodedAnswer1e8: 100_000_000n, band: { min: 1.00, max: 1.00 } },
    { symbol: "USDT",  feed: process.env.FEED_USDT,  coingeckoId: "tether",          band: { min: 0.95, max: 1.05 } },
    { symbol: "PYUSD", feed: process.env.FEED_PYUSD, coingeckoId: "paypal-usd",      band: { min: 0.95, max: 1.05 } },
    { symbol: "DAI",   feed: process.env.FEED_DAI,   coingeckoId: "dai",             band: { min: 0.95, max: 1.05 } },
    { symbol: "EURC",  feed: process.env.FEED_EURC,  coingeckoVsCurrency: "eur",     band: { min: 1.00, max: 1.30 } },
    { symbol: "TRYC",  feed: process.env.FEED_TRYC,  coingeckoVsCurrency: "try",     band: { min: 0.01, max: 0.10 } },
    { symbol: "BRLC",  feed: process.env.FEED_BRLC,  coingeckoVsCurrency: "brl",     band: { min: 0.10, max: 0.30 } },
];

const FEED_ABI = parseAbi([
    "function setAnswer(int256 newAnswer) external",
    "function latestAnswer() view returns (int256)",
]);

const ts = () => new Date().toISOString();
const log = (msg) => console.log(`[arcora-v07-feeds] ${ts()} ${msg}`);

const priceTo1e8 = (usd) => BigInt(Math.round(usd * 1e8));

async function fetchUsdPrice(feed, apiKey) {
    if (feed.hardcodedAnswer1e8 !== undefined) {
        return Number(feed.hardcodedAnswer1e8) / 1e8;
    }
    const headers = apiKey ? { "x-cg-pro-api-key": apiKey } : undefined;
    if (feed.coingeckoId) {
        const url = `https://api.coingecko.com/api/v3/simple/price?ids=${feed.coingeckoId}&vs_currencies=usd`;
        const res = await fetch(url, { headers });
        if (!res.ok) throw new Error(`CoinGecko HTTP ${res.status} for ${feed.coingeckoId}`);
        const json = await res.json();
        const usd = json[feed.coingeckoId]?.usd;
        if (typeof usd !== "number") throw new Error(`No usd field in response for ${feed.coingeckoId}`);
        return usd;
    }
    if (feed.coingeckoVsCurrency) {
        const url = `https://api.coingecko.com/api/v3/simple/price?ids=usd&vs_currencies=${feed.coingeckoVsCurrency}`;
        const res = await fetch(url, { headers });
        if (!res.ok) throw new Error(`CoinGecko HTTP ${res.status} for usd/${feed.coingeckoVsCurrency}`);
        const json = await res.json();
        const rate = json.usd?.[feed.coingeckoVsCurrency];
        if (typeof rate !== "number" || rate === 0) throw new Error(`No ${feed.coingeckoVsCurrency} rate`);
        return 1 / rate;
    }
    throw new Error(`feed ${feed.symbol} has no price source configured`);
}

async function main() {
    const pk = process.env.DEPLOYER_PRIVATE_KEY;
    if (!pk) {
        log("DEPLOYER_PRIVATE_KEY missing — abort");
        process.exit(2);
    }
    const apiKey = process.env.COINGECKO_API_KEY || undefined;

    const account = privateKeyToAccount(pk);
    const publicClient = createPublicClient({ chain: arcTestnet, transport: http() });
    const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http() });

    let updated = 0;
    let skipped = 0;
    let errored = 0;

    for (const f of FEEDS) {
        if (!f.feed) {
            log(`${f.symbol}: feed address env missing — skip`);
            errored++;
            continue;
        }
        try {
            const usd = await fetchUsdPrice(f, apiKey);
            if (usd < f.band.min || usd > f.band.max) {
                log(`${f.symbol}: price ${usd} outside band [${f.band.min}, ${f.band.max}] — skip`);
                skipped++;
                continue;
            }
            const newAnswer = priceTo1e8(usd);
            const prev = await publicClient.readContract({
                address: f.feed,
                abi: FEED_ABI,
                functionName: "latestAnswer",
            });
            if (prev === newAnswer) {
                log(`${f.symbol}: unchanged at ${prev}`);
                skipped++;
                continue;
            }
            const hash = await walletClient.writeContract({
                address: f.feed,
                abi: FEED_ABI,
                functionName: "setAnswer",
                args: [newAnswer],
            });
            await publicClient.waitForTransactionReceipt({ hash });
            log(`${f.symbol}: ${prev} -> ${newAnswer} (usd=${usd}) tx=${hash}`);
            updated++;
        } catch (err) {
            log(`${f.symbol}: ERROR ${err?.message || err}`);
            errored++;
        }
    }

    log(`done updated=${updated} skipped=${skipped} errored=${errored}`);
    if (errored === FEEDS.length) process.exit(1);
}

main().catch((err) => {
    log(`fatal: ${err?.message || err}`);
    process.exit(1);
});
