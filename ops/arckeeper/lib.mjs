// Arc-V2 keeper helpers: chain def 5042002 + adapter ABI + pure price-shaping.
// Kept separate from ops/keepalive/lib.mjs (V1 Arc feeds) so that keeper is untouched.
import { defineChain, parseAbi } from "viem";
import { resolveRpcUrls } from "../keepalive/lib.mjs";

const DEFAULT_RPC = "https://rpc.testnet.arc.network";

export const arcTestnet = defineChain({
    id: 5042002,
    name: "Arc Testnet",
    nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, // Arc native gas = USDC (18-dec)
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

// MockOracleAdapterV2Settable.setPrice(token, price1e18, safe) — writer-gated.
export const ADAPTER_ABI = parseAbi([
    "function setPrice(address token, uint256 price1e18, bool safe) external",
    "function peekPrice(address token) view returns (uint256 price1e18, bool safe)",
    "function writer() view returns (address)",
]);

// The 3 Arc pool tokens' USD pegs (1e18). Must match DeployArcV2._cfg() pegPrice1e18.
export const PEGS_1E18 = {
    USDC: 1_000000000000000000n,
    USDT: 1_000000000000000000n,
    EURC: 1_150000000000000000n,
};

/// Pure: build the per-token push list from the ledger env. Returns
/// [{ symbol, adapter, token, price1e18 }] for every symbol whose ADAPTER_<S> and
/// TOKEN_<S> are both present. Throws if a present adapter has no matching peg.
export function buildPushList(env) {
    const out = [];
    for (const symbol of Object.keys(PEGS_1E18)) {
        const adapter = env[`ADAPTER_${symbol}`];
        const token = env[`TOKEN_${symbol}`];
        if (!adapter || !token) continue;
        const price1e18 = PEGS_1E18[symbol];
        if (price1e18 === undefined) throw new Error(`no peg for ${symbol}`);
        out.push({ symbol, adapter, token, price1e18 });
    }
    return out;
}
