// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable }           from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }      from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IArcoraDexPool }     from "./interfaces/IArcoraDexPool.sol";
import { IArcoraDexRegistry } from "./interfaces/IArcoraDexRegistry.sol";
import { IArcoraDexLP }       from "./interfaces/IArcoraDexLP.sol";
import { ArcoraDexLP }        from "./ArcoraDexLP.sol";
import { IChainlinkAggregator } from "./interfaces/IChainlinkAggregator.sol";

/// @title ArcoraDexPool
/// @notice Public-LP, oracle-priced multi-stable shared vault. Single ADEX-LP token.
contract ArcoraDexPool is IArcoraDexPool, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────
    uint16  public  constant MAX_SWAP_FEE_BPS              = 100;
    uint16  public  constant MAX_PROTOCOL_FEE_SHARE_BPS    = 2500;
    uint256 public  constant MINIMUM_LIQUIDITY             = 1000;
    uint256 internal constant BPS                          = 10_000;
    address public  constant DEAD_ADDRESS                  = address(0xdead);

    /// @dev ERC4626-style virtual offset on LP math. Two purposes:
    /// (1) Eliminates round-down-to-zero on tiny follow-up deposits: lpMinted
    ///     for any non-zero usdIn is guaranteed >= 1 regardless of supply/NAV ratio.
    /// (2) Defense-in-depth in case a future feature introduces a balanceOf-derived
    ///     NAV path.
    /// Note: the classic Uniswap-V2 donation-inflation attack is already
    /// structurally blocked by ArcoraDexPool's explicit `reserves[]` accounting
    /// (donations land in token balance but not in `reserves[]`, so NAV is
    /// unchanged). This offset is belt + suspenders.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @dev LP token min-hold period to defeat JIT/MEV sandwich attacks
    /// that try to capture oracle-update NAV deltas via atomic deposit-then-withdraw.
    /// Keeper cadence is 30 min; 1 hour guarantees at least one oracle cycle elapsed.
    uint256 public constant MIN_HOLD_SECONDS = 1 hours;

    // ── Immutables ───────────────────────────────────────────────────
    IArcoraDexRegistry public immutable override REGISTRY;
    IArcoraDexLP       public immutable override LP;

    // ── Storage ──────────────────────────────────────────────────────
    mapping(address token => uint256) public override reserves;
    mapping(address token => uint256) public override protocolFeesAccrued;
    mapping(address token => uint256) public override lastAcceptedPrice;
    mapping(address token => uint256) public override lastValidPrice;     // 1e18-scaled USD price (cache)
    mapping(address token => uint256) public override lastValidPriceAt;   // block.timestamp of cache write
    mapping(address account => uint256) public override lastMintAt;
    uint16 public override swapFeeBps;
    uint16 public override protocolFeeShareBps;
    bool   public override paused;

    constructor(
        address registry,
        uint16  initialSwapFeeBps,
        uint16  initialProtocolFeeShareBps,
        address initialOwner
    ) Ownable(initialOwner) {
        if (registry == address(0)) revert ZeroAddress();
        if (initialSwapFeeBps          > MAX_SWAP_FEE_BPS)            revert InvalidFeeBps(initialSwapFeeBps);
        if (initialProtocolFeeShareBps > MAX_PROTOCOL_FEE_SHARE_BPS)  revert InvalidProtocolFeeShareBps(initialProtocolFeeShareBps);
        REGISTRY = IArcoraDexRegistry(registry);
        LP       = IArcoraDexLP(address(new ArcoraDexLP(address(this))));
        swapFeeBps          = initialSwapFeeBps;
        protocolFeeShareBps = initialProtocolFeeShareBps;
    }

    modifier whenNotPaused() {
        if (paused) revert PoolPaused();
        _;
    }
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }

    // ── Pricing helpers ──────────────────────────────────────────────
    /// @dev Shared internal reader. Returns (price1e18, decimals, isFresh).
    ///      Does NOT mutate state. Callers decide what to do when not fresh.
    ///      All oracle failure modes (bad round, bad timestamp, negative answer,
    ///      staleness) fold into isFresh=false so callers can use the cache
    ///      rather than reverting — preserving pool availability (spec §3.4).
    function _readOracle(address token)
        internal view
        returns (uint256 price1e18, uint8 tokenDecimals, bool isFresh)
    {
        IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        if (!info.isActive) revert TokenNotActive(token);
        tokenDecimals = info.decimals;

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            info.usdOracle.latestRoundData();

        bool roundOk     = (roundId != 0 && answeredInRound >= roundId);
        bool timestampOk = (updatedAt != 0 && updatedAt <= block.timestamp);
        bool ageOk       = timestampOk && (block.timestamp - updatedAt) <= info.maxStaleSeconds;
        bool answerOk    = (answer > 0);

        isFresh = roundOk && timestampOk && ageOk && answerOk;
        if (isFresh) {
            uint8 oracleDec = info.usdOracle.decimals();
            if (oracleDec == 18)      price1e18 = uint256(answer);
            else if (oracleDec < 18)  price1e18 = uint256(answer) * (10 ** (18 - oracleDec));
            else                      price1e18 = uint256(answer) / (10 ** (oracleDec - 18));
        }
    }

    /// @dev Stateful wrapper: updates cache on fresh read; falls back to cache on stale.
    ///      Cache-deviation guard: a fresh oracle reading that diverges too far from
    ///      the existing cache (by more than maxOracleDeviationBps) is treated as
    ///      not-fresh and falls back to the cache, preventing a compromised oracle
    ///      from poisoning the cache within a single block.
    function _readUsdPrice1e18Mut(address token)
        internal returns (uint256 price1e18, uint8 tokenDecimals)
    {
        bool isFresh;
        (price1e18, tokenDecimals, isFresh) = _readOracle(token);

        uint256 cached = lastValidPrice[token];

        if (isFresh && cached != 0) {
            // Cache-deviation guard: a fresh oracle reading that diverges too far
            // from the previous cache cannot poison the cache. Fall through to
            // the cached value below.
            IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
            uint256 diff = price1e18 > cached ? price1e18 - cached : cached - price1e18;
            if (diff * BPS > cached * uint256(info.maxOracleDeviationBps)) {
                isFresh = false;
            }
        }

        if (isFresh) {
            lastValidPrice[token]   = price1e18;
            lastValidPriceAt[token] = block.timestamp;
            emit PriceCacheUpdated(token, price1e18, block.timestamp);
            return (price1e18, tokenDecimals);
        }

        // Stale or cache-rejected — fall back to cache
        price1e18 = cached;
        if (price1e18 == 0) revert NoValidPrice(token);
    }

    /// @dev View-only equivalent: returns cached fallback price without updating it.
    ///      Applies the same cache-deviation guard as _readUsdPrice1e18Mut.
    function _readUsdPrice1e18View(address token)
        internal view returns (uint256 price1e18, uint8 tokenDecimals)
    {
        bool isFresh;
        (price1e18, tokenDecimals, isFresh) = _readOracle(token);

        uint256 cached = lastValidPrice[token];

        if (isFresh && cached != 0) {
            IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
            uint256 diff = price1e18 > cached ? price1e18 - cached : cached - price1e18;
            if (diff * BPS > cached * uint256(info.maxOracleDeviationBps)) {
                isFresh = false;
            }
        }

        if (isFresh) return (price1e18, tokenDecimals);

        price1e18 = cached;
        if (price1e18 == 0) revert NoValidPrice(token);
    }

    /// @dev View-only deviation guard for `quote*()` callers. Reverts when the
    /// current oracle state (or fallback cache) deviates from `lastAcceptedPrice`
    /// by more than `maxOracleDeviationBps`. Does NOT mutate state.
    ///
    /// Behavior is intentionally STRICTER than `swap()` in one scenario:
    ///
    /// - Fresh oracle, raw price within cache-deviation cap of lastAcceptedPrice:
    ///   quote returns the price, swap executes at the same price. (MATCH)
    /// - Fresh oracle, raw price beyond cache-deviation cap from the cache (but
    ///   the cache itself is near lastAcceptedPrice): swap() SILENTLY executes
    ///   at the cached price (Task 2's cache-deviation guard shields the pool
    ///   from oracle whipsaws). quote() REVERTS PriceDeviation here, alerting
    ///   integrators that live oracle has diverged significantly from the
    ///   tradable cache price. This is a deliberate over-revert: integrators
    ///   using quote() as a preflight see an early warning that the executed
    ///   price would be stale. (STRICTER)
    /// - Fresh oracle, raw price beyond cap of lastAcceptedPrice AND the cache
    ///   has tracked the oracle past the cap: both quote() and swap() revert.
    ///   (MATCH)
    /// - Stale oracle, cache near lastAcceptedPrice: both succeed at cache.
    ///   (MATCH)
    /// - Stale oracle, cache drifted from lastAcceptedPrice: both revert.
    ///   (MATCH)
    ///
    /// Implementation reads the raw oracle first (via `_readOracle`) to detect
    /// fresh-but-cache-rejected jumps; then falls back to `_readUsdPrice1e18View`
    /// for the canonical return value when no revert fires.
    function _readUsdPrice1e18WithGuard(address token)
        internal view returns (uint256 price1e18, uint8 tokenDecimals)
    {
        IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        uint256 prev = lastAcceptedPrice[token];

        // Fetch raw oracle first to detect ratchet violations on fresh readings.
        uint256 rawPrice1e18;
        bool isFresh;
        (rawPrice1e18, tokenDecimals, isFresh) = _readOracle(token);

        if (isFresh && prev != 0) {
            uint256 diff = rawPrice1e18 > prev ? rawPrice1e18 - prev : prev - rawPrice1e18;
            if (diff * BPS > prev * uint256(info.maxOracleDeviationBps)) {
                revert PriceDeviation(token, rawPrice1e18, prev, info.maxOracleDeviationBps);
            }
        }

        // Resolve the canonical (cache-guarded) price for the actual return value.
        (price1e18, tokenDecimals) = _readUsdPrice1e18View(token);

        // Also check the cache-guarded price against lastAcceptedPrice in case the
        // oracle is stale (isFresh=false) and the cache itself has drifted.
        if (!isFresh && prev != 0) {
            uint256 diff = price1e18 > prev ? price1e18 - prev : prev - price1e18;
            if (diff * BPS > prev * uint256(info.maxOracleDeviationBps)) {
                revert PriceDeviation(token, price1e18, prev, info.maxOracleDeviationBps);
            }
        }
    }

    /// @dev Stateful: reads oracle, runs PriceGuard against last accepted, updates last accepted.
    function _readAndGuardPrice(address token)
        internal
        returns (uint256 price1e18, uint8 tokenDecimals)
    {
        IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        uint16 maxDevBps;
        (price1e18, tokenDecimals) = _readUsdPrice1e18Mut(token);
        maxDevBps = info.maxOracleDeviationBps;
        uint256 prev = lastAcceptedPrice[token];
        if (prev != 0) {
            uint256 diff = price1e18 > prev ? price1e18 - prev : prev - price1e18;
            if (diff * BPS > prev * uint256(maxDevBps)) {
                revert PriceDeviation(token, price1e18, prev, maxDevBps);
            }
        }
        lastAcceptedPrice[token] = price1e18;
    }

    /// @dev Stateful: refreshes cache on every fresh oracle read.
    function _totalReservesUSDMut() internal returns (uint256 navE18) {
        uint256 n = REGISTRY.tokensLength();
        for (uint256 i = 0; i < n; i++) {
            address t = REGISTRY.tokens(i);
            if (!REGISTRY.isActive(t)) continue;
            (uint256 p, uint8 d) = _readUsdPrice1e18Mut(t);
            navE18 += (reserves[t] * p) / (10 ** d);
        }
    }

    /// @dev View shim used by external view functions and external quote*() callers.
    function totalReservesUSD() public view override returns (uint256 navE18) {
        uint256 n = REGISTRY.tokensLength();
        for (uint256 i = 0; i < n; i++) {
            address t = REGISTRY.tokens(i);
            if (!REGISTRY.isActive(t)) continue;
            (uint256 p, uint8 d) = _readUsdPrice1e18View(t);
            navE18 += (reserves[t] * p) / (10 ** d);
        }
    }

    // ── Public ───────────────────────────────────────────────────────
    function deposit(
        address token,
        uint256 amount,
        uint256 minLpOut,
        uint256 deadline
    ) external override whenNotPaused nonReentrant checkDeadline(deadline) returns (uint256 lpMinted) {
        if (amount == 0) revert ZeroAmount();
        (uint256 priceIn, uint8 dIn) = _readAndGuardPrice(token);
        uint256 usdIn = (amount * priceIn) / (10 ** dIn);

        uint256 supply  = LP.totalSupply();
        uint256 navBefore;
        if (supply == 0) {
            if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
            // Unified formula: with supply=0 and nav=0, becomes (usdIn * VIRTUAL_SHARES) / VIRTUAL_ASSETS = usdIn * 1e6
            lpMinted  = (usdIn * (0 + VIRTUAL_SHARES)) / (0 + VIRTUAL_ASSETS);
            navBefore = 0;
        } else {
            navBefore = _totalReservesUSDMut();
            lpMinted  = (usdIn * (supply + VIRTUAL_SHARES)) / (navBefore + VIRTUAL_ASSETS);
        }
        if (lpMinted < minLpOut) revert InsufficientLpOut(lpMinted, minLpOut);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        reserves[token] += amount;

        if (supply == 0) {
            LP.mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
        }
        LP.mint(msg.sender, lpMinted);
        lastMintAt[msg.sender] = block.timestamp;

        emit Deposited(msg.sender, token, amount, lpMinted, navBefore, navBefore + usdIn);
    }

    function withdraw(
        address tokenOut,
        uint256 lpAmount,
        uint256 minTokenOut,
        uint256 deadline
    ) external override whenNotPaused nonReentrant checkDeadline(deadline) returns (uint256 amountOut) {
        if (lpAmount == 0) revert ZeroAmount();
        uint256 unlockAt = lastMintAt[msg.sender] + MIN_HOLD_SECONDS;
        if (block.timestamp < unlockAt) revert EarlyWithdraw(unlockAt, block.timestamp);

        uint256 navBefore = _totalReservesUSDMut();
        uint256 usdRedeemed = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (LP.totalSupply() + VIRTUAL_SHARES);

        uint256 protFeeAmt;
        uint256 navAfter;
        {
            (uint256 priceOut, uint8 dOut) = _readAndGuardPrice(tokenOut);
            uint256 usdNet     = (usdRedeemed * (BPS - swapFeeBps)) / BPS;
            uint256 protFeeUsd = ((usdRedeemed - usdNet) * protocolFeeShareBps) / BPS;
            uint256 scale      = 10 ** dOut;
            amountOut  = (usdNet * scale) / priceOut;
            protFeeAmt = (protFeeUsd * scale) / priceOut;
            // NAV measures only `reserves[*]`; protocolFeesAccrued and the user's payout
            // both leave reserves[tokenOut], while the LP-retained portion of the fee stays
            // in reserves -> NAV grows for remaining LPs.
            navAfter = navBefore - usdNet - protFeeUsd;
        }

        uint256 r = reserves[tokenOut];
        if (r < amountOut + protFeeAmt) revert InsufficientLiquidity(tokenOut, amountOut + protFeeAmt, r);
        if (amountOut < minTokenOut) revert InsufficientTokenOut(amountOut, minTokenOut);

        LP.burn(msg.sender, lpAmount);
        reserves[tokenOut] = r - (amountOut + protFeeAmt);
        protocolFeesAccrued[tokenOut] += protFeeAmt;

        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit Withdrew(msg.sender, tokenOut, lpAmount, amountOut, protFeeAmt, navBefore, navAfter);
    }

    // ── swap ─────────────────────────────────────────────────────────
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external override whenNotPaused nonReentrant checkDeadline(deadline) returns (uint256 amountOut) {
        if (tokenIn == tokenOut)     revert SameToken(tokenIn);
        if (amountIn  == 0)          revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 protFee;
        uint256 lpFeeUsd1e18;
        {
            (uint256 pIn,  uint8 dIn ) = _readAndGuardPrice(tokenIn);
            (uint256 pOut, uint8 dOut) = _readAndGuardPrice(tokenOut);

            uint256 gross = _grossOut(amountIn, pIn, pOut, dIn, dOut);
            uint256 fee   = (gross * swapFeeBps) / BPS;
            amountOut     = gross - fee;
            protFee       = (fee * protocolFeeShareBps) / BPS;

            // Compute lpFeeUsd1e18 BEFORE we mutate state (it's a metric for the event)
            lpFeeUsd1e18 = ((fee - protFee) * pOut) / (10 ** dOut);
        }

        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        uint256 r = reserves[tokenOut];
        if (r < amountOut + protFee) revert InsufficientLiquidity(tokenOut, amountOut + protFee, r);

        // CEI
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        reserves[tokenIn]   = reserves[tokenIn] + amountIn;
        reserves[tokenOut]  = r - (amountOut + protFee);
        protocolFeesAccrued[tokenOut] += protFee;

        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, lpFeeUsd1e18, protFee, recipient);
    }

    // ── Quote views ──────────────────────────────────────────────────
    function _grossOut(
        uint256 amountIn,
        uint256 priceIn1e18,
        uint256 priceOut1e18,
        uint8   decIn,
        uint8   decOut
    ) internal pure returns (uint256) {
        uint256 usdValue1e18 = (amountIn * priceIn1e18) / (10 ** decIn);
        return (usdValue1e18 * (10 ** decOut)) / priceOut1e18;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn)
        external view override returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut) revert SameToken(tokenIn);
        if (amountIn == 0)       revert ZeroAmount();
        (uint256 pIn,  uint8 dIn ) = _readUsdPrice1e18WithGuard(tokenIn);
        (uint256 pOut, uint8 dOut) = _readUsdPrice1e18WithGuard(tokenOut);
        uint256 gross = _grossOut(amountIn, pIn, pOut, dIn, dOut);
        amountOut     = gross - (gross * swapFeeBps) / BPS;
    }

    function quoteDeposit(address token, uint256 amount)
        external view override returns (uint256 lpOut)
    {
        if (amount == 0) revert ZeroAmount();
        (uint256 pIn, uint8 dIn) = _readUsdPrice1e18WithGuard(token);
        uint256 usdIn  = (amount * pIn) / (10 ** dIn);
        uint256 supply = LP.totalSupply();
        if (supply == 0) {
            if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
            lpOut = (usdIn * (0 + VIRTUAL_SHARES)) / (0 + VIRTUAL_ASSETS);
        } else {
            uint256 nav = totalReservesUSD();
            lpOut = (usdIn * (supply + VIRTUAL_SHARES)) / (nav + VIRTUAL_ASSETS);
        }
    }

    function quoteWithdraw(address tokenOut, uint256 lpAmount)
        external view override returns (uint256 amountOut, uint256 protocolFee)
    {
        if (lpAmount == 0) revert ZeroAmount();
        (uint256 pOut, uint8 dOut) = _readUsdPrice1e18WithGuard(tokenOut);
        {
            uint256 supply      = LP.totalSupply();
            uint256 navBefore   = totalReservesUSD();
            uint256 usdRedeemed = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (supply + VIRTUAL_SHARES);
            uint256 usdNet      = (usdRedeemed * (BPS - swapFeeBps)) / BPS;
            uint256 feeUsd      = usdRedeemed - usdNet;
            uint256 protFeeUsd  = (feeUsd * protocolFeeShareBps) / BPS;
            uint256 scale       = 10 ** dOut;
            amountOut   = (usdNet * scale) / pOut;
            protocolFee = (protFeeUsd * scale) / pOut;
        }
    }

    // ── Owner ────────────────────────────────────────────────────────
    function setSwapFeeBps(uint16 newBps) external override onlyOwner {
        if (newBps > MAX_SWAP_FEE_BPS) revert InvalidFeeBps(newBps);
        emit SwapFeeUpdated(swapFeeBps, newBps);
        swapFeeBps = newBps;
    }

    function setProtocolFeeShareBps(uint16 newBps) external override onlyOwner {
        if (newBps > MAX_PROTOCOL_FEE_SHARE_BPS) revert InvalidProtocolFeeShareBps(newBps);
        emit ProtocolFeeShareUpdated(protocolFeeShareBps, newBps);
        protocolFeeShareBps = newBps;
    }

    function withdrawProtocolFees(address token, uint256 amount, address to) external override onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 acc = protocolFeesAccrued[token];
        if (amount > acc) revert InsufficientLiquidity(token, amount, acc);
        protocolFeesAccrued[token] = acc - amount;
        IERC20(token).safeTransfer(to, amount);
        emit ProtocolFeesWithdrawn(token, amount, to);
    }

    function pause() external override onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Hook invoked by ArcoraDexLP on every transfer to propagate
    /// the deposit-side min-hold lock. The recipient inherits the stricter
    /// of (their existing lock, the sender's lock) — preventing the
    /// deposit→transfer→withdraw JIT bypass.
    /// @dev Only the LP contract may call this.
    function notifyLPTransfer(address from, address to) external override {
        if (msg.sender != address(LP)) revert NotLP();
        uint256 fromLock = lastMintAt[from];
        if (fromLock > lastMintAt[to]) {
            lastMintAt[to] = fromLock;
        }
    }

    function syncAcceptedPrice(address token) external override onlyOwner returns (uint256 price1e18) {
        // Owner-only escape hatch: bypasses the cache-deviation guard so the operator
        // can force-accept an out-of-band price after a large legitimate move and
        // simultaneously reset both the cache and the lastAcceptedPrice baseline.
        uint8 tokenDecimals;
        bool isFresh;
        (price1e18, tokenDecimals, isFresh) = _readOracle(token);
        if (!isFresh) {
            // If the oracle itself is stale, fall back to the existing cache so the
            // operator still gets a sensible (if old) baseline reset.
            price1e18 = lastValidPrice[token];
            if (price1e18 == 0) revert NoValidPrice(token);
        } else {
            // Update cache unconditionally (operator-approved override).
            lastValidPrice[token]   = price1e18;
            lastValidPriceAt[token] = block.timestamp;
            emit PriceCacheUpdated(token, price1e18, block.timestamp);
        }
        uint256 oldPrice = lastAcceptedPrice[token];
        lastAcceptedPrice[token] = price1e18;
        emit AcceptedPriceSynced(token, oldPrice, price1e18);
    }
}
