// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IPythV2
/// @notice Vendored MINIMAL Pyth interface — only the surface ChainlinkPythAdapterV2
/// needs. ABI-compatible (selectors + struct layout) with the live Pyth contract on
/// Base. Vendored, not imported from pythnetwork/pyth-sdk-solidity, to match the repo's
/// hand-written IChainlinkAggregator convention and avoid an external lib / solc-drift.
/// @dev On Base mainnet target the UPGRADED (2026-07-31) Pyth Core contract
/// 0xbC16aee60f64864882BC6C4E428e148Fc0E272F5; Sepolia 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83.
interface IPythV2 {
    /// @notice Pyth's price record. `price` and `conf` are scaled by 10**expo (expo is
    /// typically negative, e.g. expo = -8 means price/conf are in 1e-8 units).
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    /// @notice Latest price for `id` WITHOUT a freshness revert. The caller checks
    /// `publishTime` staleness itself. This is the read used by readPrice/peekPrice so
    /// that neither function reverts on a stale feed (fail-closed is signalled via `safe`,
    /// not a revert) and so both share identical control flow (O6 peek==read).
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);

    /// @notice Fee (in wei) required to apply `updateData` via updatePriceFeeds.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    /// @notice Apply pulled Hermes update blobs. PAYABLE. Called ONLY from the adapter's
    /// keeper-facing updatePyth path, NEVER from readPrice/peekPrice.
    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    /// @notice Pyth's own notion of a valid staleness window (seconds); used only as a
    /// sanity reference in tests, not as the adapter's authoritative bound.
    function getValidTimePeriod() external view returns (uint256 validTimePeriod);
}
