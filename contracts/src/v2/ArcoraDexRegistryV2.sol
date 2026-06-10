// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IArcoraDexRegistryV2} from "./interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "./interfaces/IOracleAdapterV2.sol";
import {FeeBandMathV2} from "./lib/FeeBandMathV2.sol";

interface IPoolReservesV2 {
    function reserves(address token) external view returns (uint256);
}

/// @title ArcoraDexRegistryV2
/// @notice Governance-configurable per-token admission for the immutable Pool (§6.2).
contract ArcoraDexRegistryV2 is IArcoraDexRegistryV2, Ownable2Step {
    uint256 public constant override MAX_TOKENS = 32;
    uint16 public constant override MAX_FEE_BPS = 1_000; // 10% protocol maximum per band
    uint16 public constant override MAX_PROTOCOL_FEE_SHARE_BPS = 2_500;
    uint256 internal constant BPS = 10_000;

    mapping(address token => TokenConfigV2) internal _config;
    address[] public override tokens;
    address public override pool;

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ── Views ──────────────────────────────────────────────────────
    function tokenConfig(address token) external view override returns (TokenConfigV2 memory) {
        return _config[token];
    }

    function isActive(address token) external view override returns (bool) {
        return _config[token].isActive;
    }

    function tokensLength() external view override returns (uint256) {
        return tokens.length;
    }

    // ── §6.2 validation ────────────────────────────────────────────
    function _validate(address token, TokenConfigV2 calldata c) internal view {
        if (token == address(0) || address(c.adapter) == address(0)) revert ZeroAddress();
        if (c.decimals == 0 || c.decimals > 18) revert InvalidDecimals(c.decimals);
        uint8 actual = IERC20Metadata(token).decimals();
        if (c.decimals != actual) revert TokenDecimalMismatch(token, c.decimals, actual);
        // O1: a zero floor would let priced ops drain a reserve fully — require a non-zero
        // protected floor strictly below the target.
        if (c.minimumReserveUsd == 0 || c.targetReserveUsd <= c.minimumReserveUsd) {
            revert InvalidReserveBounds(token);
        }
        uint256 n = c.bands.length;
        if (n == 0) revert InvalidBands(token);
        // First band must start at 100% health.
        if (c.bands[0].upperHealthBps != BPS) revert InvalidBands(token);
        for (uint256 i; i < n; ++i) {
            if (c.bands[i].rateBps > MAX_FEE_BPS) revert InvalidBands(token);
            if (i + 1 < n) {
                // Strictly descending health bounds (ordered + contiguous: each band's
                // lower bound is the next band's upper bound; the last band's lower is 0).
                if (c.bands[i + 1].upperHealthBps >= c.bands[i].upperHealthBps) revert InvalidBands(token);
                // Rate must NOT decrease as health falls.
                if (c.bands[i + 1].rateBps < c.bands[i].rateBps) revert InvalidBands(token);
            }
        }
    }

    // ── Mutators (owner-only) ─────────────────────────────────────
    function listToken(address token, TokenConfigV2 calldata config) external override onlyOwner {
        if (address(_config[token].adapter) != address(0)) revert TokenAlreadyListed(token);
        if (tokens.length >= MAX_TOKENS) revert MaxTokensReached();
        _validate(token, config);
        _config[token] = config;
        tokens.push(token);
        emit TokenListed(token, address(config.adapter), config.minimumReserveUsd, config.targetReserveUsd);
    }

    function setTokenConfig(address token, TokenConfigV2 calldata config) external override onlyOwner {
        if (address(_config[token].adapter) == address(0)) revert TokenNotListed(token);
        _validate(token, config);
        _config[token] = config;
        emit TokenConfigUpdated(token);
    }

    function setAdapter(address token, IOracleAdapterV2 newAdapter) external override onlyOwner {
        if (address(newAdapter) == address(0)) revert ZeroAddress();
        TokenConfigV2 storage info = _config[token];
        if (address(info.adapter) == address(0)) revert TokenNotListed(token);
        address old = address(info.adapter);
        info.adapter = newAdapter;
        emit AdapterUpdated(token, old, address(newAdapter));
    }

    /// @dev O2: forbid un-wiring the pool so the I-1 deactivate-with-reserves guard cannot be
    /// silently bypassed. The initial zero state (before any setPool) remains valid.
    function setPool(address pool_) external override onlyOwner {
        if (pool_ == address(0)) revert ZeroAddress();
        pool = pool_;
        emit PoolSet(pool_);
    }

    /// @dev I-1: cannot deactivate while the wired Pool still holds reserves.
    function deactivateToken(address token) external override onlyOwner {
        TokenConfigV2 storage info = _config[token];
        if (address(info.adapter) == address(0)) revert TokenNotListed(token);
        if (pool != address(0) && IPoolReservesV2(pool).reserves(token) != 0) revert TokenHasReserves(token);
        info.isActive = false;
        emit TokenDeactivated(token);
    }

    function reactivateToken(address token) external override onlyOwner {
        TokenConfigV2 storage info = _config[token];
        if (address(info.adapter) == address(0)) revert TokenNotListed(token);
        info.isActive = true;
        emit TokenReactivated(token);
    }

    function removeToken(address token) external override onlyOwner {
        TokenConfigV2 storage info = _config[token];
        if (address(info.adapter) == address(0)) revert TokenNotListed(token);
        if (info.isActive) revert TokenStillActive(token);
        uint256 n = tokens.length;
        for (uint256 i; i < n; ++i) {
            if (tokens[i] == token) {
                tokens[i] = tokens[n - 1];
                tokens.pop();
                break;
            }
        }
        delete _config[token];
        emit TokenRemoved(token);
    }
}
