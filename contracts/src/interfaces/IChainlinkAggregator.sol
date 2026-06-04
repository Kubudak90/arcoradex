// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IChainlinkAggregator {
    /// @notice Chainlink-shaped latest-round accessor.
    /// @dev `roundId == 0` degraded-mode convention (I-4): a genuine Chainlink
    /// feed never reports `roundId == 0`, so `OracleAggregator` overloads that
    /// value as an explicit "single-source / degraded" signal — it returns
    /// `roundId = answeredInRound = 0` when only one of its two sources is alive
    /// (the surviving price is returned WITHOUT a divergence cross-check). The
    /// Pool's `_readOracle` computes `roundOk = roundId != 0 && answeredInRound
    /// >= roundId`, so a `roundId == 0` read is treated as NOT-fresh and the Pool
    /// falls back to its `lastValidPrice` cache rather than accepting the
    /// un-cross-checked degraded reading. Consumers that integrate this interface
    /// directly MUST apply the same `roundId != 0` check.
    /// @return roundId The round id, or 0 to signal degraded single-source mode.
    /// @return answer The price answer (feed-native decimals).
    /// @return startedAt Round start timestamp.
    /// @return updatedAt Answer timestamp (used for staleness).
    /// @return answeredInRound The round in which the answer was computed (0 in
    /// degraded mode).
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}
