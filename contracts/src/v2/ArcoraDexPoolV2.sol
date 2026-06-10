// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IArcoraDexPoolV2} from "./interfaces/IArcoraDexPoolV2.sol";
import {IArcoraDexRegistryV2} from "./interfaces/IArcoraDexRegistryV2.sol";
import {IArcoraDexLPV2} from "./interfaces/IArcoraDexLPV2.sol";
import {IOracleAdapterV2} from "./interfaces/IOracleAdapterV2.sol";
import {ArcoraDexLPV2} from "./ArcoraDexLPV2.sol";
import {FeeBandMathV2} from "./lib/FeeBandMathV2.sol";

/// @title ArcoraDexPoolV2
/// @notice Immutable (non-upgradeable) reserve-floor-protected oracle-priced pool.
/// Carries V1 audited patterns: Ownable2Step, ReentrancyGuard, SafeERC20, measured
/// balance deltas (L-10), minOut/deadline, 1e18 NAV, LP min-hold (H-1), virtual-share
/// offset (#A), I-1 reserve guard via Registry.setPool. New: binary-safe oracle adapter
/// and marginal fee bands via FeeBandMathV2.
contract ArcoraDexPoolV2 is IArcoraDexPoolV2, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using FeeBandMathV2 for FeeBandMathV2.Band[];

    uint16 public constant MAX_PROTOCOL_FEE_SHARE_BPS = 2_500;
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;
    uint256 internal constant BPS = 10_000;
    address public constant DEAD_ADDRESS = address(0xdead);
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 public constant MIN_HOLD_SECONDS = 1 hours;

    // slither-disable-next-line naming-convention
    IArcoraDexRegistryV2 public immutable override REGISTRY;
    // slither-disable-next-line naming-convention
    IArcoraDexLPV2 public immutable override LP;

    mapping(address token => uint256) public override reserves;
    mapping(address token => uint256) public override protocolFeesAccrued;
    mapping(address account => uint256) public override lastMintAt;
    uint16 public protocolFeeShareBps;
    bool public override paused;
    address public override pauseGuardian;

    constructor(address registry, uint16 initialProtocolFeeShareBps, address initialOwner) Ownable(initialOwner) {
        if (registry == address(0)) revert ZeroAddress();
        if (initialProtocolFeeShareBps > MAX_PROTOCOL_FEE_SHARE_BPS) {
            revert InvalidProtocolFeeShareBps(initialProtocolFeeShareBps);
        }
        REGISTRY = IArcoraDexRegistryV2(registry);
        LP = IArcoraDexLPV2(address(new ArcoraDexLPV2(address(this))));
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

    // ── Oracle (binary safe) ────────────────────────────────────────
    function _readSafe(address token, IArcoraDexRegistryV2.TokenConfigV2 memory c)
        internal
        returns (uint256 price1e18)
    {
        if (!c.isActive) revert TokenNotActive(token);
        bool safe;
        (price1e18, safe) = c.adapter.readPrice(token);
        if (!safe || price1e18 == 0) revert OracleUnsafe(token);
    }

    function _peekSafe(address token, IArcoraDexRegistryV2.TokenConfigV2 memory c)
        internal
        view
        returns (uint256 price1e18)
    {
        if (!c.isActive) revert TokenNotActive(token);
        bool safe;
        (price1e18, safe) = c.adapter.peekPrice(token);
        if (!safe || price1e18 == 0) revert OracleUnsafe(token);
    }

    function _reserveUsd(address token, uint256 price1e18, uint8 dec) internal view returns (uint256) {
        return (reserves[token] * price1e18) / (10 ** dec);
    }

    /// @dev Total gross USD entitlement that traverse can place down to the floor for
    /// `tokenOut` at its current reserve — the sum of every band's gross-for-debit.
    /// Found by feeding traverse a deliberately-huge gross and reading how much debit
    /// it placed; because traverse caps at the floor, the placed gross == max gross.
    function _maxGrossUsd(IArcoraDexRegistryV2.TokenConfigV2 memory c, uint256 reserveUsd)
        internal
        view
        returns (uint256 grossUsd, FeeBandMathV2.Result memory r)
    {
        if (reserveUsd <= c.minimumReserveUsd) return (0, r);
        // Binary search the largest gross whose traverse returns ok. Upper bound is the
        // full usable reserve (debit <= gross always, so usable is a safe ceiling).
        uint256 lo;
        uint256 hi = reserveUsd - c.minimumReserveUsd;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            FeeBandMathV2.Result memory probe = FeeBandMathV2.traverse(
                mid, reserveUsd, c.minimumReserveUsd, c.targetReserveUsd, c.bands, protocolFeeShareBps
            );
            if (probe.ok) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        grossUsd = lo;
        r = FeeBandMathV2.traverse(
            grossUsd, reserveUsd, c.minimumReserveUsd, c.targetReserveUsd, c.bands, protocolFeeShareBps
        );
    }

    // ── NAV ──────────────────────────────────────────────────────────
    /// @dev Stateful NAV: reverts (via _readSafe) if any active token is unsafe — this
    /// is the §11 "operations whose NAV requires an unsafe price stop" guarantee.
    function _navMut() internal returns (uint256 navE18) {
        uint256 n = REGISTRY.tokensLength();
        for (uint256 i; i < n;) {
            address t = REGISTRY.tokens(i);
            IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(t);
            if (c.isActive) {
                uint256 p = _readSafe(t, c);
                navE18 += (reserves[t] * p) / (10 ** c.decimals);
            }
            unchecked {
                ++i;
            }
        }
    }

    function totalReservesUSD() public view override returns (uint256 navE18) {
        uint256 n = REGISTRY.tokensLength();
        for (uint256 i; i < n;) {
            address t = REGISTRY.tokens(i);
            IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(t);
            if (c.isActive) {
                uint256 p = _peekSafe(t, c);
                navE18 += (reserves[t] * p) / (10 ** c.decimals);
            }
            unchecked {
                ++i;
            }
        }
    }

    // ── deposit ──────────────────────────────────────────────────────
    function deposit(address token, uint256 amount, uint256 minLpOut, uint256 deadline)
        external
        override
        whenNotPaused
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 lpMinted)
    {
        if (amount == 0) revert ZeroAmount();
        IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(token);
        uint256 priceIn = _readSafe(token, c);

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroAmount();

        uint256 usdIn = (received * priceIn) / (10 ** c.decimals);

        // Rollout cap (§6.2): reject if post-deposit reserve USD would exceed depositCapUsd.
        _checkDepositCap(token, c, received, priceIn);

        uint256 supply = LP.totalSupply();
        uint256 navBefore;
        (lpMinted, navBefore) = _computeLpMint(supply, usdIn);
        if (lpMinted < minLpOut) revert InsufficientLpOut(lpMinted, minLpOut);

        reserves[token] += received;
        if (supply == 0) LP.mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
        LP.mint(msg.sender, lpMinted);
        lastMintAt[msg.sender] = block.timestamp;
        emit Deposited(msg.sender, token, received, lpMinted, navBefore, navBefore + usdIn);
    }

    /// @dev Rollout-cap check (§6.2) for `deposit`, extracted verbatim into a private helper
    /// solely to bound the live stack-slot count in `deposit` (avoids stack-too-deep without
    /// via-IR). View; arithmetic, rounding and ordering are identical to the inline flow.
    function _checkDepositCap(
        address token,
        IArcoraDexRegistryV2.TokenConfigV2 memory c,
        uint256 received,
        uint256 priceIn
    ) private view {
        if (c.depositCapUsd != 0) {
            uint256 postReserveUsd = ((reserves[token] + received) * priceIn) / (10 ** c.decimals);
            if (postReserveUsd > c.depositCapUsd) revert DepositCapExceeded(token);
        }
    }

    /// @dev LP-mint math for `deposit`, extracted verbatim into a private helper solely to
    /// bound the live stack-slot count in `deposit` (avoids stack-too-deep without via-IR).
    /// Stateful (routes through `_navMut`, which §11-stops on any unsafe active price);
    /// arithmetic, rounding, ordering and the virtual-share offset (#A) are unchanged. The
    /// NAV read happens before any reserve mutation, exactly as in the inline flow.
    function _computeLpMint(uint256 supply, uint256 usdIn) private returns (uint256 lpMinted, uint256 navBefore) {
        if (supply == 0) {
            if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
            lpMinted = (usdIn * VIRTUAL_SHARES) / VIRTUAL_ASSETS;
        } else {
            navBefore = _navMut();
            lpMinted = (usdIn * (supply + VIRTUAL_SHARES)) / (navBefore + VIRTUAL_ASSETS);
        }
    }

    // ── swap (§8.1) ───────────────────────────────────────────────────
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external override whenNotPaused nonReentrant checkDeadline(deadline) returns (uint256 amountOut) {
        if (tokenIn == tokenOut) revert SameToken(tokenIn);
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 inBalBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 receivedIn = IERC20(tokenIn).balanceOf(address(this)) - inBalBefore;
        if (receivedIn == 0) revert ZeroAmount();

        uint256 protFeeOut;
        uint256 feeUsd;
        (amountOut, protFeeOut, feeUsd) = _computeSwapOutput(tokenIn, tokenOut, receivedIn);

        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        uint256 rv = reserves[tokenOut];
        if (rv < amountOut + protFeeOut) revert InsufficientLiquidity(tokenOut, amountOut + protFeeOut, rv);

        reserves[tokenIn] += receivedIn;
        reserves[tokenOut] = rv - (amountOut + protFeeOut);
        protocolFeesAccrued[tokenOut] += protFeeOut;
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, receivedIn, amountOut, feeUsd, protFeeOut, recipient);
    }

    /// @dev Priced-output computation for `swap`, extracted verbatim into a private helper
    /// solely to bound the live stack-slot count in `swap` (avoids stack-too-deep without
    /// via-IR). Stateful (routes through `_readSafe`); arithmetic, rounding, ordering and
    /// the shared `FeeBandMathV2.traverse` call are identical to the inline §8.1 flow.
    function _computeSwapOutput(address tokenIn, address tokenOut, uint256 receivedIn)
        private
        returns (uint256 amountOut, uint256 protFeeOut, uint256 feeUsd)
    {
        IArcoraDexRegistryV2.TokenConfigV2 memory cIn = REGISTRY.tokenConfig(tokenIn);
        IArcoraDexRegistryV2.TokenConfigV2 memory cOut = REGISTRY.tokenConfig(tokenOut);
        uint256 pIn = _readSafe(tokenIn, cIn);
        uint256 pOut = _readSafe(tokenOut, cOut);

        uint256 grossUsd = (receivedIn * pIn) / (10 ** cIn.decimals);
        FeeBandMathV2.Result memory r = FeeBandMathV2.traverse(
            grossUsd,
            _reserveUsd(tokenOut, pOut, cOut.decimals),
            cOut.minimumReserveUsd,
            cOut.targetReserveUsd,
            cOut.bands,
            protocolFeeShareBps
        );
        if (!r.ok) revert ReserveFloorBreached(tokenOut);
        uint256 scale = 10 ** cOut.decimals;
        amountOut = (r.totalUserOutputUsd * scale) / pOut;
        protFeeOut = (r.totalProtocolFeeUsd * scale) / pOut;
        feeUsd = r.totalFeeUsd;
    }

    // ── quoteSwapV2 (shares traverse with swap) ────────────────────────
    function quoteSwapV2(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        override
        returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps)
    {
        if (tokenIn == tokenOut) revert SameToken(tokenIn);
        if (amountIn == 0) revert ZeroAmount();
        IArcoraDexRegistryV2.TokenConfigV2 memory cIn = REGISTRY.tokenConfig(tokenIn);
        IArcoraDexRegistryV2.TokenConfigV2 memory cOut = REGISTRY.tokenConfig(tokenOut);
        uint256 pIn = _peekSafe(tokenIn, cIn);
        uint256 pOut = _peekSafe(tokenOut, cOut);
        uint256 grossUsd = (amountIn * pIn) / (10 ** cIn.decimals);
        uint256 reserveUsd = _reserveUsd(tokenOut, pOut, cOut.decimals);
        FeeBandMathV2.Result memory r = FeeBandMathV2.traverse(
            grossUsd, reserveUsd, cOut.minimumReserveUsd, cOut.targetReserveUsd, cOut.bands, protocolFeeShareBps
        );
        if (!r.ok) revert ReserveFloorBreached(tokenOut);
        uint256 scale = 10 ** cOut.decimals;
        amountOut = (r.totalUserOutputUsd * scale) / pOut;
        protocolFee = (r.totalProtocolFeeUsd * scale) / pOut;
        feeUsd1e18 = r.totalFeeUsd;
        postHealthBps =
            FeeBandMathV2.healthBps(reserveUsd - r.totalReserveDebitUsd, cOut.minimumReserveUsd, cOut.targetReserveUsd);
    }

    // ── reserveHealth view (§9) ────────────────────────────────────────
    function reserveHealth(address token) external view override returns (uint256) {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(token);
        uint256 p = _peekSafe(token, c);
        return FeeBandMathV2.healthBps(_reserveUsd(token, p, c.decimals), c.minimumReserveUsd, c.targetReserveUsd);
    }

    // ── LP transfer hook (H-1) ─────────────────────────────────────────
    function notifyLPTransfer(address from, address) external override {
        if (msg.sender != address(LP)) revert NotLP();
        uint256 unlockAt = lastMintAt[from] + MIN_HOLD_SECONDS;
        if (block.timestamp < unlockAt) revert EarlyTransfer(unlockAt, block.timestamp);
    }

    // ── Owner / Guardian ───────────────────────────────────────────────
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

    /// @notice Guardian pause-only (§6.2): guardian OR owner may pause.
    function pause() external override {
        if (msg.sender != owner() && msg.sender != pauseGuardian) revert NotAuthorized();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause is owner-only (the governance Timelock). The guardian cannot unpause.
    function unpause() external override onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setPauseGuardian(address newGuardian) external override onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        emit PauseGuardianUpdated(pauseGuardian, newGuardian);
        pauseGuardian = newGuardian;
    }

    // ── single-token withdraw (§8.2) ───────────────────────────────────
    function withdrawSingle(address tokenOut, uint256 lpAmount, uint256 minTokenOut, uint256 deadline)
        external
        override
        whenNotPaused
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        if (lpAmount == 0) revert ZeroAmount();
        uint256 unlockAt = lastMintAt[msg.sender] + MIN_HOLD_SECONDS;
        if (block.timestamp < unlockAt) revert EarlyWithdraw(unlockAt, block.timestamp);

        uint256 navBefore = _navMut(); // reverts OracleUnsafe if any active token unsafe (§11 NAV)
        uint256 grossUsd = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (LP.totalSupply() + VIRTUAL_SHARES);

        uint256 protFeeOut;
        uint256 feeUsd;
        (amountOut, protFeeOut, feeUsd) = _computeWithdrawOutput(tokenOut, grossUsd);

        uint256 rv = reserves[tokenOut];
        if (rv < amountOut + protFeeOut) revert InsufficientLiquidity(tokenOut, amountOut + protFeeOut, rv);
        if (amountOut < minTokenOut) revert InsufficientTokenOut(amountOut, minTokenOut);

        LP.burn(msg.sender, lpAmount);
        reserves[tokenOut] = rv - (amountOut + protFeeOut);
        protocolFeesAccrued[tokenOut] += protFeeOut;
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        emit WithdrewSingle(msg.sender, tokenOut, lpAmount, amountOut, protFeeOut, feeUsd);
    }

    /// @dev Priced-output computation for `withdrawSingle`, extracted verbatim into a private
    /// helper solely to bound the live stack-slot count in `withdrawSingle` (avoids
    /// stack-too-deep without via-IR). Stateful (routes through `_readSafe`); arithmetic,
    /// rounding, ordering and the shared `FeeBandMathV2.traverse` call are identical to the
    /// inline §8.2 flow.
    function _computeWithdrawOutput(address tokenOut, uint256 grossUsd)
        private
        returns (uint256 amountOut, uint256 protFeeOut, uint256 feeUsd)
    {
        IArcoraDexRegistryV2.TokenConfigV2 memory cOut = REGISTRY.tokenConfig(tokenOut);
        uint256 pOut = _readSafe(tokenOut, cOut);
        FeeBandMathV2.Result memory r = FeeBandMathV2.traverse(
            grossUsd,
            _reserveUsd(tokenOut, pOut, cOut.decimals),
            cOut.minimumReserveUsd,
            cOut.targetReserveUsd,
            cOut.bands,
            protocolFeeShareBps
        );
        if (!r.ok) revert ReserveFloorBreached(tokenOut);
        uint256 scale = 10 ** cOut.decimals;
        amountOut = (r.totalUserOutputUsd * scale) / pOut;
        protFeeOut = (r.totalProtocolFeeUsd * scale) / pOut;
        feeUsd = r.totalFeeUsd;
    }

    /// @notice §8.3 proportional emergency exit. No oracle, no floor, no pause gate.
    /// Returns the pro-rata share of every active token's reserve. Protocol fees
    /// (held separately in protocolFeesAccrued) are excluded.
    function withdrawProportional(uint256 lpAmount, uint256 deadline)
        external
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256[] memory amounts)
    {
        if (lpAmount == 0) revert ZeroAmount();
        uint256 supply = LP.totalSupply();
        uint256 n = REGISTRY.tokensLength();
        amounts = new uint256[](n);

        // Burn FIRST (CEI): supply used for the pro-rata is the pre-burn supply.
        LP.burn(msg.sender, lpAmount);

        for (uint256 i; i < n;) {
            address t = REGISTRY.tokens(i);
            uint256 rv = reserves[t];
            if (rv != 0) {
                uint256 share = (lpAmount * rv) / supply; // round down
                if (share != 0) {
                    reserves[t] = rv - share;
                    amounts[i] = share;
                    IERC20(t).safeTransfer(msg.sender, share);
                }
            }
            unchecked {
                ++i;
            }
        }
        emit WithdrewProportional(msg.sender, lpAmount);
    }

    function quoteWithdrawV2(address tokenOut, uint256 lpAmount)
        external
        view
        override
        returns (uint256 amountOut, uint256 protocolFee, uint256 feeUsd1e18, uint256 postHealthBps)
    {
        if (lpAmount == 0) revert ZeroAmount();
        uint256 navBefore = totalReservesUSD(); // view, reverts OracleUnsafe if any active unsafe
        uint256 grossUsd = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (LP.totalSupply() + VIRTUAL_SHARES);
        IArcoraDexRegistryV2.TokenConfigV2 memory cOut = REGISTRY.tokenConfig(tokenOut);
        uint256 pOut = _peekSafe(tokenOut, cOut);
        uint256 reserveUsd = _reserveUsd(tokenOut, pOut, cOut.decimals);
        FeeBandMathV2.Result memory r = FeeBandMathV2.traverse(
            grossUsd, reserveUsd, cOut.minimumReserveUsd, cOut.targetReserveUsd, cOut.bands, protocolFeeShareBps
        );
        if (!r.ok) revert ReserveFloorBreached(tokenOut);
        uint256 scale = 10 ** cOut.decimals;
        amountOut = (r.totalUserOutputUsd * scale) / pOut;
        protocolFee = (r.totalProtocolFeeUsd * scale) / pOut;
        feeUsd1e18 = r.totalFeeUsd;
        postHealthBps =
            FeeBandMathV2.healthBps(reserveUsd - r.totalReserveDebitUsd, cOut.minimumReserveUsd, cOut.targetReserveUsd);
    }

    function maxSwapOut(address tokenOut) external view override returns (uint256 netOut, uint256 grossUsd1e18) {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(tokenOut);
        uint256 pOut = _peekSafe(tokenOut, c);
        uint256 reserveUsd = _reserveUsd(tokenOut, pOut, c.decimals);
        FeeBandMathV2.Result memory r;
        (grossUsd1e18, r) = _maxGrossUsd(c, reserveUsd);
        netOut = (r.totalUserOutputUsd * (10 ** c.decimals)) / pOut;
    }

    function maxWithdraw(address tokenOut, address account)
        external
        view
        override
        returns (uint256 lpAmount, uint256 netOut)
    {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = REGISTRY.tokenConfig(tokenOut);
        uint256 pOut = _peekSafe(tokenOut, c);
        uint256 reserveUsd = _reserveUsd(tokenOut, pOut, c.decimals);
        (uint256 maxGrossUsd, FeeBandMathV2.Result memory r) = _maxGrossUsd(c, reserveUsd);
        // LP amount whose gross USD share == maxGrossUsd (round DOWN so we never overstate).
        uint256 navBefore = totalReservesUSD();
        uint256 supply = LP.totalSupply();
        // gross = lp * (nav + VA) / (supply + VS)  =>  lp = gross * (supply + VS) / (nav + VA)
        uint256 lpFromGross = (maxGrossUsd * (supply + VIRTUAL_SHARES)) / (navBefore + VIRTUAL_ASSETS);
        uint256 bal = LP.balanceOf(account);
        lpAmount = lpFromGross < bal ? lpFromGross : bal;
        if (lpAmount == lpFromGross) {
            netOut = (r.totalUserOutputUsd * (10 ** c.decimals)) / pOut;
        } else {
            // Account-balance bound: recompute the net for the smaller LP slice.
            uint256 grossUsd = (lpAmount * (navBefore + VIRTUAL_ASSETS)) / (supply + VIRTUAL_SHARES);
            FeeBandMathV2.Result memory r2 = FeeBandMathV2.traverse(
                grossUsd, reserveUsd, c.minimumReserveUsd, c.targetReserveUsd, c.bands, protocolFeeShareBps
            );
            netOut = (r2.totalUserOutputUsd * (10 ** c.decimals)) / pOut;
        }
    }
}
