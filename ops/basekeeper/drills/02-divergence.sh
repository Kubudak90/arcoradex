#!/usr/bin/env bash
# Drill 2 (§10 divergence): set the EURC mock CL leg to $1.30 while Pyth EURC is ~$1.08-1.17;
# the primary/secondary gap exceeds maxDivergenceBps (60) -> peekPrice(EURC).safe == false
# and swaps into EURC revert. The mock CL feed is DEPLOYER-owned by design (deploy step 7)
# precisely so this drill is a one-liner.
# Permissionless infra: runs against live Sepolia OR a fork (RPC_URL controls which).
# Requires DEPLOYER_PRIVATE_KEY (the mock feed owner). RESTORE AFTERWARDS — see final echo.
# Reads the address ledger from ops/basekeeper/.env.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../.env"
RPC_URL="${RPC_URL:-${BASE_SEPOLIA_RPC:?set BASE_SEPOLIA_RPC or RPC_URL}}"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY (owner of the EURC mock CL feed)}"
# Runbook name: EURC_MOCK_CL_FEED; the deploy ledger emits the same address as CL_LEG_EURC.
EURC_MOCK_CL_FEED="${EURC_MOCK_CL_FEED:-${CL_LEG_EURC:?set EURC_MOCK_CL_FEED (CL_LEG_EURC in the deploy ledger)}}"

echo "== Drill 2: divergence (EURC mock CL leg -> \$1.30) =="
cast send "$EURC_MOCK_CL_FEED" "setAnswer(int256)" 130000000 \
    --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC_URL" >/dev/null
echo "OK: mock CL leg set to 130000000 (8-dec \$1.30)"

echo "-- peekPrice(EURC) MUST be unsafe (primary/secondary divergence over bound) --"
SAFE="$(cast call "$ADAPTER_EURC" "peekPrice(address)(uint256,bool)" "$TOKEN_EURC" --rpc-url "$RPC_URL" | tail -n 1)"
if [ "$SAFE" = "false" ]; then
    echo "OK: peekPrice(EURC).safe == false"
else
    echo "FAIL: expected peekPrice(EURC).safe == false, got: $SAFE"; exit 1
fi

echo "Drill 2 PASS."
echo "RESTORE the leg to \$1.15 when done:"
echo "  cast send $EURC_MOCK_CL_FEED 'setAnswer(int256)' 115000000 --private-key \$DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL"
