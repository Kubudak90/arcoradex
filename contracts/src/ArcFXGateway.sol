// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable }           from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }      from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IStablePool }           from "./pool/IStablePool.sol";
import { IStablecoinRegistry }   from "./registry/IStablecoinRegistry.sol";

/// @title ArcFXGateway
/// @notice Merchant checkout + atomic FX settlement on Arc. v0.7 — token-agnostic,
///         routes through StablePool for cross-stable swaps. Same-token path is direct.
contract ArcFXGateway is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Immutable config (v0.7) ────────────────────────────────────────
    IStablePool          public immutable POOL;
    IStablecoinRegistry  public immutable REGISTRY;
    uint256              public immutable PROTOCOL_FEE_BPS;

    /// @dev Caps for the bisection-based `_estimateAmountIn`. Doubling finds
    /// an upper bound in O(log gap) view calls; bisection narrows in O(log gap)
    /// more. Combined ceiling of ~128 quote() calls handles any plausible
    /// FX-cross rounding plateau (e.g. cheap → expensive stable mismatches
    /// where each input wei nudges output by sub-wei increments).
    uint256 private constant ESTIMATE_MAX_DOUBLES = 64;
    uint256 private constant ESTIMATE_MAX_BISECTS = 64;

    // ── Merchant registry ──────────────────────────────────────────────
    struct Merchant {
        address payoutAddress;
        address payoutToken;
        bool    active;
    }
    mapping(address merchant => Merchant) public merchants;

    // ── Invoice state ──────────────────────────────────────────────────
    enum InvoiceStatus { None, Created, Paid, Refunded }
    struct Invoice {
        address       merchant;
        address       payIn;
        address       payoutToken;   // locked at creation; merchant changes don't reroute pending invoices
        uint256       amountOut;
        uint64        expiresAt;
        InvoiceStatus status;
        address       paidBy;
    }
    mapping(bytes32 globalId => Invoice) public invoices;

    // ── Payment accounting (for refunds) ───────────────────────────────
    /// @dev Recorded inside pay() so refundInvoice() knows the exact amounts
    /// without re-deriving them from oracle math (which drifts).
    struct InvoicePayment {
        uint256 merchantPayout;  // amount the merchant received in payoutToken
        uint256 fee;             // protocol fee taken in payoutToken
    }
    mapping(bytes32 globalId => InvoicePayment) public payments;

    // ── Accounting ─────────────────────────────────────────────────────
    mapping(address token => uint256) public protocolFeesAccrued;

    // ── Delegate authorization ─────────────────────────────────────────
    mapping(address merchant => mapping(address delegate => uint64 expiresAt))
        public delegateAuthorizations;

    // ── Events ─────────────────────────────────────────────────────────
    event MerchantRegistered(address indexed merchant, address payoutAddress, address payoutToken);
    event MerchantPayoutAddressUpdated(address indexed merchant, address oldAddress, address newAddress);
    event MerchantPayoutTokenUpdated(address indexed merchant, address oldToken, address newToken);
    event MerchantDeactivated(address indexed merchant);
    event InvoiceCreated(
        bytes32 indexed globalId,
        address indexed merchant,
        bytes32 indexed merchantInvoiceId,
        address payIn,
        address payoutToken,
        uint256 amountOut,
        uint64 expiresAt
    );
    event InvoicePaid(
        bytes32 indexed globalId,
        address indexed payer,
        uint256 amountIn,
        uint256 grossReceived,
        uint256 merchantPayout,
        uint256 fee
    );
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event DelegateAuthorized(address indexed merchant, address indexed delegate, uint64 expiresAt);
    event DelegateRevoked(address indexed merchant, address indexed delegate);
    event InvoiceRefunded(
        bytes32 indexed globalId,
        address indexed refundedTo,
        address indexed payoutToken,
        uint256 merchantPayout,
        uint256 protocolFeeReturned
    );

    // ── Errors ─────────────────────────────────────────────────────────
    error NotMerchant();
    error MerchantAlreadyRegistered();
    error MerchantInactive();
    error InvalidPayoutToken();
    error InvalidPayoutAddress();
    error InvoiceAlreadyExists(bytes32 globalId);
    error InvoiceAlreadyPaid(bytes32 globalId);
    error InvoiceExpired(bytes32 globalId);
    error InvoiceNotFound(bytes32 globalId);
    error UnsupportedPair();
    error SlippageExceeded(uint256 required, uint256 max);
    error DelegateNotAuthorized();
    error InvoiceNotRefundable(bytes32 globalId);
    error InsufficientFeesForRefund(uint256 required, uint256 accrued);

    // ── Constructor ────────────────────────────────────────────────────
    constructor(
        IStablePool pool,
        IStablecoinRegistry registry,
        uint256 protocolFeeBps,
        address initialOwner
    ) Ownable(initialOwner) {
        POOL = pool;
        REGISTRY = registry;
        PROTOCOL_FEE_BPS = protocolFeeBps;
    }

    // ── Merchant management ────────────────────────────────────────────

    function registerMerchant(address payoutAddress, address payoutToken) external {
        if (merchants[msg.sender].active) revert MerchantAlreadyRegistered();
        if (payoutAddress == address(0)) revert InvalidPayoutAddress();
        if (!REGISTRY.isActive(payoutToken)) revert InvalidPayoutToken();
        merchants[msg.sender] = Merchant({
            payoutAddress: payoutAddress,
            payoutToken:   payoutToken,
            active:        true
        });
        emit MerchantRegistered(msg.sender, payoutAddress, payoutToken);
    }

    function updatePayoutAddress(address newPayoutAddress) external {
        Merchant storage m = merchants[msg.sender];
        if (!m.active) revert NotMerchant();
        if (newPayoutAddress == address(0)) revert InvalidPayoutAddress();
        address old = m.payoutAddress;
        m.payoutAddress = newPayoutAddress;
        emit MerchantPayoutAddressUpdated(msg.sender, old, newPayoutAddress);
    }

    function updatePayoutToken(address newPayoutToken) external {
        Merchant storage m = merchants[msg.sender];
        if (!m.active) revert NotMerchant();
        if (!REGISTRY.isActive(newPayoutToken)) revert InvalidPayoutToken();
        address old = m.payoutToken;
        m.payoutToken = newPayoutToken;
        emit MerchantPayoutTokenUpdated(msg.sender, old, newPayoutToken);
    }

    function deactivateMerchant() external {
        Merchant storage m = merchants[msg.sender];
        if (!m.active) revert NotMerchant();
        m.active = false;
        emit MerchantDeactivated(msg.sender);
    }

    // ── Invoice creation ───────────────────────────────────────────────

    function createInvoice(
        bytes32 merchantInvoiceId,
        address payIn,
        uint256 amountOut,
        uint64 expiresAt
    ) external returns (bytes32 globalId) {
        return _createInvoice(msg.sender, merchantInvoiceId, payIn, amountOut, expiresAt);
    }

    function createInvoiceFor(
        address merchant,
        bytes32 merchantInvoiceId,
        address payIn,
        uint256 amountOut,
        uint64 expiresAt
    ) external returns (bytes32 globalId) {
        uint64 authExpiry = delegateAuthorizations[merchant][msg.sender];
        if (authExpiry < block.timestamp) revert DelegateNotAuthorized();
        return _createInvoice(merchant, merchantInvoiceId, payIn, amountOut, expiresAt);
    }

    function _createInvoice(
        address merchant,
        bytes32 merchantInvoiceId,
        address payIn,
        uint256 amountOut,
        uint64 expiresAt
    ) internal returns (bytes32 globalId) {
        Merchant memory m = merchants[merchant];
        if (!m.active) revert MerchantInactive();
        if (!REGISTRY.isActive(payIn)) revert UnsupportedPair();

        globalId = keccak256(abi.encode(merchant, merchantInvoiceId));
        if (invoices[globalId].status != InvoiceStatus.None) revert InvoiceAlreadyExists(globalId);

        invoices[globalId] = Invoice({
            merchant:    merchant,
            payIn:       payIn,
            payoutToken: m.payoutToken,
            amountOut:   amountOut,
            expiresAt:   expiresAt,
            status:      InvoiceStatus.Created,
            paidBy:      address(0)
        });
        emit InvoiceCreated(globalId, merchant, merchantInvoiceId, payIn, m.payoutToken, amountOut, expiresAt);
    }

    // ── Pay ────────────────────────────────────────────────────────────

    function pay(bytes32 globalId, uint256 maxAmountIn) external nonReentrant {
        Invoice storage inv = invoices[globalId];
        if (inv.status == InvoiceStatus.None) revert InvoiceNotFound(globalId);
        if (inv.status == InvoiceStatus.Paid) revert InvoiceAlreadyPaid(globalId);
        if (block.timestamp > inv.expiresAt)  revert InvoiceExpired(globalId);

        address payoutToken    = inv.payoutToken;
        address payoutAddress  = merchants[inv.merchant].payoutAddress;

        // Same-token direct path: no swap, no AMM fee.
        if (inv.payIn == payoutToken) {
            if (inv.amountOut > maxAmountIn) revert SlippageExceeded(inv.amountOut, maxAmountIn);

            IERC20(inv.payIn).safeTransferFrom(msg.sender, address(this), inv.amountOut);

            uint256 directFee    = (inv.amountOut * PROTOCOL_FEE_BPS) / 10_000;
            uint256 directPayout = inv.amountOut - directFee;
            protocolFeesAccrued[payoutToken] += directFee;

            inv.status = InvoiceStatus.Paid;
            inv.paidBy = msg.sender;
            payments[globalId] = InvoicePayment({ merchantPayout: directPayout, fee: directFee });

            IERC20(payoutToken).safeTransfer(payoutAddress, directPayout);
            emit InvoicePaid(globalId, msg.sender, inv.amountOut, inv.amountOut, directPayout, directFee);
            return;
        }

        // Cross-token path: route through StablePool.
        uint256 amountIn = _estimateAmountIn(inv.payIn, payoutToken, inv.amountOut);
        if (amountIn > maxAmountIn) revert SlippageExceeded(amountIn, maxAmountIn);

        IERC20(inv.payIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(inv.payIn).forceApprove(address(POOL), amountIn);
        uint256 received = POOL.swap(
            inv.payIn,
            payoutToken,
            amountIn,
            inv.amountOut,
            block.timestamp + 1,
            address(this)
        );

        uint256 swapFee    = (received * PROTOCOL_FEE_BPS) / 10_000;
        uint256 swapPayout = received - swapFee;
        protocolFeesAccrued[payoutToken] += swapFee;

        inv.status = InvoiceStatus.Paid;
        inv.paidBy = msg.sender;
        payments[globalId] = InvoicePayment({ merchantPayout: swapPayout, fee: swapFee });

        IERC20(payoutToken).safeTransfer(payoutAddress, swapPayout);
        emit InvoicePaid(globalId, msg.sender, amountIn, received, swapPayout, swapFee);
    }

    // ── Refund ─────────────────────────────────────────────────────────

    /// @notice Refund a paid invoice. Pulls `merchantPayout` from the merchant's
    /// wallet (requires payoutToken approve to gateway), forwards it to the
    /// original payer, and returns the protocol fee from `protocolFeesAccrued`
    /// to the merchant. The invoice is marked Refunded; second calls revert.
    /// Callable by the merchant or the contract owner.
    function refundInvoice(bytes32 globalId) external nonReentrant {
        Invoice storage inv = invoices[globalId];
        if (inv.status != InvoiceStatus.Paid) revert InvoiceNotRefundable(globalId);
        if (msg.sender != inv.merchant && msg.sender != owner()) revert NotMerchant();

        InvoicePayment memory p = payments[globalId];
        address payoutToken = inv.payoutToken;
        address refundTo    = inv.paidBy;
        address merchant    = inv.merchant;

        // Surface a clean error if the owner already withdrew the fee bucket.
        if (protocolFeesAccrued[payoutToken] < p.fee) {
            revert InsufficientFeesForRefund(p.fee, protocolFeesAccrued[payoutToken]);
        }

        inv.status = InvoiceStatus.Refunded;
        protocolFeesAccrued[payoutToken] -= p.fee;
        delete payments[globalId];

        // Pull payout from merchant → forward to payer.
        IERC20(payoutToken).safeTransferFrom(merchant, refundTo, p.merchantPayout);
        if (p.fee > 0) {
            IERC20(payoutToken).safeTransfer(merchant, p.fee);
        }

        emit InvoiceRefunded(globalId, refundTo, payoutToken, p.merchantPayout, p.fee);
    }

    /// @dev Inverts the pool's forward swap quote to find the smallest input
    /// that produces at least `amountOut`. Strategy:
    ///   1. Linear-inverse seed (`lo`): cheap but can undershoot by tens of
    ///      wei when the gradient is sub-1 (cheap-stable → expensive-stable).
    ///   2. Doubling: grow `hi` by powers of two until quote(hi) ≥ amountOut.
    ///   3. Bisection: narrow [lo, hi] to the smallest passing input.
    /// If quote() is monotone (it is: gross is linear in amountIn, fee is a
    /// constant fraction of gross), the returned `amountIn` is the optimum.
    /// If liquidity or oracle config makes the swap unreachable we return
    /// `type(uint256).max` so the slippage check at the call site rejects.
    function _estimateAmountIn(address tokenIn, address tokenOut, uint256 amountOut)
        internal
        view
        returns (uint256 amountIn)
    {
        uint8 decIn = REGISTRY.tokenInfo(tokenIn).decimals;
        uint256 probeIn  = 10 ** decIn;
        uint256 probeOut = POOL.quote(tokenIn, tokenOut, probeIn);
        if (probeOut == 0) return type(uint256).max;

        uint256 lo = (amountOut * probeIn + probeOut - 1) / probeOut;
        if (POOL.quote(tokenIn, tokenOut, lo) >= amountOut) return lo;

        uint256 hi = lo + 1;
        bool bracketed = false;
        for (uint256 i = 0; i < ESTIMATE_MAX_DOUBLES; i++) {
            if (POOL.quote(tokenIn, tokenOut, hi) >= amountOut) { bracketed = true; break; }
            uint256 gap = hi - lo;
            // Cap at uint256 max to avoid overflow on degenerate pools.
            if (gap > type(uint256).max / 2) return type(uint256).max;
            hi = lo + gap * 2;
        }
        if (!bracketed) return type(uint256).max;

        for (uint256 i = 0; i < ESTIMATE_MAX_BISECTS && hi - lo > 1; i++) {
            uint256 mid = lo + (hi - lo) / 2;
            if (POOL.quote(tokenIn, tokenOut, mid) >= amountOut) {
                hi = mid;
            } else {
                lo = mid;
            }
        }
        amountIn = hi;
    }

    function withdrawFees(address token, address to) external onlyOwner {
        uint256 amount = protocolFeesAccrued[token];
        protocolFeesAccrued[token] = 0;
        IERC20(token).safeTransfer(to, amount);
        emit FeesWithdrawn(token, to, amount);
    }

    // ── Delegate authorization ─────────────────────────────────────────

    function authorizeDelegate(address delegate, uint64 expiresAt) external {
        if (!merchants[msg.sender].active) revert NotMerchant();
        delegateAuthorizations[msg.sender][delegate] = expiresAt;
        emit DelegateAuthorized(msg.sender, delegate, expiresAt);
    }

    function revokeDelegate(address delegate) external {
        delegateAuthorizations[msg.sender][delegate] = 0;
        emit DelegateRevoked(msg.sender, delegate);
    }
}
