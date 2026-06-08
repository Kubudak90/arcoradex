# ArcoraDEX Base-First V2 Design

**Date:** 2026-06-08
**Status:** Design approved; pending written-spec review
**Authors:** Huseyin Arslan + Codex

## 1. Decision Summary

ArcoraDEX V2 will launch first on Base with real-value liquidity. Arc remains a
planned second deployment and must independently pass the same oracle and
operational admission criteria. Cross-chain settlement is a later, separate
project.

The first Base production pool supports USDC, EURC, and USDT. The Pool is
immutable. A governance-controlled Registry permits additional stablecoins
without upgrading Pool logic.

V2 preserves single-token withdrawal as a product feature while preventing one
withdrawal or swap from consuming a token's protected reserve. It adds
token-specific reserve floors, marginal utilization fees, strict dual-source
oracles, fail-closed transaction handling, and production monitoring.

## 2. Scope Decomposition

This design covers the first project only:

1. Base-first ArcoraDEX V2 contracts, SDK, application, deployment, oracle
   integration, monitoring, and controlled mainnet rollout.
2. A later Arc deployment will reuse the audited V2 code and have independent
   contracts, liquidity, LP shares, configuration, and oracle admission.
3. A later multichain settlement layer will move a settlement asset between
   chains and execute against the destination's local pool. It will not create a
   shared cross-chain LP token or shared cross-chain NAV in its first version.

## 3. Goals

- Preserve oracle-priced swaps and single-token LP withdrawals.
- Prevent swaps and single-token withdrawals from draining a protected reserve.
- Charge progressively more only as an output reserve becomes scarce.
- Make transaction splitting economically equivalent to one large transaction.
- Refuse value-bearing operation without two independent direct token/USD
  sources and real monitoring.
- Add future stablecoins through governance configuration, not a Pool upgrade.
- Keep LPs able to exit proportionally during an oracle incident.

## 4. Non-Goals

- An upgradeable Pool proxy.
- A constant-product or other price-impact curve.
- Partial fulfillment or a withdrawal queue.
- Automatic unpause.
- Cross-chain LP accounting or shared liquidity.
- Launching TRYC or BRLC from an FX rate alone.

## 5. Approaches Considered

### 5.1 Unrestricted single-token withdrawal

This preserves the current UX but allows a large LP to exhaust one reserve. It
does not adequately protect remaining LPs and is rejected.

### 5.2 Hard reserve floor with one flat fee

This prevents complete depletion but prices a healthy reserve and a critically
scarce reserve identically. It creates abrupt behavior at the boundary and does
not compensate LPs for utilization risk. It is rejected.

### 5.3 Protected floor with marginal fee bands

This preserves single-token withdrawal, prevents reserve depletion, and
increases compensation as the output reserve approaches its floor. Fees are
calculated marginally across bands, preventing a user from reducing fees by
splitting a transaction. This is the selected approach.

For extensibility, an immutable Pool plus configurable Registry was selected
over a UUPS proxy. Adding assets is a configuration operation and does not
justify exposing all Pool funds to implementation-upgrade authority, initializer
risk, or storage-layout mistakes.

## 6. Contracts and Configuration

### 6.1 Immutable Pool

`ArcoraDexPoolV2` contains the finalized swap, deposit, withdrawal, reserve-floor,
fee-band, accounting, pause, and proportional-exit logic. The deployed Pool
implementation is not behind an upgradeable proxy.

### 6.2 Extensible Registry

Each admitted token has governance-controlled configuration:

- token address and decimals;
- active status;
- oracle adapter address;
- `minimumReserveUsd`;
- `targetReserveUsd`;
- oracle freshness, confidence, and divergence limits;
- fee-band boundaries and rates;
- token-level deposit or reserve cap used during rollout.

Configuration must satisfy:

- `targetReserveUsd > minimumReserveUsd`;
- fee bands are ordered and contiguous;
- fee rates do not decrease as reserve health falls;
- no rate exceeds the protocol maximum;
- the token has passed oracle and operational admission checks.

All additions and parameter changes go through the Governance Safe and a
48-hour `TimelockController`. The Pause Guardian may only pause. It cannot
unpause, add tokens, alter oracle sources, change limits, or upgrade Pool logic.

## 7. Reserve Health and Dynamic Fees

For an output token:

