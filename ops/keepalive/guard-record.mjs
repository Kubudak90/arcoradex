// ArcoraDEX CumulativeDeviationGuard recorder.
//
// Reads each per-token OracleAggregator's latestRoundData(), scales the
// 8-decimal answer to 1e18, and calls CumulativeDeviationGuard.record(token,
// price1e18). The guard is event-only: this produces the PriceObserved /
// CircuitBreakerTripped event stream that off-chain monitoring consumes.
//
// record() is permissionless; this signs with the keeper EOA (already funded).
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

const GUARD = "0x035447f8d97A23fFfC32aa8bFb8ffDbC7B94E608";

// (token, aggregator) pairs — fixed P3 deployment addresses.
const TOKENS = [
    { symbol: "USDC",  token: "0x3BFa09fF6467639f0981948385bA1018Ac07d22C", aggregator: "0x6c6519cB0C66c2269505833382f23D4e8f915480" },
    { symbol: "USDT",  token: "0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B", aggregator: "0x3e58dd7fD2729A27961Ffb11d37BFf42874cAa34" },
    { symbol: "PYUSD", token: "0xfdB2c86d010698401f0b969348DC58b6659B96a3", aggregator: "0x78cB5F03b420F0CD2E8adcb141069F31a38E07E8" },
    { symbol: "DAI",   token: "0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE", aggregator: "0x3e542b4d2EdBFC965028eB85140BcFEa6868A37E" },
    { symbol: "EURC",  token: "0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD", aggregator: "0x1357cf421A8c3b732A882e4812AFba6209EBEBbc" },
    { symbol: "TRYC",  token: "0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61", aggregator: "0xFE3FE7F2b2693D676E4831283dd1B81665AC9faA" },
    { symbol: "BRLC",  token: "0xa13c0935A98e2c175b31A4054f698819271a8FfC", aggregator: "0xF5021349E0D6e2ACB00bEb105D7793202ac3Aa46" },
];

const AGG_ABI = parseAbi([
    "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
]);
const GUARD_ABI = parseAbi([
    "function record(address token, uint256 price1e18) external",
]);

const ts = () => new Date().toISOString();
const log = (msg) => console.log(`[arcoradex-guard-record] ${ts()} ${msg}`);

async function main() {
    const pk = process.env.KEEPER_PRIVATE_KEY;
    if (!pk) {
        log("KEEPER_PRIVATE_KEY missing — abort");
        process.exit(2);
    }
    const account = privateKeyToAccount(pk.startsWith("0x") ? pk : "0x" + pk);
    const publicClient = createPublicClient({ chain: arcTestnet, transport: http() });
    const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http() });

    let recorded = 0;
    let errored = 0;

    for (const t of TOKENS) {
        try {
            // latestRoundData() reverts if the aggregator's sources diverge or
            // are all unavailable — treat that as an errored token, not a hard stop.
            const round = await publicClient.readContract({
                address: t.aggregator, abi: AGG_ABI, functionName: "latestRoundData",
            });
            const answer = round[1]; // int256, 8-decimal
            if (answer <= 0n) throw new Error(`aggregator answer <= 0 (${answer})`);
            const price1e18 = answer * 10_000_000_000n; // 1e8 -> 1e18

            const hash = await walletClient.writeContract({
                address: GUARD, abi: GUARD_ABI, functionName: "record",
                args: [t.token, price1e18],
            });
            await publicClient.waitForTransactionReceipt({ hash });
            log(`${t.symbol}: recorded price1e18=${price1e18} tx=${hash}`);
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
