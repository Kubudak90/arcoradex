// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IOracleAdapterV2} from "./interfaces/IOracleAdapterV2.sol";
import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";
import {IPythV2} from "./interfaces/IPythV2.sol";

/// @title ChainlinkPythAdapterV2
/// @notice Per-token IOracleAdapterV2: dual-source (Chainlink primary + Pyth secondary)
/// token/USD oracle normalized to 1e18. The ADAPTER alone decides `safe` per spec
/// §10/§11 — both legs must be fresh, valid, within Pyth confidence, and within
/// cross-source divergence; a single surviving leg, a stale/invalid/malformed read, or
/// excess divergence ⇒ `safe == false` (fail-closed). `peekPrice` and `readPrice` return
/// the SAME tuple for a given block (O6): both delegate to a pure-of-state `_compute`,
/// and `readPrice`'s only side effect is updating a display cache — it never pulls Pyth.
/// Pyth pull-updates are isolated in `updatePyth` (keeper path), never reached by reads.
contract ChainlinkPythAdapterV2 is IOracleAdapterV2, Ownable2Step {
    uint256 internal constant BPS = 10_000;

    /// @dev Fail-closed normalized-price ceiling (review findings 1 & 2). Any leg whose
    /// 1e18-normalized price exceeds this is treated as INVALID (leg ⇒ unsafe), never a
    /// revert. The bound is deliberately astronomical ($1e18) so no real asset trips it,
    /// yet it caps `_compute`'s arithmetic: with both legs ≤ 1e36,
    /// `diff * BPS ≤ 1e36 * 1e4 = 1e40` and `cl1e18 + py1e18 ≤ 2e36` both stay well below
    /// uint256.max (~1.16e77) — so the divergence/mid math can never overflow. Each leg
    /// reader applies this in overflow-proof order (compare BEFORE multiplying) so the
    /// read/peek fail-closed invariant holds: they never revert except WrongToken.
    uint256 internal constant MAX_PRICE_1E18 = 1e36;

    // ── Immutable wiring ────────────────────────────────────────────────
    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    address public immutable TOKEN;
    // slither-disable-next-line naming-convention
    IChainlinkAggregator public immutable CHAINLINK_FEED;
    // slither-disable-next-line naming-convention
    IPythV2 public immutable PYTH;
    // slither-disable-next-line naming-convention
    bytes32 public immutable PYTH_PRICE_ID;
    // slither-disable-next-line naming-convention
    uint8 public immutable CHAINLINK_DECIMALS;

    // ── Tunable safety params (owner = Timelock) ────────────────────────
    uint32 public chainlinkMaxStaleSeconds;
    uint32 public pythMaxStaleSeconds;
    uint16 public pythMaxConfBps;
    uint16 public maxDivergenceBps;

    // ── §11 display cache (NEVER authorizes a transfer) ─────────────────
    uint256 public lastSafePrice1e18;
    uint256 public lastSafeAt;

    // ── Errors ──────────────────────────────────────────────────────────
    error ZeroAddress();
    error WrongToken(address requested, address expected);
    error ChainlinkDecimalsTooLarge(uint8 decimals);
    error InvalidStaleSeconds(uint32 v);
    error InvalidConfBps(uint16 v);
    error InvalidDivergenceBps(uint16 v);
    error InsufficientUpdateFee(uint256 sent, uint256 required);
    error RefundFailed();

    // ── Events ──────────────────────────────────────────────────────────
    event ChainlinkMaxStaleUpdated(uint32 oldValue, uint32 newValue);
    event PythMaxStaleUpdated(uint32 oldValue, uint32 newValue);
    event PythMaxConfBpsUpdated(uint16 oldValue, uint16 newValue);
    event MaxDivergenceBpsUpdated(uint16 oldValue, uint16 newValue);
    event SafePriceCached(uint256 price1e18, uint256 at);
    event PythUpdated(address indexed keeper, uint256 fee);

    constructor(
        address token_,
        IChainlinkAggregator chainlinkFeed_,
        IPythV2 pyth_,
        bytes32 pythPriceId_,
        uint32 chainlinkMaxStaleSeconds_,
        uint32 pythMaxStaleSeconds_,
        uint16 pythMaxConfBps_,
        uint16 maxDivergenceBps_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (token_ == address(0) || address(chainlinkFeed_) == address(0) || address(pyth_) == address(0)) {
            revert ZeroAddress();
        }
        if (chainlinkMaxStaleSeconds_ == 0) revert InvalidStaleSeconds(chainlinkMaxStaleSeconds_);
        if (pythMaxStaleSeconds_ == 0) revert InvalidStaleSeconds(pythMaxStaleSeconds_);
        if (pythMaxConfBps_ == 0 || pythMaxConfBps_ > BPS) revert InvalidConfBps(pythMaxConfBps_);
        if (maxDivergenceBps_ == 0 || maxDivergenceBps_ > BPS) revert InvalidDivergenceBps(maxDivergenceBps_);

        uint8 clDec = chainlinkFeed_.decimals();
        if (clDec > 18) revert ChainlinkDecimalsTooLarge(clDec);

        TOKEN = token_;
        CHAINLINK_FEED = chainlinkFeed_;
        PYTH = pyth_;
        PYTH_PRICE_ID = pythPriceId_;
        CHAINLINK_DECIMALS = clDec;
        chainlinkMaxStaleSeconds = chainlinkMaxStaleSeconds_;
        pythMaxStaleSeconds = pythMaxStaleSeconds_;
        pythMaxConfBps = pythMaxConfBps_;
        maxDivergenceBps = maxDivergenceBps_;
    }

    // ── IOracleAdapterV2 ────────────────────────────────────────────────

    /// @inheritdoc IOracleAdapterV2
    function peekPrice(address token) external view override returns (uint256 price1e18, bool safe) {
        if (token != TOKEN) revert WrongToken(token, TOKEN);
        (price1e18, safe) = _compute();
    }

    /// @inheritdoc IOracleAdapterV2
    /// @dev Non-view ONLY to refresh the §11 display cache. Returns the SAME tuple as
    /// peekPrice in the same block (O6). No Pyth pull occurs here.
    function readPrice(address token) external override returns (uint256 price1e18, bool safe) {
        if (token != TOKEN) revert WrongToken(token, TOKEN);
        (price1e18, safe) = _compute();
        if (safe) {
            lastSafePrice1e18 = price1e18;
            lastSafeAt = block.timestamp;
            emit SafePriceCached(price1e18, block.timestamp);
        }
    }

    /// @notice Keeper-only Pyth pull. ISOLATED from read/peek so quotes==execution within
    /// a block. Forwards the Pyth fee and refunds the remainder.
    function updatePyth(bytes[] calldata updateData) external payable {
        uint256 fee = PYTH.getUpdateFee(updateData);
        if (msg.value < fee) revert InsufficientUpdateFee(msg.value, fee);
        PYTH.updatePriceFeeds{value: fee}(updateData);
        emit PythUpdated(msg.sender, fee);
        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    // ── Internal dual-source compute (shared by read + peek) ────────────

    /// @dev The ONE safety+price computation. Pure function of current feed state; no
    /// side effects. Returns the mid-price + true only when BOTH legs are fresh/valid,
    /// Pyth confidence is within bound, and divergence is within bound. Otherwise returns
    /// a best-effort display price (surviving leg, else cache, else 0) and false.
    function _compute() internal view returns (uint256 price1e18, bool safe) {
        (bool clOk, uint256 cl1e18) = _readChainlink();
        (bool pyOk, uint256 py1e18) = _readPyth();

        if (!clOk || !pyOk) {
            // Single-source / bad leg ⇒ UNSAFE (§10: a single surviving source is insufficient).
            uint256 display = clOk ? cl1e18 : (pyOk ? py1e18 : lastSafePrice1e18);
            return (display, false);
        }

        uint256 lo = cl1e18 < py1e18 ? cl1e18 : py1e18;
        uint256 diff = cl1e18 > py1e18 ? cl1e18 - py1e18 : py1e18 - cl1e18;
        uint256 mid = (cl1e18 + py1e18) / 2;
        if (diff * BPS > lo * maxDivergenceBps) {
            return (mid, false); // diverged ⇒ UNSAFE (display the mid for context)
        }
        return (mid, true);
    }

    /// @dev Chainlink leg → (ok, price1e18). Same five validity checks as V1 OracleAggregator.
    function _readChainlink() internal view returns (bool ok, uint256 price1e18) {
        // Justification [unused-return]: startedAt (3rd field) carries no staleness info.
        // slither-disable-next-line unused-return
        try CHAINLINK_FEED.latestRoundData() returns (uint80 r, int256 a, uint256, uint256 u, uint80 air) {
            // Finding 3 (hardening): reject future `updatedAt` (no forward tolerance) — a
            // timestamp ahead of `block.timestamp` is not "fresh", it is malformed ⇒ unsafe.
            if (
                a > 0 && u > 0 && u <= block.timestamp && r != 0 && air >= r
                    && block.timestamp <= u + chainlinkMaxStaleSeconds
            ) {
                // CHAINLINK_DECIMALS <= 18 (constructor-guaranteed) ⇒ scale up to 1e18.
                uint256 scale = 10 ** (18 - CHAINLINK_DECIMALS);
                // Finding 1 (fail-closed): cap the normalized price BEFORE multiplying so an
                // astronomical `a` (e.g. decimals=0, answer=int256.max) marks the leg invalid
                // instead of overflowing — the multiply lives in the try's success branch,
                // which try/catch does NOT shield, so an overflow here would otherwise REVERT
                // the read. Comparing `a > MAX_PRICE_1E18 / scale` first is overflow-proof and
                // keeps the read/peek invariant: never revert except WrongToken.
                if (uint256(a) > MAX_PRICE_1E18 / scale) return (false, 0);
                return (true, uint256(a) * scale);
            }
            return (false, 0);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Pyth leg → (ok, price1e18). Validates positive price, fresh publishTime,
    /// expo in [-18, 18], and confidence ratio within bound.
    function _readPyth() internal view returns (bool ok, uint256 price1e18) {
        try PYTH.getPriceUnsafe(PYTH_PRICE_ID) returns (IPythV2.Price memory p) {
            if (p.price <= 0 || p.publishTime == 0) return (false, 0);
            if (p.expo < -18 || p.expo > 18) return (false, 0); // malformed-expo (§14 expo-edge)
            // Finding 3 (hardening): reject future `publishTime` (no forward tolerance) — a
            // timestamp ahead of `block.timestamp` is not "fresh", it is malformed ⇒ unsafe.
            if (p.publishTime > block.timestamp) return (false, 0);
            if (block.timestamp > p.publishTime + pythMaxStaleSeconds) return (false, 0);
            uint256 rawPrice = uint256(uint64(p.price));
            // Confidence ratio in bps; expo cancels (conf and price share expo).
            if (uint256(p.conf) * BPS > rawPrice * pythMaxConfBps) return (false, 0);
            int256 scaleExp = int256(18) + int256(p.expo); // in [0, 36]
            uint256 scaled =
                scaleExp >= 0 ? rawPrice * (10 ** uint256(scaleExp)) : rawPrice / (10 ** uint256(-scaleExp));
            // Finding 2 (fail-closed): cap the normalized price so an astronomical-but-
            // individually-valid leg marks itself invalid instead of letting `_compute`'s
            // divergence math (`diff * BPS`, `cl1e18 + py1e18`) overflow and REVERT the read.
            // rawPrice ≤ uint64.max (~1.8e19) and scaleExp ≤ 36, so the scale-up cannot
            // overflow uint256; the ceiling is applied after normalization. With both legs
            // ≤ MAX_PRICE_1E18 the compute math is overflow-free. Invariant: never revert
            // except WrongToken.
            if (scaled > MAX_PRICE_1E18) return (false, 0);
            return (true, scaled);
        } catch {
            return (false, 0);
        }
    }

    // ── Governance setters (owner = Timelock) ───────────────────────────

    function setChainlinkMaxStaleSeconds(uint32 v) external onlyOwner {
        if (v == 0) revert InvalidStaleSeconds(v);
        emit ChainlinkMaxStaleUpdated(chainlinkMaxStaleSeconds, v);
        chainlinkMaxStaleSeconds = v;
    }

    function setPythMaxStaleSeconds(uint32 v) external onlyOwner {
        if (v == 0) revert InvalidStaleSeconds(v);
        emit PythMaxStaleUpdated(pythMaxStaleSeconds, v);
        pythMaxStaleSeconds = v;
    }

    function setPythMaxConfBps(uint16 v) external onlyOwner {
        if (v == 0 || v > BPS) revert InvalidConfBps(v);
        emit PythMaxConfBpsUpdated(pythMaxConfBps, v);
        pythMaxConfBps = v;
    }

    function setMaxDivergenceBps(uint16 v) external onlyOwner {
        if (v == 0 || v > BPS) revert InvalidDivergenceBps(v);
        emit MaxDivergenceBpsUpdated(maxDivergenceBps, v);
        maxDivergenceBps = v;
    }
}