```text
availableUsd = targetReserveUsd - minimumReserveUsd
usableRemainingUsd = reserveUsd - minimumReserveUsd
health = clamp(usableRemainingUsd / availableUsd, 0, 1)
```

Reserve above `targetReserveUsd` is in the healthiest band. No swap or
single-token withdrawal may make the accounted reserve fall below
`minimumReserveUsd`.

Initial fee schedule:

| Remaining health | Marginal fee |
|---|---:|
| 75%-100% and above | 0.05% |
| 50%-75% | 0.20% |
| 25%-50% | 0.75% |
| 0%-25% | 3.00% |
| Below 0% | prohibited |

The schedule applies to output consumed by both swaps and single-token
withdrawals. Each portion of a transaction is charged at the rate of the band it
crosses. A transaction spanning multiple bands pays the sum of the band-level
fees. Therefore, splitting the same gross output into multiple transactions
does not lower the total fee, apart from bounded integer rounding.

The existing protocol/LP fee split applies to the dynamic fee. The protocol
share accrues separately; the LP share remains in the output reserve.

Band capacity is measured in actual reserve debit, not gross entitlement. For a
segment charged at one fee rate:

```text
segmentFee = segmentGrossEntitlement * bandFeeRate
segmentProtocolFee = segmentFee * protocolFeeShare
segmentUserOutput = segmentGrossEntitlement - segmentFee
segmentReserveDebit = segmentUserOutput + segmentProtocolFee
```

The algorithm consumes as much gross entitlement as can fit in the current
band's remaining debit capacity, then continues in the next band. The amount
retained for LPs is not debited from reserves. After summing all segments:

```text
reserveDebit = totalUserOutput + totalProtocolFeeOutput
postReserve = preReserve - reserveDebit
require postReserveUsd >= minimumReserveUsd
```

Integer division always rounds conservatively: maximum calculations round down,
fees round up when needed to preserve the floor, and execution never returns
more than the corresponding quote. Quotes and execution share one internal band
traversal implementation.

## 8. User Flows

### 8.1 Swap

1. Validate both tokens and both oracle states.
2. Measure the actual received input amount.
3. Convert received input to gross output entitlement using accepted prices.
4. Traverse output-token reserve bands and calculate marginal fees.
5. Calculate user net output and protocol fee.
6. Enforce `minOut`, accounting invariants, and the output reserve floor.
7. Update reserves and transfer output.

### 8.2 Single-token withdrawal

1. Validate the selected output token and all oracle data needed to value NAV.
2. Calculate the LP owner's gross USD entitlement.
3. Traverse the selected output token's bands marginally.
4. Enforce the user's `minTokenOut` and the reserve floor.
5. Burn LP and transfer the net output.

There is no queue and no partial fulfillment. An amount above the safe maximum
reverts on-chain.

### 8.3 Proportional emergency withdrawal

Proportional withdrawal burns LP and returns the user's pro-rata share of every
accounted reserve. It remains available when a token oracle is unsafe or the
Pool is paused because it does not require USD valuation or token selection.
Protocol fees are excluded from the returned reserves.

The proportional path remains subject to reentrancy protection and measured
balance/accounting invariants, but not to reserve floors; every LP receives the
same basket and no token is preferentially extracted.

## 9. Views, SDK, and Application

The Pool or SDK exposes:

- `reserveHealth(token)`;
- `maxSwapOut(tokenOut)`;
- `maxWithdraw(tokenOut, account)`;
- `quoteSwapV2(tokenIn, tokenOut, amountIn)`;
- `quoteWithdrawV2(tokenOut, lpAmount)`;
- the marginal fee breakdown and post-transaction reserve health.

`maxSwapOut` returns the maximum executable net token output and its associated
gross entitlement at the current oracle state. `maxWithdraw` returns the
maximum LP amount the account may burn through the single-token path, together
with the resulting net token output. These values are quotes, not reservations;
execution recomputes them against current state.

The application must:

- show the current reserve health and estimated dynamic fee;
- provide a `Max` action that selects only the maximum floor-safe amount;
- warn when an entered amount exceeds the safe maximum;
- never submit an over-maximum transaction;
- refresh the quote immediately before submission;
- still rely on the contract as the final enforcement layer;
- offer proportional withdrawal when oracle-dependent paths are unavailable.

## 10. Oracle Architecture

Each production token requires two independent, direct `token/USD` sources:

