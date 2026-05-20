// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";

/// @title OracleAggregator
/// @notice 2-source `IChainlinkAggregator` wrapper. Returns the average of the
/// two sources when they agree within `maxDivergenceBps`; reverts if they
/// diverge beyond that; falls back to a single source when the other reverts
/// or is stale.
///
/// @dev Security trade-off — degraded mode:
/// When one source is down (reverts, returns bad data, or is stale) the
/// aggregator returns the surviving source's price WITHOUT a divergence
/// cross-check, and signals this by returning `roundId = 0`. Consumers
/// (e.g. the Pool's _readOracle) treat `roundId == 0` as not-fresh and fall
/// back to their lastValidPrice cache rather than accepting the degraded read.
/// Operators MUST monitor `sourceHealth()` (and, in P3, the
/// CumulativeDeviationGuard events) to detect when the aggregator has entered
/// single-source mode and the divergence check is inactive.
contract OracleAggregator is IChainlinkAggregator, Ownable2Step {
    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    IChainlinkAggregator public immutable PRIMARY;
    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    IChainlinkAggregator public immutable SECONDARY;
    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    uint8 public immutable DECIMALS; // M4: removed trailing underscore
    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    uint32 public immutable MAX_STALE_SECONDS;
    uint16 public maxDivergenceBps;

    error SourcesDiverge(uint256 primary, uint256 secondary, uint16 capBps);
    error AllSourcesUnavailable();
    error DecimalsMismatch(uint8 primaryDec, uint8 secondaryDec);
    error InvalidDivergenceBps(uint16 bps);
    error InvalidStaleSeconds(uint32 v);

    event MaxDivergenceUpdated(uint16 oldValue, uint16 newValue);

    constructor(
        IChainlinkAggregator primary_,
        IChainlinkAggregator secondary_,
        uint16 initialMaxDivergenceBps,
        uint32 maxStaleSeconds_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (initialMaxDivergenceBps == 0 || initialMaxDivergenceBps > 10_000) {
            revert InvalidDivergenceBps(initialMaxDivergenceBps);
        }
        if (maxStaleSeconds_ == 0) revert InvalidStaleSeconds(maxStaleSeconds_);
        uint8 pDec = primary_.decimals();
        uint8 sDec = secondary_.decimals();
        if (pDec != sDec) revert DecimalsMismatch(pDec, sDec);
        PRIMARY = primary_;
        SECONDARY = secondary_;
        DECIMALS = pDec; // M4: renamed from DECIMALS_
        MAX_STALE_SECONDS = maxStaleSeconds_;
        maxDivergenceBps = initialMaxDivergenceBps;
    }

    function decimals() external view override returns (uint8) {
        return DECIMALS; // M4: renamed from DECIMALS_
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        (bool pOk, int256 pAns, uint256 pAt, uint80 pR) = _tryRead(PRIMARY);
        (bool sOk, int256 sAns, uint256 sAt, uint80 sR) = _tryRead(SECONDARY);

        if (!pOk && !sOk) revert AllSourcesUnavailable();

        // Single-source mode: signal degraded operation to consumers via
        // roundId = 0 (the Pool's _readOracle treats roundId == 0 as not-fresh
        // and falls back to its lastValidPrice cache).
        if (pOk && !sOk) return (0, pAns, pAt, pAt, 0);
        if (sOk && !pOk) return (0, sAns, sAt, sAt, 0);

        // Both sources healthy — delegate to helper to avoid stack-too-deep.
        return _combineSources(pAns, pAt, pR, sAns, sAt, sR);
    }

    /// @dev Called only when both sources are healthy. Checks divergence and
    ///      returns the mid-price, staler timestamp, and max roundId.
    function _combineSources(
        int256 pAns,
        uint256 pAt,
        uint80 pR,
        int256 sAns,
        uint256 sAt,
        uint80 sR
    ) private view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 absDiff = pAns > sAns ? uint256(pAns - sAns) : uint256(sAns - pAns);
        uint256 minAns = pAns < sAns ? uint256(pAns) : uint256(sAns);
        if (absDiff * 10_000 > minAns * uint256(maxDivergenceBps)) {
            revert SourcesDiverge(uint256(pAns), uint256(sAns), maxDivergenceBps);
        }

        int256 mid = (pAns + sAns) / 2; // sum of two positive feed answers cannot realistically overflow int256 (M5)
        // Return the STALER timestamp so the Pool's MAX_STALE_SECONDS check still
        // catches the staler source (audit C-2).
        uint256 olderAt = pAt < sAt ? pAt : sAt;
        // Return a real, monotonic-source-derived roundId so the Pool's
        // roundOk staleness check is meaningful (audit C-5).
        uint80 roundId = pR > sR ? pR : sR;
        return (roundId, mid, olderAt, olderAt, roundId);
    }

    /// @notice Monitoring hook: reports per-source liveness so off-chain
    /// keepers can detect when the aggregator is running in degraded
    /// (single-source) mode — i.e. the divergence cross-check is inactive.
    function sourceHealth() external view returns (bool primaryOk, bool secondaryOk) {
        (primaryOk,,,) = _tryRead(PRIMARY);
        (secondaryOk,,,) = _tryRead(SECONDARY);
    }

    function setMaxDivergenceBps(uint16 newBps) external onlyOwner {
        if (newBps == 0 || newBps > 10_000) revert InvalidDivergenceBps(newBps);
        emit MaxDivergenceUpdated(maxDivergenceBps, newBps);
        maxDivergenceBps = newBps;
    }

    /// @dev Returns (success, answer, updatedAt, roundId). Catches revert from source.
    /// Validates: positive answer, positive timestamp, round completeness
    /// (roundId != 0 and answeredInRound >= roundId), and per-source staleness
    /// (block.timestamp <= updatedAt + MAX_STALE_SECONDS). A stale or incomplete
    /// round is treated as a failed read.
    function _tryRead(IChainlinkAggregator src)
        private
        view
        returns (bool ok, int256 answer, uint256 updatedAt, uint80 roundId_)
    {
        // Justification [unused-return]: latestRoundData's 5-tuple is fully destructured; only startedAt (3rd field) is discarded as per Chainlink integration best practice — it carries no useful staleness information.
        // slither-disable-next-line unused-return
        try src.latestRoundData() returns (uint80 r, int256 a, uint256, uint256 u, uint80 air) {
            if (a > 0 && u > 0 && r != 0 && air >= r && block.timestamp <= u + MAX_STALE_SECONDS) {
                return (true, a, u, r);
            }
            return (false, 0, 0, 0);
        } catch {
            return (false, 0, 0, 0);
        }
    }
}
