// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IOracleAdapterV2
/// @notice The single oracle abstraction ArcoraDexPoolV2 consumes. The Pool never
/// reads a raw feed: it receives only a 1e18-scaled USD price and a binary `safe`
/// flag. The ADAPTER alone decides safety per spec §10/§11 — a token is `safe`
/// only when BOTH independent direct token/USD sources are fresh, valid, within
/// confidence, and within divergence. A single surviving source, a stale read, an
/// invalid read, or excess divergence MUST yield `safe == false`. When unsafe the
/// adapter MAY still return a non-zero last-known `price1e18` for display/alert
/// context, but the Pool MUST NOT authorize an oracle-priced transfer on it.
interface IOracleAdapterV2 {
    /// @notice Stateful price read (real adapters may refresh an internal cache).
    /// @return price1e18 1e18-scaled USD price (last-known if unsafe; may be 0 if never seeded).
    /// @return safe True only when the token is safe for an oracle-priced operation.
    function readPrice(address token) external returns (uint256 price1e18, bool safe);

    /// @notice View-only equivalent used by quotes and views. MUST be consistent
    /// with `readPrice` for the same state (no side effects).
    function peekPrice(address token) external view returns (uint256 price1e18, bool safe);
}
