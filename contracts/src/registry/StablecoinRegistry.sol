// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable }       from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }  from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IStablecoinRegistry }  from "./IStablecoinRegistry.sol";
import { IChainlinkAggregator } from "../interfaces/IChainlinkAggregator.sol";

/// @title StablecoinRegistry
/// @notice Per-token metadata + USD oracle catalogue for the shared-vault StablePool.
contract StablecoinRegistry is IStablecoinRegistry, Ownable2Step {
    mapping(address token => TokenInfo) internal _info;
    address[] public override tokens;

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ── External views ────────────────────────────────────────────────

    function tokenInfo(address token) external view override returns (TokenInfo memory) {
        return _info[token];
    }

    function isActive(address token) external view override returns (bool) {
        return _info[token].isActive;
    }

    function tokensLength() external view override returns (uint256) {
        return tokens.length;
    }

    // ── Mutations (owner-only) ────────────────────────────────────────

    function listToken(
        address token,
        uint8 decimals_,
        IChainlinkAggregator oracle,
        uint16 maxDeviationBps
    ) external override onlyOwner {
        if (token == address(0) || address(oracle) == address(0)) revert ZeroAddress();
        if (decimals_ == 0 || decimals_ > 18) revert InvalidDecimals(decimals_);
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

    function setOracle(address token, IChainlinkAggregator oracle) external override onlyOwner {
        if (address(oracle) == address(0)) revert ZeroAddress();
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        address oldOracle = address(info.usdOracle);
        info.usdOracle = oracle;
        emit OracleUpdated(token, oldOracle, address(oracle));
    }

    function setDeviation(address token, uint16 maxDeviationBps) external override onlyOwner {
        if (maxDeviationBps == 0 || maxDeviationBps > 10_000) revert InvalidDeviation(maxDeviationBps);
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        uint16 old = info.maxOracleDeviationBps;
        info.maxOracleDeviationBps = maxDeviationBps;
        emit DeviationUpdated(token, old, maxDeviationBps);
    }
}
