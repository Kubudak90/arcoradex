// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IArcoraDexRegistry} from "./interfaces/IArcoraDexRegistry.sol";
import {IChainlinkAggregator} from "./interfaces/IChainlinkAggregator.sol";

/// @dev Minimal local view of the Pool used solely for the I-1 reserve guard in
/// `deactivateToken`. Declared locally (rather than importing the full
/// `IArcoraDexPool`) to avoid an interface-import cycle: `IArcoraDexPool` already
/// references `IArcoraDexRegistry`.
interface IPoolReserves {
    function reserves(address token) external view returns (uint256);
}

/// @title ArcoraDexRegistry
/// @notice Per-token catalogue: decimals, USD oracle, deviation cap, active flag.
contract ArcoraDexRegistry is IArcoraDexRegistry, Ownable2Step {
    /// @notice Upper bound on the number of listed tokens. Bounds the Pool's NAV
    /// loop (which iterates every listed token) so its cost cannot grow without
    /// limit. Combined with `removeToken`, deactivation can reclaim iteration cost.
    uint256 public constant override MAX_TOKENS = 32;

    mapping(address token => TokenInfo) internal _info;
    address[] public override tokens;

    /// @notice The Pool whose reserves the registry consults for the I-1 guard in
    /// `deactivateToken`. When unset (`address(0)`) the guard is skipped, preserving
    /// back-compat for bare registries and deploys that never wire a pool.
    /// Production MUST call `setPool(pool)` so deactivation cannot strand reserves.
    address public override pool;

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
        uint16 maxDeviationBps,
        uint32 maxStaleSeconds_
    ) external override onlyOwner {
        if (token == address(0) || address(oracle) == address(0)) revert ZeroAddress();
        if (decimals_ == 0 || decimals_ > 18) revert InvalidDecimals(decimals_);
        uint8 actualDecimals = IERC20Metadata(token).decimals();
        if (decimals_ != actualDecimals) revert TokenDecimalMismatch(token, decimals_, actualDecimals);
        if (maxDeviationBps == 0 || maxDeviationBps > 10_000) revert InvalidDeviation(maxDeviationBps);
        if (maxStaleSeconds_ < 60 || maxStaleSeconds_ > 7 days) revert InvalidStaleSeconds(maxStaleSeconds_);
        if (_info[token].usdOracle != IChainlinkAggregator(address(0))) revert TokenAlreadyListed(token);
        if (tokens.length >= MAX_TOKENS) revert MaxTokensReached();

        _info[token] = TokenInfo({
            decimals: decimals_,
            isActive: true,
            usdOracle: oracle,
            maxOracleDeviationBps: maxDeviationBps,
            maxStaleSeconds: maxStaleSeconds_
        });
        tokens.push(token);
        emit TokenListed(token, decimals_, address(oracle), maxDeviationBps, maxStaleSeconds_);
    }

    /// @notice Repoint `token`'s USD price feed to `newOracle`. Owner-only.
    /// @dev Security: this is an INSTANT feed repoint — there is no timelock or
    /// staging here, and the Pool reads `info.usdOracle` (and, on it,
    /// `oracle.decimals()` + `latestRoundData()`) afresh on the very next priced
    /// op. A wrong or malicious feed therefore takes effect immediately, so this
    /// must only be driven by the governance owner (the Timelock in production).
    /// I-7 defense-in-depth: reject a feed reporting > 18 decimals — the Pool
    /// scales answers to 1e18 by `oracle.decimals()`, so a feed outside the
    /// supported `[1, 18]` domain would mis-scale every price.
    function setOracle(address token, IChainlinkAggregator newOracle) external override onlyOwner {
        if (address(newOracle) == address(0)) revert ZeroAddress();
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        uint8 newDecimals = newOracle.decimals();
        if (newDecimals > 18) revert OracleDecimalsTooHigh(newDecimals);
        address oldOracle = address(info.usdOracle);
        info.usdOracle = newOracle;
        emit OracleUpdated(token, oldOracle, address(newOracle));
    }

    /// @notice Update `token`'s per-read oracle deviation cap (bps). Owner-only.
    /// @dev Security: the cap bounds how far a fresh oracle reading may move from
    /// the Pool's `lastAcceptedPrice` baseline before the priced op reverts
    /// `PriceDeviation` and falls back to cache. Loosening it (toward 10_000)
    /// widens the band an attacker-controlled or glitching feed can move within
    /// in a single update; tightening it (toward 1) makes the Pool more prone to
    /// reverting on legitimate volatility. Bounded to `[1, 10_000]`.
    function setDeviation(address token, uint16 maxDeviationBps) external override onlyOwner {
        if (maxDeviationBps == 0 || maxDeviationBps > 10_000) revert InvalidDeviation(maxDeviationBps);
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        uint16 old = info.maxOracleDeviationBps;
        info.maxOracleDeviationBps = maxDeviationBps;
        emit DeviationUpdated(token, old, maxDeviationBps);
    }

    /// @notice Update `token`'s per-read oracle staleness window (seconds).
    /// Owner-only.
    /// @dev Security: the Pool treats an oracle answer older than
    /// `block.timestamp - maxStaleSeconds` as not-fresh and falls back to its
    /// `lastValidPrice` cache. Raising this lets the Pool accept older live
    /// readings (more tolerant of feed lag, but more exposed to stale prices);
    /// lowering it forces cache fallback sooner. Bounded to `[60s, 7 days]`.
    function setMaxStaleSeconds(address token, uint32 maxStaleSeconds_) external override onlyOwner {
        if (maxStaleSeconds_ < 60 || maxStaleSeconds_ > 7 days) revert InvalidStaleSeconds(maxStaleSeconds_);
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        uint32 old = info.maxStaleSeconds;
        info.maxStaleSeconds = maxStaleSeconds_;
        emit MaxStaleSecondsUpdated(token, old, maxStaleSeconds_);
    }

    /// @notice Wire (or rewire) the Pool the registry consults for the I-1
    /// reserve guard in `deactivateToken`.
    /// @dev The registry is not the Pool's owner and cannot drive it; it only
    /// *reads* `reserves(token)`. A zero address disables the guard (back-compat).
    /// Production deployments MUST call this with the live Pool so a token cannot
    /// be deactivated while the Pool still holds its reserves (which would silently
    /// drop those reserves out of NAV — see `IArcoraDexRegistry.TokenHasReserves`).
    function setPool(address pool_) external override onlyOwner {
        pool = pool_;
        emit PoolSet(pool_);
    }

    /// @dev I-1: deactivating a token whose Pool reserves are non-zero would drop
    /// those reserves out of NAV (the NAV loop skips inactive tokens), transferring
    /// value between LP cohorts and stranding the reserves. When a Pool is wired,
    /// require its reserves for the token to be drained to zero first. When no Pool
    /// is wired (`pool == address(0)`) the guard is skipped (back-compat).
    function deactivateToken(address token) external override onlyOwner {
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        if (pool != address(0) && IPoolReserves(pool).reserves(token) != 0) revert TokenHasReserves(token);
        info.isActive = false;
        emit TokenDeactivated(token);
    }

    /// @notice Re-activate a previously deactivated token.
    /// @dev STALE-CACHE WARNING (I-2): reactivation does NOT touch the Pool's price
    /// caches (`lastAcceptedPrice` / `lastValidPrice` / `lastValidPriceAt`). A token
    /// that was inactive for a while (or is being re-listed after a prior
    /// `removeToken`) may carry an ancient cached price that the Pool would trade
    /// against until the keeper pushes a fresh oracle reading. Governance MUST call
    /// `Pool.resetPriceCache(token)` in the SAME Timelock batch as this call (and
    /// likewise after re-listing a previously-removed token) so the next priced op
    /// takes the fresh-oracle path instead of the stale cache.
    function reactivateToken(address token) external override onlyOwner {
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        info.isActive = true;
        emit TokenReactivated(token);
    }

    /// @notice Permanently removes a token from the registry, reclaiming the
    /// Pool's NAV-loop iteration cost for it.
    /// @dev The caller MUST deactivate the token first (this reverts on an active
    /// token). The I-1 guard ensures deactivation requires the Pool's reserves to
    /// be drained to zero, so `!isActive ⇒ reserves == 0` by procedure — the
    /// registry has no Pool reference and so cannot check reserves itself.
    /// Uses swap-pop on `tokens[]`; this reorders the array, which is safe because
    /// the NAV loop is an order-independent sum over all listed tokens.
    function removeToken(address token) external override onlyOwner {
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        if (info.isActive) revert TokenStillActive(token);

        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; i++) {
            if (tokens[i] == token) {
                tokens[i] = tokens[n - 1];
                tokens.pop();
                break;
            }
        }
        delete _info[token];
        emit TokenRemoved(token);
    }
}
