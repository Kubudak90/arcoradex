#!/usr/bin/env bash
# Drill 3 (§11 stale Pyth): stop pulling Pyth; past pythMaxStaleSeconds (24h) ALL three
# tokens' Pyth legs read stale -> every peekPrice(*).safe == false. The keeper pull
# (update-pyth-base-sepolia.mjs) restores safety. §12 signal: Pyth freshness alarm.
#
# FORK-ONLY: live time cannot be fast-forwarded. Start a local fork first:
#   anvil --fork-url "$BASE_SEPOLIA_RPC"
# then run this script (RPC_URL defaults to the local anvil at http://127.0.0.1:8545).
#
# RESTORE-PHASE NOTE: a fork's clock cannot be rewound, and a fresh Hermes update carries a
# REAL wall-clock publishTime — on the still-warped fork even a fresh pull would read > 24h
# stale forever. The restore phase therefore `anvil_reset`s the fork back to the live head
# (clearing the warp) BEFORE running the keeper; the fresh pull then flips peekPrice safe.
#
# Reads the address ledger from ops/basekeeper/.env (the keeper consumes ADAPTER_* from it).
# KEEPER_PRIVATE_KEY defaults to anvil dev key 0 (public Foundry test key — NOT a secret),
# which anvil funds on the fork.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
# shellcheck disable=SC1091
source "${HERE}/../.env"
set +a
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
: "${BASE_SEPOLIA_RPC:?set BASE_SEPOLIA_RPC (the fork upstream; needed by anvil_reset)}"
KEEPER_PRIVATE_KEY="${KEEPER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

echo "== Drill 3: stale Pyth (fork) =="
cast rpc anvil_nodeInfo --rpc-url "$RPC_URL" >/dev/null 2>&1 \
    || { echo "FAIL: $RPC_URL is not a local anvil fork (fork-only drill; see header)"; exit 1; }

echo "-- warp 86401s (> the 24h pythMaxStaleSeconds) + mine --"
cast rpc evm_increaseTime 86401 --rpc-url "$RPC_URL" >/dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null

echo "-- ALL peekPrice(*) MUST be unsafe --"
for SYM in USDC USDT EURC; do
    AV="ADAPTER_${SYM}"; TV="TOKEN_${SYM}"
    SAFE="$(cast call "${!AV}" "peekPrice(address)(uint256,bool)" "${!TV}" --rpc-url "$RPC_URL" | tail -n 1)"
    if [ "$SAFE" = "false" ]; then
        echo "OK: peekPrice(${SYM}).safe == false"
    else
        echo "FAIL: expected peekPrice(${SYM}).safe == false, got: $SAFE"; exit 1
    fi
done

echo "-- anvil_reset to the live head (clears the warp; see RESTORE-PHASE NOTE) --"
cast rpc anvil_reset "{\"forking\":{\"jsonRpcUrl\":\"${BASE_SEPOLIA_RPC}\"}}" --rpc-url "$RPC_URL" >/dev/null

echo "-- keeper pull MUST restore safety --"
BASE_SEPOLIA_RPC="$RPC_URL" BASE_SEPOLIA_RPC_FALLBACK="" KEEPER_PRIVATE_KEY="$KEEPER_PRIVATE_KEY" \
    node "${HERE}/../update-pyth-base-sepolia.mjs"

for SYM in USDC USDT EURC; do
    AV="ADAPTER_${SYM}"; TV="TOKEN_${SYM}"
    SAFE="$(cast call "${!AV}" "peekPrice(address)(uint256,bool)" "${!TV}" --rpc-url "$RPC_URL" | tail -n 1)"
    if [ "$SAFE" = "true" ]; then
        echo "OK: peekPrice(${SYM}).safe == true (keeper restored)"
    else
        echo "FAIL: expected peekPrice(${SYM}).safe == true after the keeper pull, got: $SAFE"; exit 1
    fi
done

echo "Drill 3 PASS."
