// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable }       from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }  from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IChainlinkAggregator } from "../interfaces/IChainlinkAggregator.sol";

/// @title OracleAggregator
/// @notice 2-source `IChainlinkAggregator` wrapper. Returns the average of the
/// two sources when they agree within `maxDivergenceBps`; reverts if they
/// diverge beyond that; falls back to a single source when the other reverts.
contract OracleAggregator is IChainlinkAggregator, Ownable2Step {
    IChainlinkAggregator public immutable PRIMARY;
    IChainlinkAggregator public immutable SECONDARY;
    uint8                public immutable DECIMALS_;
    uint16               public maxDivergenceBps;

    error SourcesDiverge(uint256 primary, uint256 secondary, uint16 capBps);
    error AllSourcesUnavailable();
    error DecimalsMismatch(uint8 primaryDec, uint8 secondaryDec);
    error InvalidDivergenceBps(uint16 bps);

    event MaxDivergenceUpdated(uint16 oldValue, uint16 newValue);

    constructor(
        IChainlinkAggregator primary_,
        IChainlinkAggregator secondary_,
        uint16 initialMaxDivergenceBps,
        address initialOwner
    ) Ownable(initialOwner) {
        if (initialMaxDivergenceBps == 0 || initialMaxDivergenceBps > 10_000) {
            revert InvalidDivergenceBps(initialMaxDivergenceBps);
        }
        uint8 pDec = primary_.decimals();
        uint8 sDec = secondary_.decimals();
        if (pDec != sDec) revert DecimalsMismatch(pDec, sDec);
        PRIMARY = primary_;
        SECONDARY = secondary_;
        DECIMALS_ = pDec;
        maxDivergenceBps = initialMaxDivergenceBps;
    }

    function decimals() external view override returns (uint8) {
        return DECIMALS_;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (bool pOk, int256 pAns, uint256 pAt) = _tryRead(PRIMARY);
        (bool sOk, int256 sAns, uint256 sAt) = _tryRead(SECONDARY);

        if (!pOk && !sOk) revert AllSourcesUnavailable();

        if (pOk && !sOk) return (1, pAns, pAt, pAt, 1);
        if (sOk && !pOk) return (1, sAns, sAt, sAt, 1);

        // Both succeeded — divergence check.
        uint256 absDiff = pAns > sAns ? uint256(pAns - sAns) : uint256(sAns - pAns);
        uint256 minAns  = pAns < sAns ? uint256(pAns) : uint256(sAns);
        if (absDiff * 10_000 > minAns * uint256(maxDivergenceBps)) {
            revert SourcesDiverge(uint256(pAns), uint256(sAns), maxDivergenceBps);
        }

        int256  mid    = (pAns + sAns) / 2;
        uint256 latest = pAt > sAt ? pAt : sAt;
        return (1, mid, latest, latest, 1);
    }

    function setMaxDivergenceBps(uint16 newBps) external onlyOwner {
        if (newBps == 0 || newBps > 10_000) revert InvalidDivergenceBps(newBps);
        emit MaxDivergenceUpdated(maxDivergenceBps, newBps);
        maxDivergenceBps = newBps;
    }

    /// @dev Returns (success, answer, updatedAt). Catches revert from source.
    /// Treats answer <= 0 as failure (Chainlink convention).
    function _tryRead(IChainlinkAggregator src)
        private
        view
        returns (bool ok, int256 answer, uint256 updatedAt)
    {
        try src.latestRoundData() returns (uint80, int256 a, uint256, uint256 u, uint80) {
            if (a > 0 && u > 0) {
                return (true, a, u);
            }
            return (false, 0, 0);
        } catch {
            return (false, 0, 0);
        }
    }
}
