// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable }            from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }       from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20Metadata }     from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IArcoraDexRegistry } from "./interfaces/IArcoraDexRegistry.sol";
import { IChainlinkAggregator } from "./interfaces/IChainlinkAggregator.sol";

/// @title ArcoraDexRegistry
/// @notice Per-token catalogue: decimals, USD oracle, deviation cap, active flag.
contract ArcoraDexRegistry is IArcoraDexRegistry, Ownable2Step {
    mapping(address token => TokenInfo) internal _info;
    address[] public override tokens;

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ── Views ──────────────────────────────────────────────────────
    function tokenInfo(address token) external view override returns (TokenInfo memory) {
        return _info[token];
    }

    function isActive(address token) external view override returns (bool) {
        return _info[token].isActive;
    }

    function tokensLength() external view override returns (uint256) {
        return tokens.length;
    }

    // ── Mutators (owner-only) ─────────────────────────────────────
    function listToken(
        address token,
        uint8 decimals_,
        IChainlinkAggregator oracle,
        uint16 maxDeviationBps
    ) external override onlyOwner {
        if (token == address(0) || address(oracle) == address(0)) revert ZeroAddress();
        if (decimals_ == 0 || decimals_ > 18) revert InvalidDecimals(decimals_);
        uint8 actualDecimals = IERC20Metadata(token).decimals();
        if (decimals_ != actualDecimals) revert TokenDecimalMismatch(token, decimals_, actualDecimals);
        if (maxDeviationBps == 0 || maxDeviationBps > 10_000) revert InvalidDeviation(maxDeviationBps);
        if (_info[token].usdOracle != IChainlinkAggregator(address(0))) revert TokenAlreadyListed(token);

        _info[token] = TokenInfo({
            decimals: decimals_,
            isActive: true,
            usdOracle: oracle,
            maxOracleDeviationBps: maxDeviationBps
        });
        tokens.push(token);
        emit TokenListed(token, decimals_, address(oracle), maxDeviationBps);
    }

    function setOracle(address token, IChainlinkAggregator newOracle) external override onlyOwner {
        if (address(newOracle) == address(0)) revert ZeroAddress();
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        address oldOracle = address(info.usdOracle);
        info.usdOracle = newOracle;
        emit OracleUpdated(token, oldOracle, address(newOracle));
    }

    function setDeviation(address token, uint16 maxDeviationBps) external override onlyOwner {
        if (maxDeviationBps == 0 || maxDeviationBps > 10_000) revert InvalidDeviation(maxDeviationBps);
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        uint16 old = info.maxOracleDeviationBps;
        info.maxOracleDeviationBps = maxDeviationBps;
        emit DeviationUpdated(token, old, maxDeviationBps);
    }

    function deactivateToken(address token) external override onlyOwner {
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        info.isActive = false;
        emit TokenDeactivated(token);
    }

    function reactivateToken(address token) external override onlyOwner {
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        info.isActive = true;
        emit TokenReactivated(token);
    }
}
