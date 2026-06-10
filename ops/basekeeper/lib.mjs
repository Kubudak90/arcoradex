// Base-Sepolia keeper helpers: Hermes fetch + blob decode + adapter ABI + chain def.
// Kept separate from ops/keepalive/lib.mjs (Arc) so the Arc keeper is untouched.
import { defineChain, parseAbi } from "viem";

// Post-2026-07-31 Pyth Core: Hermes pulls require an API key. Pass it via HERMES_API_KEY
// (sent as ?token=... or the documented header at run time). Pre-upgrade Hermes is keyless.
export const HERMES_BASE = process.env.HERMES_BASE_URL || "https://hermes.pyth.network";

export const baseSepolia = defineChain({
    id: 84532,
    name: "Base Sepolia",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [process.env.BASE_SEPOLIA_RPC || "https://sepolia.base.org"] } },
});

// The 3 Sepolia/mainnet-identical Pyth feed IDs (authoritative table).
export const FEED_IDS = {
    USDC: "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a",
    USDT: "0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b",
    EURC: "0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c",
};

// ChainlinkPythAdapterV2.updatePyth(bytes[]) — payable; getUpdateFee is on the Pyth contract.
export const ADAPTER_ABI = parseAbi([
    "function updatePyth(bytes[] calldata updateData) external payable",
    "function PYTH() view returns (address)",
    "function PYTH_PRICE_ID() view returns (bytes32)",
]);

export const PYTH_ABI = parseAbi([
    "function getUpdateFee(bytes[] calldata updateData) view returns (uint256)",
]);

/// Fetch the latest Hermes VAA update blobs for the given feed ids. Returns an array of
/// `0x`-prefixed hex blobs ready for updatePyth(bytes[]). Throws on non-200 / empty.
/// Hermes v2 endpoint: GET /v2/updates/price/latest?ids[]=<id>&ids[]=<id>&encoding=hex
export async function fetchHermesUpdates(ids, { apiKey, timeoutMs = 12_000, fetchImpl = fetch } = {}) {
    const params = new URLSearchParams();
    for (const id of ids) params.append("ids[]", id);
    params.append("encoding", "hex");
    let url = `${HERMES_BASE}/v2/updates/price/latest?${params.toString()}`;
    if (apiKey) url += `&token=${encodeURIComponent(apiKey)}`;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
        const res = await fetchImpl(url, { signal: ctrl.signal });
        if (!res.ok) throw new Error(`Hermes HTTP ${res.status}`);
        const json = await res.json();
        return parseHermesBlobs(json);
    } finally {
        clearTimeout(timer);
    }
}

/// Pure: extract the `0x`-prefixed binary update blobs from a Hermes v2 response.
/// Hermes v2 returns { binary: { encoding: "hex", data: ["<hex>", ...] } }. Each entry is the
/// hex VAA WITHOUT a 0x prefix -> prefix it. Throws if no data is present.
export function parseHermesBlobs(json) {
    const data = json?.binary?.data;
    if (!Array.isArray(data) || data.length === 0) throw new Error("Hermes: empty binary.data");
    return data.map((h) => (h.startsWith("0x") ? h : `0x${h}`));
}
