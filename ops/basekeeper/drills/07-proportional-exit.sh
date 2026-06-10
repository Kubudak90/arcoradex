#!/usr/bin/env bash
# Drill 7 (§8.3 emergency proportional exit): withdrawProportional(lp, deadline) burns the
# caller's LP and pays out the pro-rata basket of EVERY reserve. It has NO oracle dependency
# and NO pause gate — it MUST succeed even in the Drill-1 unsafe state and the Drill-8
# paused state (re-run this script in those states to complete the §8.3 evidence).
# Permissionless: runs against live Sepolia OR a fork (RPC_URL controls which).
# Requires DEPLOYER_PRIVATE_KEY (the deployer holds the bootstrap seed LP) or any
# LP-holding key. Reads the address ledger from ops/basekeeper/.env.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../.env"
RPC_URL="${RPC_URL:-${BASE_SEPOLIA_RPC:?set BASE_SEPOLIA_RPC or RPC_URL}}"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY (an LP-holding key)}"
LP_AMOUNT="${DRILL7_LP_AMOUNT:-1000000000000000000}" # 1.0 LP (18-dec); override with DRILL7_LP_AMOUNT
DEADLINE=$(($(date +%s) + 1800))
CALLER="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"

echo "== Drill 7: emergency proportional exit =="
echo "caller: $CALLER  lpAmount: $LP_AMOUNT  deadline: $DEADLINE"
echo "-- caller LP balance --"
cast call "$LP" "balanceOf(address)(uint256)" "$CALLER" --rpc-url "$RPC_URL"

echo "-- caller token balances BEFORE --"
for SYM in USDC USDT EURC; do
    TV="TOKEN_${SYM}"
    echo "  ${SYM}: $(cast call "${!TV}" "balanceOf(address)(uint256)" "$CALLER" --rpc-url "$RPC_URL")"
done

echo "-- withdrawProportional MUST succeed (even with a token unsafe / the pool paused) --"
cast send "$POOL" "withdrawProportional(uint256,uint256)" "$LP_AMOUNT" "$DEADLINE" \
    --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC_URL" >/dev/null
echo "OK: withdrawProportional succeeded"

echo "-- caller token balances AFTER (a pro-rata share of ALL 3 reserves received) --"
for SYM in USDC USDT EURC; do
    TV="TOKEN_${SYM}"
    echo "  ${SYM}: $(cast call "${!TV}" "balanceOf(address)(uint256)" "$CALLER" --rpc-url "$RPC_URL")"
done

echo "Drill 7 PASS."
