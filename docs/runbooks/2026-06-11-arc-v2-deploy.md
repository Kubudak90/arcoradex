# Arc Testnet V2 Deploy Runbook (chainId 5042002, MOCK oracles)

Deploys the full ArcoraDEX V2 stack on Arc testnet so the existing V2 UI runs on Arc
identically to Base Sepolia. Arc has NO Pyth and NO real Chainlink, so each token is
priced by a deployable keeper-settable `MockOracleAdapterV2Settable` (seeded SAFE at peg).

## Chain facts
- chainId 5042002 (hex 0x4CEF52); RPC https://rpc.testnet.arc.network; explorer https://testnet.arcscan.app
- Native gas is USDC (18-dec native units). Get testnet USDC from https://faucet.circle.com
  for the DEPLOYER and the KEEPER before running anything.

## Env (FRESH governance via the test mnemonic on testnet)
```
export DEPLOYER_PRIVATE_KEY=0x...          # broadcasts; mints + seeds; holds Arc USDC for gas
export KEEPER_EOA=0x...                     # the price-pusher address (becomes each adapter writer)
export GOV_USE_TEST_MNEMONIC=true           # testnet opt-in (factory's mainnet guard still applies)
export TIMELOCK_MIN_DELAY=172800            # 48h (or 0 for a fast launch, then updateDelay)
export ARC_TESTNET_RPC=https://rpc.testnet.arc.network
```
For a real-owners launch, omit GOV_USE_TEST_MNEMONIC and set GOV_SAFE_OWNERS / GOV_SAFE_THRESHOLD /
PG_SAFE_OWNERS / PG_SAFE_THRESHOLD instead.

## Deploy (single broadcast)
```
cd contracts
forge script script/DeployArcV2.s.sol:DeployArcV2 \
  --rpc-url "$ARC_TESTNET_RPC" --broadcast --slow -vvv
```
The orchestrator deploys governance -> 3 tokens -> 3 mock adapters (seeded SAFE at peg) ->
Registry (3 listed, §7 bands, low caps) -> Pool -> setPool + pause guardian -> bootstrap (all 3
seed; oracles safe by construction) -> handoffs -> invariant asserts -> ADDRESS LEDGER.

## Capture the ledger
Copy the `=== ADDRESS LEDGER ===` block into `ops/arckeeper/.env`:
```
REGISTRY=0x...   POOL=0x...   LP=0x...
GOV_SAFE=0x...   PG_SAFE=0x...   TIMELOCK=0x...
TOKEN_USDC=0x... ADAPTER_USDC=0x...
TOKEN_USDT=0x... ADAPTER_USDT=0x...
TOKEN_EURC=0x... ADAPTER_EURC=0x...
KEEPER_PRIVATE_KEY=0x...   ARC_TESTNET_RPC=https://rpc.testnet.arc.network
```
The SDK Arc config + app chain switcher (NEXT plan) consume the same addresses.

## Start the keeper
Push fresh safe prices so the adapters stay current (and so swaps/deposits never read unsafe):
```
cd ops/arckeeper && npm install && node push-prices-arc.mjs   # one-shot; wire to a systemd timer or /loop
```
Cadence: any interval well under the operator's comfort (e.g. 30 min) is fine — the mock adapter
has no intrinsic staleness, so this is for freshness/parity, not to avoid a revert.

## Post-deploy governance accepts
- Gov Safe (3/5) schedules + executes Timelock ops calling `Registry.acceptOwnership()` and
  `Pool.acceptOwnership()` (incurs TIMELOCK_MIN_DELAY).
- Gov Safe (3/5) calls each `adapter.acceptOwnership()` directly (Ownable2Step admin). The adapter
  `writer` stays the keeper EOA throughout — governance owns only the admin (writer-rotation) role.

## Failure drill (operator)
To simulate an oracle outage on a token: stop the keeper, then (with the keeper key, still the
writer) call `adapter.setSafe(token, false)`. Swaps INTO that token + single-token withdrawals
revert `OracleUnsafe`; `withdrawProportional` still works. Restore with `setPrice(token, peg, true)`.