- Chainlink as primary;
- Pyth as secondary.

An `OracleAdapter` normalizes decimals and validates both sources. A token is
unsafe if either source is stale or invalid, Pyth confidence exceeds its
configured bound, or source divergence exceeds the configured limit. A single
surviving source is insufficient for an oracle-priced value transfer.

An FX feed such as TRY/USD or BRL/USD does not prove that a TRYC or BRLC token is
redeemable at that FX value. Such tokens remain disabled until they have a
qualified direct token peg/market source in addition to the other independent
source.

The initial Base production set is USDC, EURC, and USDT, conditional on final
deployment-time verification of the exact Base feed contracts and parameters.
Future assets must pass the same admission policy before a Timelock proposal is
scheduled.

## 11. Oracle Failure Behavior

If a required token becomes unsafe:

- swaps involving it stop;
- deposits of it stop;
- single-token withdrawals into it stop;
- operations whose NAV calculation requires its unsafe price stop;
- proportional withdrawal remains available.

The last valid price may be retained for display and alert context but must not
authorize a new oracle-priced value transfer. Recovery requires healthy sources
and, after a Pool-level pause, a Timelock-controlled unpause. There is no
automatic unpause.

## 12. Monitoring and Incident Response

Monitoring uses an independent third external reference for alerts only. It does
not set the on-chain execution price.

Required signals include:

- Chainlink and Pyth freshness;
- Pyth confidence;
- primary/secondary and third-reference divergence;
- reserve health and floor proximity;
- token and total TVL caps;
- failed oracle reads and rejected transactions;
- Pool, token, and governance pause state;
- Timelock proposals and executions.

Critical alerts notify defined 24/7 responders. The Pause Guardian may pause
immediately. Unpause and risk-parameter changes require normal governance. A
value-bearing deployment is not opened until alert delivery, responder
ownership, runbooks, and a live pause drill have been verified.

## 13. Base Rollout

1. Deploy and test the complete stack on Base Sepolia.
2. Run oracle failure, divergence, stale-price, confidence, reserve-floor,
   marginal-fee, and emergency-exit drills.
3. Complete security review and freeze the production Pool bytecode.
4. Deploy fresh production governance, Registry, adapters, and immutable Pool on
   Base mainnet.
5. Admit USDC, EURC, and USDT with low token-level and total TVL caps.
6. Verify monitoring and execute a mainnet pause drill before public deposits.
7. Increase caps only through 48-hour Timelock proposals and only after observed
   stable operation.

Arc is described publicly as a planned deployment, not a dated commitment. It
must pass the same oracle, monitoring, governance, security, and rollout gates.

## 14. Testing and Invariants

Contract tests must cover:

- exact fee results inside each band and across every boundary;
- equivalence of one large transaction and split transactions within rounding
  tolerance;
- swaps and withdrawals stopping exactly at the protected floor;
- `maxSwapOut` and `maxWithdraw` never overstating executable amounts;
- quote/execution parity;
- fee-on-transfer input accounting;
- protocol-fee and reserve balance conservation;
- oracle stale, confidence, divergence, revert, and malformed-data cases;
- fail-closed behavior when only one oracle source survives;
- proportional withdrawal during oracle failure and pause;
- governance authorization and 48-hour delay;
- Registry additions without changing Pool code.

Stateful invariants must include:

```text
tokenBalance >= reserves[token] + protocolFeesAccrued[token]
oraclePricedOperation => postReserveUsd >= minimumReserveUsd
singleSourceOracle => no oraclePricedOperation
proportionalExit preserves equal basket treatment
fee(split execution) ~= fee(single execution)
```

SDK and application tests cover safe maximums, stale quote refresh, disabled
submission above maximum, `Max` behavior, dynamic fee presentation, network
selection, and proportional emergency exit.

## 15. Acceptance Criteria

Base mainnet may accept public value only when:

- all approved tests and invariants pass;
- USDC, EURC, and USDT each have two verified independent direct sources;
- external security review covers the frozen Pool, Registry, adapters, and
  governance deployment path;
- production Safe and Timelock ownership is verified on-chain;
- alert delivery and pause drills succeed;
- proportional emergency withdrawal is independently tested;
- initial caps and reserve parameters are documented and queued through
  governance;
- application and SDK use the production chain-address map with no Arc-testnet
  hardcoding in the Base flow.
