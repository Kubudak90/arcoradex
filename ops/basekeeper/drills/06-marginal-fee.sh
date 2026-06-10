#!/usr/bin/env bash
# Drill 6 (§7/§14 marginal fee): quote ONE large swap vs the HALF-size swap across a band
# boundary. Both quotes read the SAME pool state, so 2*fee(half) is the no-boundary
# baseline: the large swap's deeper-band tail pays a HIGHER marginal rate, hence
# fee(one) >= 2*fee(half) (equal only when no boundary is crossed). The printed fee/health
# breakdown is HUMAN-verified against the §7 band schedule (5/20/75/300 bps), per the runbook.
# Permissionless: runs against live Sepolia OR a fork (RPC_URL controls which).
# Reads the address ledger from ops/basekeeper/.env.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../.env"
RPC_URL="${RPC_URL:-${BASE_SEPOLIA_RPC:?set BASE_SEPOLIA_RPC or RPC_URL}}"
# 2,000 USDC (6-dec): at the $5,000 target / $1,000 floor it drives USDT health 100% -> 50%,
# spanning the 100% and 75% band boundaries. Override with DRILL6_AMOUNT.
AMOUNT="${DRILL6_AMOUNT:-2000000000}"
HALF=$((AMOUNT / 2))

echo "== Drill 6: marginal-fee verification (USDC -> USDT) =="
echo "-- quoteSwapV2 one large (${AMOUNT}): amountOut / protocolFee / feeUsd1e18 / postHealthBps --"
ONE="$(cast call "$POOL" "quoteSwapV2(address,address,uint256)(uint256,uint256,uint256,uint256)" \
    "$TOKEN_USDC" "$TOKEN_USDT" "$AMOUNT" --rpc-url "$RPC_URL")"
echo "$ONE"

echo "-- quoteSwapV2 one half (${HALF}): amountOut / protocolFee / feeUsd1e18 / postHealthBps --"
HALFQ="$(cast call "$POOL" "quoteSwapV2(address,address,uint256)(uint256,uint256,uint256,uint256)" \
    "$TOKEN_USDC" "$TOKEN_USDT" "$HALF" --rpc-url "$RPC_URL")"
echo "$HALFQ"

FEE_ONE="$(echo "$ONE" | awk 'NR==3{print $1}')"
FEE_HALF="$(echo "$HALFQ" | awk 'NR==3{print $1}')"
echo "-- comparison (feeUsd1e18) --"
awk -v one="$FEE_ONE" -v half="$FEE_HALF" 'BEGIN {
    printf "fee(one large)    = %s\n", one
    printf "2 * fee(one half) = %.0f\n", 2 * half
    if (one + 0 >= 2 * half) {
        print "marginal banding : OK — the large swap pays >= 2x the half (deeper-band tail rate)"
    } else {
        print "marginal banding : CHECK — the large swap paid LESS than 2x the half (unexpected)"
    }
}'
echo "Human-verify the fee/health breakdown against the §7 schedule (runbook Drill 6)."
