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
    uint256 public  constant MAX_STALE_SECONDS             = 1 hours;
    uint256 internal constant BPS                          = 10_000;
    address public  constant DEAD_ADDRESS                  = address(0xdead);

    // ── Immutables ───────────────────────────────────────────────────
    IArcoraDexRegistry public immutable override REGISTRY;
    IArcoraDexLP       public immutable override LP;

    // ── Storage ──────────────────────────────────────────────────────
    mapping(address token => uint256) public override reserves;
    mapping(address token => uint256) public override protocolFeesAccrued;
    mapping(address token => uint256) public override lastAcceptedPrice;
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

    // ── Pricing helpers (PriceGuard added in T11) ────────────────────
    /// @dev Reads the oracle once and returns 1e18-scaled USD price.
    /// PriceGuard / staleness logic ships in T11 (replaces this helper).
    function _readUsdPrice1e18(address token)
        internal
        view
        returns (uint256 price1e18, uint8 tokenDecimals)
    {
        IArcoraDexRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        if (!info.isActive) revert TokenNotActive(token);
        tokenDecimals = info.decimals;
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            info.usdOracle.latestRoundData();
        if (roundId == 0 || answeredInRound < roundId) {
            revert InvalidOracleRound(token, roundId, answeredInRound);
        }
        if (answer <= 0) revert PriceDeviation(token, 0, 0, info.maxOracleDeviationBps);
        if (updatedAt == 0 || updatedAt > block.timestamp) revert InvalidOracleTimestamp(token, updatedAt);
        if (block.timestamp - updatedAt > MAX_STALE_SECONDS) {
            revert PriceDeviation(token, uint256(answer), updatedAt, info.maxOracleDeviationBps);
        }
        uint8 oracleDec = info.usdOracle.decimals();
        if (oracleDec == 18)      price1e18 = uint256(answer);
        else if (oracleDec < 18)  price1e18 = uint256(answer) * (10 ** (18 - oracleDec));
        else                      price1e18 = uint256(answer) / (10 ** (oracleDec - 18));
    }

    function totalReservesUSD() public view override returns (uint256 navE18) {
        uint256 n = REGISTRY.tokensLength();
        for (uint256 i = 0; i < n; i++) {
            address t = REGISTRY.tokens(i);
            if (!REGISTRY.isActive(t)) continue;
            (uint256 p, uint8 d) = _readUsdPrice1e18(t);
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
        (uint256 priceIn, uint8 dIn) = _readUsdPrice1e18(token);
        uint256 usdIn = (amount * priceIn) / (10 ** dIn);

        uint256 supply  = LP.totalSupply();
        uint256 navBefore;
        if (supply == 0) {
            if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
            lpMinted  = usdIn - MINIMUM_LIQUIDITY;
            navBefore = 0;
        } else {
            navBefore = totalReservesUSD();
            lpMinted  = (usdIn * supply) / navBefore;
        }
        if (lpMinted < minLpOut) revert InsufficientLpOut(lpMinted, minLpOut);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        reserves[token] += amount;

        if (supply == 0) {
            LP.mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
        }
        LP.mint(msg.sender, lpMinted);

        emit Deposited(msg.sender, token, amount, lpMinted, navBefore, navBefore + usdIn);
    }

    function withdraw(
        address tokenOut,
        uint256 lpAmount,
        uint256 minTokenOut,
        uint256 deadline
    ) external override whenNotPaused nonReentrant checkDeadline(deadline) returns (uint256 amountOut) {
        if (lpAmount == 0) revert ZeroAmount();

        uint256 navBefore = totalReservesUSD();
        uint256 usdRedeemed = (lpAmount * navBefore) / LP.totalSupply();

        uint256 protFeeAmt;
        {
            (uint256 priceOut, uint8 dOut) = _readUsdPrice1e18(tokenOut);
            uint256 usdNet     = (usdRedeemed * (BPS - swapFeeBps)) / BPS;
            uint256 protFeeUsd = ((usdRedeemed - usdNet) * protocolFeeShareBps) / BPS;
            uint256 scale      = 10 ** dOut;
            amountOut  = (usdNet * scale) / priceOut;
            protFeeAmt = (protFeeUsd * scale) / priceOut;
        }

        uint256 r = reserves[tokenOut];
        if (r < amountOut + protFeeAmt) revert InsufficientLiquidity(tokenOut, amountOut + protFeeAmt, r);
        if (amountOut < minTokenOut) revert InsufficientTokenOut(amountOut, minTokenOut);

        LP.burn(msg.sender, lpAmount);
        reserves[tokenOut] = r - (amountOut + protFeeAmt);
        protocolFeesAccrued[tokenOut] += protFeeAmt;

        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit Withdrew(msg.sender, tokenOut, lpAmount, amountOut, protFeeAmt, navBefore, navBefore - usdRedeemed);
    }

    // ── swap (stub; implemented in T10) ──────────────────────────────
    function swap(
        address /*tokenIn*/,
        address /*tokenOut*/,
        uint256 /*amountIn*/,
        uint256 /*minOut*/,
        uint256 /*deadline*/,
        address /*recipient*/
    ) external override whenNotPaused nonReentrant returns (uint256) {
        // Implemented in T10.
        revert("swap: not implemented (T10)");
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
        (uint256 pIn,  uint8 dIn ) = _readUsdPrice1e18(tokenIn);
        (uint256 pOut, uint8 dOut) = _readUsdPrice1e18(tokenOut);
        uint256 gross = _grossOut(amountIn, pIn, pOut, dIn, dOut);
        amountOut     = gross - (gross * swapFeeBps) / BPS;
    }

    function quoteDeposit(address token, uint256 amount)
        external view override returns (uint256 lpOut)
    {
        if (amount == 0) revert ZeroAmount();
        (uint256 pIn, uint8 dIn) = _readUsdPrice1e18(token);
        uint256 usdIn  = (amount * pIn) / (10 ** dIn);
        uint256 supply = LP.totalSupply();
        if (supply == 0) {
            if (usdIn <= MINIMUM_LIQUIDITY) revert FirstDepositTooSmall(usdIn, MINIMUM_LIQUIDITY);
            lpOut = usdIn - MINIMUM_LIQUIDITY;
        } else {
            uint256 nav = totalReservesUSD();
            lpOut = (usdIn * supply) / nav;
        }
    }

    function quoteWithdraw(address tokenOut, uint256 lpAmount)
        external view override returns (uint256 amountOut, uint256 protocolFee)
    {
        if (lpAmount == 0) revert ZeroAmount();
        (uint256 pOut, uint8 dOut) = _readUsdPrice1e18(tokenOut);
        {
            uint256 supply      = LP.totalSupply();
            uint256 navBefore   = totalReservesUSD();
            uint256 usdRedeemed = (lpAmount * navBefore) / supply;
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

    function syncAcceptedPrice(address /*token*/) external override onlyOwner returns (uint256) {
        // Implemented in T11 alongside PriceGuard.
        revert("syncAcceptedPrice: not implemented (T11)");
    }
}
