#!/usr/bin/env bash
# Drill 1 (§11 oracle failure): the EURC Chainlink leg (the in-process MockChainlinkFeed)
# goes stale -> peekPrice(EURC).safe == false and swaps INTO EURC revert OracleUnsafe.
# The production src/testnet/MockChainlinkFeed has NO setUpdatedAt — it refreshes updatedAt
# only on setAnswer — so this drill AGES the leg by warping fork time past the EURC
# chainlinkMaxStaleSeconds (7d).
#
# FORK-ONLY: live time cannot be fast-forwarded. Start a local fork first:
#   anvil --fork-url "$BASE_SEPOLIA_RPC"
# then run this script (RPC_URL defaults to the local anvil at http://127.0.0.1:8545).
# NOTE: the 30d warp also ages the Pyth legs (24h windows), so EVERY leg reads stale —
# that only strengthens the §11 unsafe signal asserted below. §12 signal:
# peekPrice(EURC).safe == false. Reads the address ledger from ops/basekeeper/.env.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../.env"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

echo "== Drill 1: oracle failure (EURC mock CL leg stale; fork) =="
cast rpc anvil_nodeInfo --rpc-url "$RPC_URL" >/dev/null 2>&1 \
    || { echo "FAIL: $RPC_URL is not a local anvil fork (fork-only drill; see header)"; exit 1; }

echo "-- warp 2592001s (> the 7d EURC chainlinkMaxStaleSeconds) + mine --"
cast rpc evm_increaseTime 2592001 --rpc-url "$RPC_URL" >/dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null

echo "-- peekPrice(EURC) MUST be unsafe --"
SAFE="$(cast call "$ADAPTER_EURC" "peekPrice(address)(uint256,bool)" "$TOKEN_EURC" --rpc-url "$RPC_URL" | tail -n 1)"
if [ "$SAFE" = "false" ]; then
    echo "OK: peekPrice(EURC).safe == false"
else
    echo "FAIL: expected peekPrice(EURC).safe == false, got: $SAFE"; exit 1
fi

echo "-- quoteSwapV2(USDC -> EURC) MUST revert OracleUnsafe --"
if cast call "$POOL" "quoteSwapV2(address,address,uint256)(uint256,uint256,uint256,uint256)" \
      "$TOKEN_USDC" "$TOKEN_EURC" 1000000 --rpc-url "$RPC_URL" 2>/tmp/drill1.err; then
    echo "FAIL: swap into EURC did not revert"; exit 1
else
    # match the decoded name or the raw OracleUnsafe(address) selector 0x6a59c510
    grep -q -e "OracleUnsafe" -e "0x6a59c510" /tmp/drill1.err && echo "OK: reverted OracleUnsafe" \
        || { echo "FAIL: reverted for the wrong reason:"; cat /tmp/drill1.err; exit 1; }
fi

echo "Drill 1 PASS. (Proportional exit in this unsafe state is asserted by 07-proportional-exit.sh.)"
