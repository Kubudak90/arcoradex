// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable }           from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }      from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IStablePool }           from "./IStablePool.sol";
import { IStablecoinRegistry }   from "../registry/IStablecoinRegistry.sol";

/// @title StablePool
/// @notice Singleton oracle-priced shared-vault stablecoin pool.
/// @dev No pairs, no curve. `reserves[token]` per-token; swap rate = price[in] / price[out].
contract StablePool is IStablePool, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 internal constant MAX_SWAP_FEE_BPS = 50;

    IStablecoinRegistry public immutable REGISTRY;

    mapping(address token => uint256) public override reserves;
    mapping(address token => uint256) public override protocolFeesAccrued;

    /// @notice Per-token last accepted oracle price (1e18 scaled). 0 means never observed.
    mapping(address token => uint256) public lastAcceptedPrice;

    uint16 public override swapFeeBps;
    bool   public override paused;

    constructor(address registry, uint16 initialSwapFeeBps, address initialOwner) Ownable(initialOwner) {
        REGISTRY = IStablecoinRegistry(registry);
        if (initialSwapFeeBps > MAX_SWAP_FEE_BPS) revert InvalidFeeBps(initialSwapFeeBps);
        swapFeeBps = initialSwapFeeBps;
    }

    // ── modifiers ─────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (paused) revert PoolPaused();
        _;
    }

    // ── owner: liquidity ──────────────────────────────────────────────

    function deposit(address token, uint256 amount) external override onlyOwner whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!REGISTRY.isActive(token)) revert TokenNotActive(token);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        reserves[token] += amount;
        emit LiquidityDeposited(token, amount, reserves[token]);
    }

    function withdraw(address token, uint256 amount, address to) external override onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 r = reserves[token];
        if (amount > r) revert InsufficientLiquidity(token, amount, r);
        reserves[token] = r - amount;
        IERC20(token).safeTransfer(to, amount);
        emit LiquidityWithdrawn(token, amount, reserves[token]);
    }

    function withdrawProtocolFees(address token, uint256 amount, address to) external override onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 accrued = protocolFeesAccrued[token];
        if (amount > accrued) revert InsufficientLiquidity(token, amount, accrued);
        protocolFeesAccrued[token] = accrued - amount;
        IERC20(token).safeTransfer(to, amount);
    }

    function syncAcceptedPrice(address token) external override onlyOwner returns (uint256 price1e18) {
        (price1e18,,) = _readUsdPrice1e18(token);
        lastAcceptedPrice[token] = price1e18;
    }

    // ── owner: parameters ────────────────────────────────────────────

    function setSwapFeeBps(uint16 newBps) external override onlyOwner {
        if (newBps > MAX_SWAP_FEE_BPS) revert InvalidFeeBps(newBps);
        emit SwapFeeUpdated(swapFeeBps, newBps);
        swapFeeBps = newBps;
    }

    function pause() external override onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ── pricing helpers ──────────────────────────────────────────────

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_STALE_SECONDS = 1 hours;

    /// @dev Reads `tokenInfo` and the oracle, returns 1e18-scaled USD price + token decimals + deviation cap.
    function _readUsdPrice1e18(address token)
        internal
        view
        returns (uint256 price1e18, uint8 tokenDecimals, uint16 maxDevBps)
    {
        IStablecoinRegistry.TokenInfo memory info = REGISTRY.tokenInfo(token);
        if (!info.isActive) revert TokenNotActive(token);
        tokenDecimals = info.decimals;
        maxDevBps     = info.maxOracleDeviationBps;
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            info.usdOracle.latestRoundData();
        if (roundId == 0 || answeredInRound < roundId) {
            revert InvalidOracleRound(token, roundId, answeredInRound);
        }
        if (answer <= 0) revert PriceDeviation(token, 0, 0, maxDevBps);
        if (updatedAt == 0 || updatedAt > block.timestamp) revert InvalidOracleTimestamp(token, updatedAt);
        if (block.timestamp - updatedAt > MAX_STALE_SECONDS) {
            revert PriceDeviation(token, uint256(answer), updatedAt, maxDevBps);
        }
        uint8 oracleDec = info.usdOracle.decimals();
        if (oracleDec == 18)      price1e18 = uint256(answer);
        else if (oracleDec < 18)  price1e18 = uint256(answer) * (10 ** (18 - oracleDec));
        else                      price1e18 = uint256(answer) / (10 ** (oracleDec - 18));
    }

    /// @dev Stateful: reads oracle, runs PriceGuard against last accepted, updates last accepted.
    function _readAndGuardPrice(address token)
        internal
        returns (uint256 price1e18, uint8 tokenDecimals)
    {
        uint16 maxDevBps;
        (price1e18, tokenDecimals, maxDevBps) = _readUsdPrice1e18(token);
        uint256 prev = lastAcceptedPrice[token];
        if (prev != 0) {
            uint256 diff = price1e18 > prev ? price1e18 - prev : prev - price1e18;
            if (diff * BPS > prev * maxDevBps) {
                revert PriceDeviation(token, price1e18, prev, maxDevBps);
            }
        }
        lastAcceptedPrice[token] = price1e18;
    }

    /// @dev Pure conversion: amountIn * priceIn / priceOut, scaled across decimals.
    function _grossOut(
        uint256 amountIn,
        uint256 priceIn1e18,
        uint256 priceOut1e18,
        uint8   decimalsIn,
        uint8   decimalsOut
    ) internal pure returns (uint256) {
        uint256 usdValue1e18 = (amountIn * priceIn1e18) / (10 ** decimalsIn);
        return (usdValue1e18 * (10 ** decimalsOut)) / priceOut1e18;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        override
        returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut) revert SameToken(tokenIn);
        if (amountIn == 0)       revert ZeroAmount();

        (uint256 pIn,  uint8 dIn,  ) = _readUsdPrice1e18(tokenIn);
        (uint256 pOut, uint8 dOut, ) = _readUsdPrice1e18(tokenOut);

        uint256 gross = _grossOut(amountIn, pIn, pOut, dIn, dOut);
        amountOut     = gross - (gross * swapFeeBps) / BPS;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external override whenNotPaused nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (tokenIn == tokenOut)        revert SameToken(tokenIn);
        if (amountIn == 0)              revert ZeroAmount();

        uint256 gross;
        uint256 fee;
        {
            (uint256 pIn,  uint8 dIn) = _readAndGuardPrice(tokenIn);
            (uint256 pOut, uint8 dOut) = _readAndGuardPrice(tokenOut);
            gross = _grossOut(amountIn, pIn, pOut, dIn, dOut);
            fee   = (gross * swapFeeBps) / BPS;
            amountOut = gross - fee;
        }

        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        uint256 outReserve = reserves[tokenOut];
        if (gross > outReserve) revert InsufficientLiquidity(tokenOut, gross, outReserve);

        // CEI: pull-in, update reserves, push-out.
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        reserves[tokenIn]  = reserves[tokenIn] + amountIn;
        reserves[tokenOut] = outReserve - gross;
        protocolFeesAccrued[tokenOut] += fee;

        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, fee, recipient);
    }
}
