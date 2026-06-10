#!/usr/bin/env bash
# Drill 5 (§7 reserve-floor): a swap that would push the output reserve below
# minimumReserveUsd reverts ReserveFloorBreached; maxSwapOut returns the safe ceiling.
# Reads the address ledger from ops/basekeeper/.env (REGISTRY/POOL/TOKEN_*).
# Permissionless: runs against live Sepolia OR a fork (RPC_URL controls which).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../.env"
RPC_URL="${RPC_URL:-${BASE_SEPOLIA_RPC:?set BASE_SEPOLIA_RPC or RPC_URL}}"

echo "== Drill 5: reserve-floor =="
echo "-- maxSwapOut(USDT) (the floor-safe ceiling) --"
cast call "$POOL" "maxSwapOut(address)(uint256,uint256)" "$TOKEN_USDT" --rpc-url "$RPC_URL"

echo "-- quoteSwapV2 with an over-max input MUST revert ReserveFloorBreached --"
if cast call "$POOL" "quoteSwapV2(address,address,uint256)(uint256,uint256,uint256,uint256)" \
      "$TOKEN_USDC" "$TOKEN_USDT" 1000000000000 --rpc-url "$RPC_URL" 2>/tmp/drill5.err; then
    echo "FAIL: over-max swap did not revert"; exit 1
else
    grep -q "ReserveFloorBreached" /tmp/drill5.err && echo "OK: reverted ReserveFloorBreached" \
        || { echo "FAIL: reverted for the wrong reason:"; cat /tmp/drill5.err; exit 1; }
fi
