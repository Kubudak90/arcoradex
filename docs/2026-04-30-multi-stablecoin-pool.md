# Multi-Stablecoin Shared-Vault Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two-token `OracleAMM` (USDC/EURC) with a singleton shared-vault `StablePool` that swaps any active stable to any other active stable using per-token Chainlink-shape USD oracles, and refactor `ArcFXGateway` to v0.7 to route through it. Day-one supports 7 stables: USDC, USDT, PYUSD, DAI, EURC, TRYC, BRLC.

**Architecture:** Three contracts — `StablecoinRegistry` (Ownable2Step token + oracle metadata), `StablePool` (Ownable2Step + Pausable shared vault, oracle-priced atomic swaps, per-token PriceGuard), `ArcFXGateway v0.7` (token-agnostic, routes through pool for cross-stable, preserves same-token branch and v0.5 1-wei estimator). Single LP (us). No LP tokens. No pairs.

**Tech Stack:** Solidity 0.8.26, Foundry, OpenZeppelin v5 (Ownable2Step, Pausable, SafeERC20, ReentrancyGuard), existing `IChainlinkAggregator` interface, existing `MockChainlinkFeed` (testnet), CoinGecko free API (off-chain keeper).

**Spec reference:** `docs/superpowers/specs/2026-04-29-plan-3-multi-stablecoin.md` (rev2, 2026-04-30).

---

## File Structure

### New files
- `packages/contracts/src/registry/IStablecoinRegistry.sol` — interface for the registry (used by pool + gateway).
- `packages/contracts/src/registry/StablecoinRegistry.sol` — `TokenInfo` storage, owner-gated mutations, Ownable2Step.
- `packages/contracts/src/pool/IStablePool.sol` — interface for the shared vault.
- `packages/contracts/src/pool/StablePool.sol` — shared vault with `reserves[token]`, oracle-priced swap, per-token PriceGuard, Pausable, Ownable2Step.
- `packages/contracts/src/testnet/MintableERC20.sol` — production-deployable testnet stablecoin mock (owner-mintable). Replaces inlining the test helper for the deploy script.
- `packages/contracts/test/StablecoinRegistry.t.sol` — registry tests.
- `packages/contracts/test/StablePool.t.sol` — pool tests.
- `packages/contracts/script/DeployV07.s.sol` — single-shot deployer: registry → pool → 6 mock tokens → 6 mock feeds → gateway → registry listings → pool seeding.
- `ops/keepalive/multi-feed-push.ts` — Node script that fetches 6 prices from CoinGecko and pushes to mock feeds. Replaces the EUR-only keeper.

### Modified files
- `packages/contracts/src/ArcFXGateway.sol` — remove `USDC`, `EURC`, `USDC_INDEX`, `EURC_INDEX` immutables; add `POOL` (now `IStablePool`) + `REGISTRY`; route `pay()` through `pool.swap()`; preserve same-token branch verbatim; generalize `_estimateAmountIn` over decimals via registry. Bump version comment to `v0.7.0`.
- `packages/contracts/test/ArcFXGateway.t.sol` — replace `MockStableSwapPool` setup with `StablecoinRegistry + StablePool + 7 mock tokens + 7 mock feeds`. Existing tests stay; constructor args change.
- `packages/contracts/test/ArcFXGateway.fuzz.t.sol` — same setup migration.
- `packages/contracts/test/ArcFXGateway.invariant.t.sol` — same setup migration.
- `packages/contracts/test/handlers/GatewayHandler.sol` — same setup migration.
- `ops/keepalive/` (existing systemd unit + .env) — point at new keeper script.

### Files NOT touched in this plan
- `packages/app/**` — UI/api integration is a follow-up plan.
- `packages/sdk/**` — SDK token enumeration is a follow-up plan.
- `packages/contracts/src/pool/OracleAMM.sol` — kept on disk as rollback reference. Not deleted, not deployed by v0.7 script.
- `packages/contracts/src/pool/{StableSwap,SwapUtils,MathUtils,LPToken,AmplificationUtils}.sol` — unused by v0.7. Left untouched.

---

## Task 1: StablecoinRegistry interface

**Files:**
- Create: `packages/contracts/src/registry/IStablecoinRegistry.sol`

- [ ] **Step 1: Create the interface file**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IChainlinkAggregator } from "../interfaces/IChainlinkAggregator.sol";

/// @title IStablecoinRegistry
/// @notice Per-token metadata + USD oracle catalogue for the shared-vault StablePool.
interface IStablecoinRegistry {
    struct TokenInfo {
        uint8                decimals;
        bool                 isActive;
        IChainlinkAggregator usdOracle;             // USD-quoted, Chainlink-shape
        uint16               maxOracleDeviationBps; // PriceGuard tolerance, per-token
    }

    event TokenListed(address indexed token, uint8 decimals, address usdOracle, uint16 maxOracleDeviationBps);
    event TokenDeactivated(address indexed token);
    event TokenReactivated(address indexed token);
    event OracleUpdated(address indexed token, address oldOracle, address newOracle);
    event DeviationUpdated(address indexed token, uint16 oldBps, uint16 newBps);

    error TokenAlreadyListed(address token);
    error TokenNotListed(address token);
    error InvalidDecimals(uint8 decimals);
    error InvalidDeviation(uint16 bps);
    error ZeroAddress();

    function tokenInfo(address token) external view returns (TokenInfo memory);
    function isActive(address token) external view returns (bool);
    function tokens(uint256 index) external view returns (address);
    function tokensLength() external view returns (uint256);
    function listToken(address token, uint8 decimals_, IChainlinkAggregator oracle, uint16 maxDeviationBps) external;
    function deactivateToken(address token) external;
    function reactivateToken(address token) external;
    function setOracle(address token, IChainlinkAggregator oracle) external;
    function setDeviation(address token, uint16 maxDeviationBps) external;
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd packages/contracts && forge build`
Expected: PASS (only the interface added; no impl yet, no other contracts reference it).

- [ ] **Step 3: Commit**

```bash
git add packages/contracts/src/registry/IStablecoinRegistry.sol
git commit -m "feat(contracts): add IStablecoinRegistry interface for v0.7 multi-stable pool"
```

---

## Task 2: StablecoinRegistry — listing + Ownable2Step (TDD)

**Files:**
- Create: `packages/contracts/src/registry/StablecoinRegistry.sol`
- Test: `packages/contracts/test/StablecoinRegistry.t.sol`

- [ ] **Step 1: Write the failing test for token listing + ownership handshake**

Create `packages/contracts/test/StablecoinRegistry.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { StablecoinRegistry } from "../src/registry/StablecoinRegistry.sol";
import { IStablecoinRegistry } from "../src/registry/IStablecoinRegistry.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeed } from "../src/testnet/MockChainlinkFeed.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

contract StablecoinRegistryTest is Test {
    StablecoinRegistry  reg;
    MockERC20           usdc;
    MockChainlinkFeed   usdcFeed;
    address             owner = makeAddr("owner");
    address             newOwner = makeAddr("newOwner");
    address             stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_700_000_000);
        reg = new StablecoinRegistry(owner);
        usdc = new MockERC20("USDC", "USDC", 6);
        usdcFeed = new MockChainlinkFeed(8, 1.0000e8);
    }

    function test_ListToken_Success() public {
        vm.expectEmit(true, false, false, true, address(reg));
        emit IStablecoinRegistry.TokenListed(address(usdc), 6, address(usdcFeed), 50);
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);

        IStablecoinRegistry.TokenInfo memory info = reg.tokenInfo(address(usdc));
        assertEq(info.decimals, 6);
        assertTrue(info.isActive);
        assertEq(address(info.usdOracle), address(usdcFeed));
        assertEq(info.maxOracleDeviationBps, 50);
        assertEq(reg.tokens(0), address(usdc));
        assertEq(reg.tokensLength(), 1);
        assertTrue(reg.isActive(address(usdc)));
    }

    function test_ListToken_RevertsIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
    }

    function test_ListToken_RevertsOnDuplicate() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.TokenAlreadyListed.selector, address(usdc)));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
    }

    function test_ListToken_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IStablecoinRegistry.ZeroAddress.selector);
        reg.listToken(address(0), 6, IChainlinkAggregator(address(usdcFeed)), 50);
    }

    function test_ListToken_RevertsOnInvalidDecimals() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.InvalidDecimals.selector, 0));
        reg.listToken(address(usdc), 0, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.InvalidDecimals.selector, 30));
        reg.listToken(address(usdc), 30, IChainlinkAggregator(address(usdcFeed)), 50);
    }

    function test_ListToken_RevertsOnInvalidDeviation() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.InvalidDeviation.selector, 0));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.InvalidDeviation.selector, 10_001));
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 10_001);
    }

    function test_Ownable2Step_AcceptHandshake() public {
        vm.prank(owner);
        reg.transferOwnership(newOwner);
        // Pending — owner unchanged until accept
        assertEq(reg.owner(), owner);
        assertEq(reg.pendingOwner(), newOwner);
        // newOwner accepts
        vm.prank(newOwner);
        reg.acceptOwnership();
        assertEq(reg.owner(), newOwner);
        assertEq(reg.pendingOwner(), address(0));
    }
}
```

- [ ] **Step 2: Run tests, verify they fail (no impl)**

Run: `cd packages/contracts && forge test --match-contract StablecoinRegistryTest -vv`
Expected: FAIL — `StablecoinRegistry` does not exist.

- [ ] **Step 3: Implement StablecoinRegistry**

Create `packages/contracts/src/registry/StablecoinRegistry.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable }       from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }  from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IStablecoinRegistry }  from "./IStablecoinRegistry.sol";
import { IChainlinkAggregator } from "../interfaces/IChainlinkAggregator.sol";

/// @title StablecoinRegistry
/// @notice Per-token metadata + USD oracle catalogue for the shared-vault StablePool.
contract StablecoinRegistry is IStablecoinRegistry, Ownable2Step {
    mapping(address token => TokenInfo) internal _info;
    address[] public override tokens;

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ── External views ────────────────────────────────────────────────

    function tokenInfo(address token) external view override returns (TokenInfo memory) {
        return _info[token];
    }

    function isActive(address token) external view override returns (bool) {
        return _info[token].isActive;
    }

    function tokensLength() external view override returns (uint256) {
        return tokens.length;
    }

    // ── Mutations (owner-only) ────────────────────────────────────────

    function listToken(
        address token,
        uint8 decimals_,
        IChainlinkAggregator oracle,
        uint16 maxDeviationBps
    ) external override onlyOwner {
        if (token == address(0) || address(oracle) == address(0)) revert ZeroAddress();
        if (decimals_ == 0 || decimals_ > 18) revert InvalidDecimals(decimals_);
        if (maxDeviationBps == 0 || maxDeviationBps > 10_000) revert InvalidDeviation(maxDeviationBps);
        if (_info[token].usdOracle != IChainlinkAggregator(address(0))) revert TokenAlreadyListed(token);

        _info[token] = TokenInfo({
            decimals: decimals_,
            isActive: true,
            usdOracle: oracle,
            maxOracleDeviationBps: maxDeviationBps
        });
        tokens.push(token);
        emit TokenListed(token, decimals_, address(oracle), maxDeviationBps);
    }

    function deactivateToken(address token) external override onlyOwner {
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        info.isActive = false;
        emit TokenDeactivated(token);
    }

    function reactivateToken(address token) external override onlyOwner {
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        info.isActive = true;
        emit TokenReactivated(token);
    }

    function setOracle(address token, IChainlinkAggregator oracle) external override onlyOwner {
        if (address(oracle) == address(0)) revert ZeroAddress();
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        address oldOracle = address(info.usdOracle);
        info.usdOracle = oracle;
        emit OracleUpdated(token, oldOracle, address(oracle));
    }

    function setDeviation(address token, uint16 maxDeviationBps) external override onlyOwner {
        if (maxDeviationBps == 0 || maxDeviationBps > 10_000) revert InvalidDeviation(maxDeviationBps);
        TokenInfo storage info = _info[token];
        if (info.usdOracle == IChainlinkAggregator(address(0))) revert TokenNotListed(token);
        uint16 old = info.maxOracleDeviationBps;
        info.maxOracleDeviationBps = maxDeviationBps;
        emit DeviationUpdated(token, old, maxDeviationBps);
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd packages/contracts && forge test --match-contract StablecoinRegistryTest -vv`
Expected: PASS — all 7 test functions green.

- [ ] **Step 5: Commit**

```bash
git add packages/contracts/src/registry/StablecoinRegistry.sol packages/contracts/test/StablecoinRegistry.t.sol
git commit -m "feat(contracts): add StablecoinRegistry with Ownable2Step"
```

---

## Task 3: StablecoinRegistry — deactivate / reactivate / setOracle / setDeviation tests

**Files:**
- Modify: `packages/contracts/test/StablecoinRegistry.t.sol`

- [ ] **Step 1: Append tests for the remaining mutations**

Append to `packages/contracts/test/StablecoinRegistryTest`:

```solidity
    function test_Deactivate_Reactivate_Flow() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);

        vm.expectEmit(true, false, false, true, address(reg));
        emit IStablecoinRegistry.TokenDeactivated(address(usdc));
        vm.prank(owner);
        reg.deactivateToken(address(usdc));
        assertFalse(reg.isActive(address(usdc)));

        vm.expectEmit(true, false, false, true, address(reg));
        emit IStablecoinRegistry.TokenReactivated(address(usdc));
        vm.prank(owner);
        reg.reactivateToken(address(usdc));
        assertTrue(reg.isActive(address(usdc)));
    }

    function test_Deactivate_RevertsOnUnknownToken() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.TokenNotListed.selector, address(usdc)));
        reg.deactivateToken(address(usdc));
    }

    function test_SetOracle_Success() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);

        MockChainlinkFeed newFeed = new MockChainlinkFeed(8, 1.0001e8);
        vm.expectEmit(true, false, false, true, address(reg));
        emit IStablecoinRegistry.OracleUpdated(address(usdc), address(usdcFeed), address(newFeed));
        vm.prank(owner);
        reg.setOracle(address(usdc), IChainlinkAggregator(address(newFeed)));

        assertEq(address(reg.tokenInfo(address(usdc)).usdOracle), address(newFeed));
    }

    function test_SetOracle_RevertsOnZero() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.prank(owner);
        vm.expectRevert(IStablecoinRegistry.ZeroAddress.selector);
        reg.setOracle(address(usdc), IChainlinkAggregator(address(0)));
    }

    function test_SetDeviation_Success() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.expectEmit(true, false, false, true, address(reg));
        emit IStablecoinRegistry.DeviationUpdated(address(usdc), 50, 150);
        vm.prank(owner);
        reg.setDeviation(address(usdc), 150);
        assertEq(reg.tokenInfo(address(usdc)).maxOracleDeviationBps, 150);
    }

    function test_SetDeviation_RevertsOnInvalid() public {
        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablecoinRegistry.InvalidDeviation.selector, 0));
        reg.setDeviation(address(usdc), 0);
    }

    function test_TokensArray_OrderPreserved() public {
        MockERC20 eurc = new MockERC20("EURC", "EURC", 6);
        MockChainlinkFeed eurFeed = new MockChainlinkFeed(8, 1.0863e8);

        vm.prank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        vm.prank(owner);
        reg.listToken(address(eurc), 6, IChainlinkAggregator(address(eurFeed)), 150);

        assertEq(reg.tokensLength(), 2);
        assertEq(reg.tokens(0), address(usdc));
        assertEq(reg.tokens(1), address(eurc));
    }
```

- [ ] **Step 2: Run tests, verify pass**

Run: `cd packages/contracts && forge test --match-contract StablecoinRegistryTest -vv`
Expected: PASS — 13 test functions total.

- [ ] **Step 3: Commit**

```bash
git add packages/contracts/test/StablecoinRegistry.t.sol
git commit -m "test(contracts): cover deactivate/setOracle/setDeviation + array order"
```

---

## Task 4: StablePool interface

**Files:**
- Create: `packages/contracts/src/pool/IStablePool.sol`

- [ ] **Step 1: Create the interface**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStablePool
/// @notice Singleton oracle-priced shared-vault stablecoin pool.
interface IStablePool {
    event LiquidityDeposited(address indexed token, uint256 amount, uint256 newReserve);
    event LiquidityWithdrawn(address indexed token, uint256 amount, uint256 newReserve);
    event Swapped(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        address recipient
    );
    event SwapFeeUpdated(uint16 oldBps, uint16 newBps);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error TokenNotActive(address token);
    error SameToken(address token);
    error ZeroAmount();
    error DeadlinePassed();
    error InsufficientLiquidity(address token, uint256 requested, uint256 available);
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    error PriceDeviation(address token, uint256 newPrice, uint256 lastAccepted, uint16 maxBps);
    error InvalidFeeBps(uint16 bps);
    error PoolPaused();

    function reserves(address token) external view returns (uint256);
    function protocolFeesAccrued(address token) external view returns (uint256);
    function swapFeeBps() external view returns (uint16);
    function paused() external view returns (bool);

    function deposit(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount, address to) external;
    function withdrawProtocolFees(address token, uint256 amount, address to) external;

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external returns (uint256 amountOut);

    function setSwapFeeBps(uint16 newBps) external;
    function pause() external;
    function unpause() external;
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd packages/contracts && forge build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add packages/contracts/src/pool/IStablePool.sol
git commit -m "feat(contracts): add IStablePool interface"
```

---

## Task 5: StablePool — deposit / withdraw / pause skeleton (TDD)

**Files:**
- Create: `packages/contracts/src/pool/StablePool.sol`
- Test: `packages/contracts/test/StablePool.t.sol`

- [ ] **Step 1: Write the failing tests**

Create `packages/contracts/test/StablePool.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { StablecoinRegistry } from "../src/registry/StablecoinRegistry.sol";
import { StablePool }         from "../src/pool/StablePool.sol";
import { IStablePool }        from "../src/pool/IStablePool.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeed }    from "../src/testnet/MockChainlinkFeed.sol";
import { MockERC20 }            from "./helpers/MockERC20.sol";

contract StablePoolTest is Test {
    StablecoinRegistry  reg;
    StablePool          pool;
    MockERC20           usdc;
    MockERC20           eurc;
    MockERC20           dai;       // 18 decimals
    MockChainlinkFeed   usdcFeed;
    MockChainlinkFeed   eurcFeed;
    MockChainlinkFeed   daiFeed;

    address owner    = makeAddr("owner");
    address customer = makeAddr("customer");

    uint16 constant DEFAULT_FEE_BPS = 5;
    uint16 constant TIGHT_DEV_BPS   = 50;
    uint16 constant FX_DEV_BPS      = 150;

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        reg = new StablecoinRegistry(owner);
        pool = new StablePool(address(reg), DEFAULT_FEE_BPS, owner);

        usdc     = new MockERC20("USDC", "USDC", 6);
        eurc     = new MockERC20("EURC", "EURC", 6);
        dai      = new MockERC20("DAI",  "DAI",  18);
        usdcFeed = new MockChainlinkFeed(8, 1.0000e8);
        eurcFeed = new MockChainlinkFeed(8, 1.0863e8);
        daiFeed  = new MockChainlinkFeed(8, 1.0000e8);

        vm.startPrank(owner);
        reg.listToken(address(usdc), 6,  IChainlinkAggregator(address(usdcFeed)), TIGHT_DEV_BPS);
        reg.listToken(address(eurc), 6,  IChainlinkAggregator(address(eurcFeed)), FX_DEV_BPS);
        reg.listToken(address(dai),  18, IChainlinkAggregator(address(daiFeed)),  TIGHT_DEV_BPS);
        vm.stopPrank();
    }

    function _seed(address token, uint256 amount) internal {
        MockERC20(token).mint(owner, amount);
        vm.startPrank(owner);
        IERC20(token).approve(address(pool), amount);
        pool.deposit(token, amount);
        vm.stopPrank();
    }

    // ── deposit / withdraw ───────────────────────────────────────────

    function test_Deposit_PullsTokens_AndUpdatesReserve() public {
        usdc.mint(owner, 1_000e6);
        vm.startPrank(owner);
        usdc.approve(address(pool), 1_000e6);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IStablePool.LiquidityDeposited(address(usdc), 1_000e6, 1_000e6);
        pool.deposit(address(usdc), 1_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(pool)), 1_000e6);
        assertEq(pool.reserves(address(usdc)), 1_000e6);
    }

    function test_Deposit_RevertsIfNotOwner() public {
        usdc.mint(customer, 1_000e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(); // OZ Ownable
        pool.deposit(address(usdc), 1_000e6);
        vm.stopPrank();
    }

    function test_Deposit_RevertsOnInactiveToken() public {
        MockERC20 other = new MockERC20("X", "X", 6);
        other.mint(owner, 1_000e6);
        vm.startPrank(owner);
        other.approve(address(pool), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IStablePool.TokenNotActive.selector, address(other)));
        pool.deposit(address(other), 1_000e6);
        vm.stopPrank();
    }

    function test_Withdraw_TransfersOut_AndUpdatesReserve() public {
        _seed(address(usdc), 1_000e6);
        vm.expectEmit(true, false, false, true, address(pool));
        emit IStablePool.LiquidityWithdrawn(address(usdc), 400e6, 600e6);
        vm.prank(owner);
        pool.withdraw(address(usdc), 400e6, owner);
        assertEq(pool.reserves(address(usdc)), 600e6);
        assertEq(usdc.balanceOf(owner), 400e6);
    }

    function test_Withdraw_RevertsOnInsufficientReserve() public {
        _seed(address(usdc), 100e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablePool.InsufficientLiquidity.selector, address(usdc), 200e6, 100e6));
        pool.withdraw(address(usdc), 200e6, owner);
    }

    // ── pause / unpause ──────────────────────────────────────────────

    function test_Pause_BlocksDeposit_AllowsWithdraw() public {
        _seed(address(usdc), 1_000e6);
        vm.prank(owner);
        pool.pause();

        usdc.mint(owner, 100e6);
        vm.startPrank(owner);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(IStablePool.PoolPaused.selector);
        pool.deposit(address(usdc), 100e6);

        // withdraw still works (unwinding path)
        pool.withdraw(address(usdc), 200e6, owner);
        vm.stopPrank();
        assertEq(pool.reserves(address(usdc)), 800e6);
    }

    function test_Pause_RevertsIfNotOwner() public {
        vm.prank(customer);
        vm.expectRevert();
        pool.pause();
    }

    function test_Unpause_RestoresDeposits() public {
        vm.prank(owner);
        pool.pause();
        vm.prank(owner);
        pool.unpause();
        usdc.mint(owner, 100e6);
        vm.startPrank(owner);
        usdc.approve(address(pool), 100e6);
        pool.deposit(address(usdc), 100e6);
        vm.stopPrank();
        assertEq(pool.reserves(address(usdc)), 100e6);
    }

    // ── fee setter ────────────────────────────────────────────────────

    function test_SetSwapFee_Success() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit IStablePool.SwapFeeUpdated(DEFAULT_FEE_BPS, 30);
        vm.prank(owner);
        pool.setSwapFeeBps(30);
        assertEq(pool.swapFeeBps(), 30);
    }

    function test_SetSwapFee_RevertsAbove50() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStablePool.InvalidFeeBps.selector, 51));
        pool.setSwapFeeBps(51);
    }
}
```

- [ ] **Step 2: Run tests, verify they fail (no impl)**

Run: `cd packages/contracts && forge test --match-contract StablePoolTest -vv`
Expected: FAIL — `StablePool` does not exist.

- [ ] **Step 3: Implement StablePool skeleton (deposit/withdraw/pause/fee setter — no swap yet)**

Create `packages/contracts/src/pool/StablePool.sol`:

```solidity
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

    // ── swap / quote — STUBS (filled in next tasks) ──────────────────

    function quote(address, address, uint256) external pure override returns (uint256) {
        revert("not implemented");
    }

    function swap(address, address, uint256, uint256, uint256, address) external override returns (uint256) {
        revert("not implemented");
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd packages/contracts && forge test --match-contract StablePoolTest -vv`
Expected: PASS — 11 test functions green.

- [ ] **Step 5: Commit**

```bash
git add packages/contracts/src/pool/StablePool.sol packages/contracts/test/StablePool.t.sol
git commit -m "feat(contracts): StablePool deposit/withdraw/pause skeleton"
```

---

## Task 6: StablePool — quote (read-only swap math) with cross-decimal

**Files:**
- Modify: `packages/contracts/src/pool/StablePool.sol`
- Modify: `packages/contracts/test/StablePool.t.sol`

- [ ] **Step 1: Write failing quote tests**

Append to `StablePoolTest`:

```solidity
    // ── quote ─────────────────────────────────────────────────────────

    function test_Quote_USDCtoEURC_AppliesFee() public {
        // 1.0 USDC -> ? EURC. usdcUsd=1.0000, eurcUsd=1.0863, fee=5bps.
        // gross = 1e6 * 1.0000 / 1.0863 ≈ 920_555 (in EURC 6dec)
        // net   = gross * 9_995 / 10_000
        uint256 q = pool.quote(address(usdc), address(eurc), 1_000_000);
        // Expected: 1e6 * 1e8 / 1.0863e8 = 920_555 (truncated), then * 9995/10000 = 920_094
        assertApproxEqAbs(q, 920_094, 2);
    }

    function test_Quote_EURCtoUSDC_AppliesFee() public {
        // 1.0 EURC -> ? USDC. gross = 1e6 * 1.0863 / 1.0000 = 1_086_300
        // net = 1_086_300 * 9_995 / 10_000 = 1_085_756
        uint256 q = pool.quote(address(eurc), address(usdc), 1_000_000);
        assertApproxEqAbs(q, 1_085_756, 2);
    }

    function test_Quote_USDCtoDAI_CrossDecimal_6to18() public {
        // 1.0 USDC (6dec) -> ? DAI (18dec). Both peg=1.
        // amountOutGross = 1e6 * 1.0e8 / 1.0e8 * 10^(18-6) = 1e18
        // net = 1e18 * 9_995/10_000 = 9.995e17
        uint256 q = pool.quote(address(usdc), address(dai), 1_000_000);
        assertEq(q, 999_500_000_000_000_000); // 0.9995 DAI
    }

    function test_Quote_DAItoUSDC_CrossDecimal_18to6() public {
        // 1.0 DAI (18dec) -> ? USDC (6dec). Both peg=1.
        // gross = 1e18 * 1e8 / 1e8 / 10^12 = 1e6
        // net   = 1e6 * 9_995/10_000 = 999_500
        uint256 q = pool.quote(address(dai), address(usdc), 1e18);
        assertEq(q, 999_500);
    }

    function test_Quote_RevertsOnInactiveToken() public {
        vm.prank(owner);
        reg.deactivateToken(address(eurc));
        vm.expectRevert(abi.encodeWithSelector(IStablePool.TokenNotActive.selector, address(eurc)));
        pool.quote(address(usdc), address(eurc), 1e6);
    }

    function test_Quote_RevertsOnSameToken() public {
        vm.expectRevert(abi.encodeWithSelector(IStablePool.SameToken.selector, address(usdc)));
        pool.quote(address(usdc), address(usdc), 1e6);
    }

    function test_Quote_RevertsOnZeroAmount() public {
        vm.expectRevert(IStablePool.ZeroAmount.selector);
        pool.quote(address(usdc), address(eurc), 0);
    }
```

- [ ] **Step 2: Run, verify they fail with "not implemented"**

Run: `cd packages/contracts && forge test --match-contract StablePoolTest --match-test test_Quote -vv`
Expected: FAIL — revert "not implemented".

- [ ] **Step 3: Implement quote()**

Replace the `quote` stub in `StablePool.sol` with:

```solidity
    // ── pricing helpers ──────────────────────────────────────────────

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_STALE_SECONDS = 1 hours;

    /// @dev Reads `tokenInfo` and the oracle, returns 1e18-scaled USD price.
    function _readUsdPrice1e18(address token)
        internal
        view
        returns (uint256 price1e18, IStablecoinRegistry.TokenInfo memory info)
    {
        info = REGISTRY.tokenInfo(token);
        if (!info.isActive) revert TokenNotActive(token);
        (, int256 answer, , uint256 updatedAt, ) = info.usdOracle.latestRoundData();
        if (answer <= 0) revert PriceDeviation(token, 0, 0, info.maxOracleDeviationBps);
        if (block.timestamp - updatedAt > MAX_STALE_SECONDS) {
            revert PriceDeviation(token, uint256(answer), updatedAt, info.maxOracleDeviationBps);
        }
        uint8 dec = info.usdOracle.decimals();
        if (dec == 18)      price1e18 = uint256(answer);
        else if (dec < 18)  price1e18 = uint256(answer) * (10 ** (18 - dec));
        else                price1e18 = uint256(answer) / (10 ** (dec - 18));
    }

    /// @dev Pure conversion: amountIn * priceIn / priceOut, scaled across decimals.
    function _grossOut(
        uint256 amountIn,
        uint256 priceIn1e18,
        uint256 priceOut1e18,
        uint8   decimalsIn,
        uint8   decimalsOut
    ) internal pure returns (uint256) {
        // usd1e18Value = amountIn * priceIn1e18 / 10^decimalsIn
        uint256 usdValue1e18 = (amountIn * priceIn1e18) / (10 ** decimalsIn);
        // amountOut = usdValue1e18 * 10^decimalsOut / priceOut1e18
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

        (uint256 pIn,  IStablecoinRegistry.TokenInfo memory iIn)  = _readUsdPrice1e18(tokenIn);
        (uint256 pOut, IStablecoinRegistry.TokenInfo memory iOut) = _readUsdPrice1e18(tokenOut);

        uint256 gross = _grossOut(amountIn, pIn, pOut, iIn.decimals, iOut.decimals);
        uint256 fee   = (gross * swapFeeBps) / BPS;
        amountOut     = gross - fee;
    }
```

- [ ] **Step 4: Run quote tests, verify pass**

Run: `cd packages/contracts && forge test --match-contract StablePoolTest --match-test test_Quote -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/contracts/src/pool/StablePool.sol packages/contracts/test/StablePool.t.sol
git commit -m "feat(contracts): StablePool quote with cross-decimal oracle math"
```

---

## Task 7: StablePool — swap (state mutation, fee accrual, reserve check)

**Files:**
- Modify: `packages/contracts/src/pool/StablePool.sol`
- Modify: `packages/contracts/test/StablePool.t.sol`

- [ ] **Step 1: Write failing swap tests**

Append to `StablePoolTest`:

```solidity
    // ── swap ──────────────────────────────────────────────────────────

    function test_Swap_USDCtoEURC_TransfersAndAccountsCorrectly() public {
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);

        usdc.mint(customer, 1_000e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);

        uint256 expected = pool.quote(address(usdc), address(eurc), 1_000e6);
        uint256 grossEurc = (1_000e6 * 1.0000e8) / 1.0863e8 * 1e0; // not used, just docs

        vm.expectEmit(true, true, true, true, address(pool));
        emit IStablePool.Swapped(customer, address(usdc), address(eurc), 1_000e6, expected, /*fee*/ 0, customer);
        // We can't predict the fee easily because expected is post-fee; skip strict fee check by recomputing.

        uint256 received = pool.swap(address(usdc), address(eurc), 1_000e6, expected, block.timestamp, customer);
        vm.stopPrank();

        assertEq(received, expected);
        assertEq(eurc.balanceOf(customer), expected);
        assertEq(pool.reserves(address(usdc)), 100_000e6 + 1_000e6);
        assertEq(pool.reserves(address(eurc)), 100_000e6 - expected);

        // Fee accrued in tokenOut units
        assertGt(pool.protocolFeesAccrued(address(eurc)), 0);
    }

    function test_Swap_RevertsOnInsufficientLiquidity() public {
        _seed(address(usdc), 100_000e6);
        // No EURC reserve — swap should revert
        usdc.mint(customer, 1_000e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(); // bound by available reserves[eurc] = 0
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);
        vm.stopPrank();
    }

    function test_Swap_RevertsOnSlippage() public {
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);

        usdc.mint(customer, 1_000e6);
        uint256 quote_ = pool.quote(address(usdc), address(eurc), 1_000e6);

        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IStablePool.InsufficientOutput.selector, quote_, quote_ + 1));
        pool.swap(address(usdc), address(eurc), 1_000e6, quote_ + 1, block.timestamp, customer);
        vm.stopPrank();
    }

    function test_Swap_RevertsOnExpiredDeadline() public {
        _seed(address(usdc), 100e6);
        _seed(address(eurc), 100e6);

        usdc.mint(customer, 10e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 10e6);
        vm.expectRevert(IStablePool.DeadlinePassed.selector);
        pool.swap(address(usdc), address(eurc), 10e6, 0, block.timestamp - 1, customer);
        vm.stopPrank();
    }

    function test_Swap_RevertsWhenPaused() public {
        _seed(address(usdc), 100e6);
        _seed(address(eurc), 100e6);
        vm.prank(owner);
        pool.pause();

        usdc.mint(customer, 10e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 10e6);
        vm.expectRevert(IStablePool.PoolPaused.selector);
        pool.swap(address(usdc), address(eurc), 10e6, 0, block.timestamp, customer);
        vm.stopPrank();
    }

    function test_Swap_TransfersToCustomRecipient() public {
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);

        address merchant = makeAddr("merchant");
        usdc.mint(customer, 1_000e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);
        uint256 expected = pool.quote(address(usdc), address(eurc), 1_000e6);
        uint256 received = pool.swap(address(usdc), address(eurc), 1_000e6, expected, block.timestamp, merchant);
        vm.stopPrank();

        assertEq(received, expected);
        assertEq(eurc.balanceOf(merchant), expected);
        assertEq(eurc.balanceOf(customer), 0);
    }
```

- [ ] **Step 2: Run, verify failure (still "not implemented")**

Run: `cd packages/contracts && forge test --match-contract StablePoolTest --match-test test_Swap -vv`
Expected: FAIL — revert "not implemented".

- [ ] **Step 3: Implement swap()**

Replace the swap stub with:

```solidity
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

        (uint256 pIn,  IStablecoinRegistry.TokenInfo memory iIn)  = _readUsdPrice1e18(tokenIn);
        (uint256 pOut, IStablecoinRegistry.TokenInfo memory iOut) = _readUsdPrice1e18(tokenOut);

        uint256 gross = _grossOut(amountIn, pIn, pOut, iIn.decimals, iOut.decimals);
        uint256 fee   = (gross * swapFeeBps) / BPS;
        amountOut     = gross - fee;

        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        uint256 outReserve = reserves[tokenOut];
        if (gross > outReserve) revert InsufficientLiquidity(tokenOut, gross, outReserve);

        // Pull-in, then update reserves, then push-out (CEI ordering).
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        reserves[tokenIn]  = reserves[tokenIn] + amountIn;
        reserves[tokenOut] = outReserve - gross;
        protocolFeesAccrued[tokenOut] += fee;

        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, fee, recipient);
    }
```

- [ ] **Step 4: Run, verify pass**

Run: `cd packages/contracts && forge test --match-contract StablePoolTest -vv`
Expected: PASS — full StablePool suite green.

- [ ] **Step 5: Commit**

```bash
git add packages/contracts/src/pool/StablePool.sol packages/contracts/test/StablePool.t.sol
git commit -m "feat(contracts): StablePool swap + fee accrual + recipient routing"
```

---

## Task 8: StablePool — per-token PriceGuard (last-accepted price)

**Files:**
- Modify: `packages/contracts/src/pool/StablePool.sol`
- Modify: `packages/contracts/test/StablePool.t.sol`

- [ ] **Step 1: Write failing PriceGuard tests**

Append to `StablePoolTest`:

```solidity
    // ── PriceGuard ────────────────────────────────────────────────────

    function test_PriceGuard_FirstSwapPrimesAccepted_NoRevert() public {
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);
        usdc.mint(customer, 1_000e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 1_000e6);
        // First-ever swap on this token primes lastAcceptedPrice; cannot revert on deviation.
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);
        vm.stopPrank();

        assertEq(pool.lastAcceptedPrice(address(usdc)), 1e18);     // 1.0000 USD scaled to 1e18
        assertApproxEqRel(pool.lastAcceptedPrice(address(eurc)), 1.0863e18, 1e15);
    }

    function test_PriceGuard_RevertsOnLargeDeviation_USDC() public {
        // First, prime: usdc=1.0000.
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);
        usdc.mint(customer, 2_000e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 2_000e6);
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);
        vm.stopPrank();

        // Now USDC oracle prints $0.95 — 5% off, way over 50bps.
        usdcFeed.setAnswer(0.95e8);

        vm.startPrank(customer);
        vm.expectRevert(abi.encodeWithSelector(
            IStablePool.PriceDeviation.selector, address(usdc), 0.95e18, 1e18, TIGHT_DEV_BPS
        ));
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);
        vm.stopPrank();
    }

    function test_PriceGuard_AllowsSmallMove_WithinBand() public {
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);
        usdc.mint(customer, 2_000e6);
        vm.startPrank(customer);
        usdc.approve(address(pool), 2_000e6);
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);

        // Bump USDC by 30 bps — within 50bps cap.
        usdcFeed.setAnswer(1.0030e8);
        // Should still succeed.
        pool.swap(address(usdc), address(eurc), 1_000e6, 0, block.timestamp, customer);
        vm.stopPrank();

        assertEq(pool.lastAcceptedPrice(address(usdc)), 1.003e18);
    }

    function test_PriceGuard_FXTokenUsesItsBand() public {
        // EURC is configured with FX_DEV_BPS=150. A 1% move is allowed.
        _seed(address(usdc), 100_000e6);
        _seed(address(eurc), 100_000e6);
        eurc.mint(customer, 2_000e6);
        vm.startPrank(customer);
        eurc.approve(address(pool), 2_000e6);
        pool.swap(address(eurc), address(usdc), 1_000e6, 0, block.timestamp, customer);

        // Move EURC by 1%: 1.0863 -> 1.0972.
        eurcFeed.setAnswer(1.0972e8);
        pool.swap(address(eurc), address(usdc), 1_000e6, 0, block.timestamp, customer);
        vm.stopPrank();
    }
```

- [ ] **Step 2: Run, verify failure (no `lastAcceptedPrice`, no deviation logic)**

Run: `cd packages/contracts && forge test --match-contract StablePoolTest --match-test test_PriceGuard -vv`
Expected: FAIL — `lastAcceptedPrice` undefined.

- [ ] **Step 3: Add PriceGuard storage + check to StablePool**

Add new state and helper to `StablePool.sol`:

After the `protocolFeesAccrued` mapping, insert:

```solidity
    /// @notice Per-token last accepted oracle price (1e18 scaled). 0 means never observed.
    mapping(address token => uint256) public lastAcceptedPrice;
```

Replace `_readUsdPrice1e18`'s body with this version that also runs the deviation check + records:

Wait — `_readUsdPrice1e18` is a `view` function. The deviation check has to happen *before* mutating state and `lastAcceptedPrice` updates need to be in a non-view path. Refactor:

Add new internal function `_readAndGuardPrice` (non-view):

```solidity
    /// @dev Stateful: reads oracle, runs PriceGuard, updates lastAcceptedPrice.
    function _readAndGuardPrice(address token)
        internal
        returns (uint256 price1e18, IStablecoinRegistry.TokenInfo memory info)
    {
        (price1e18, info) = _readUsdPrice1e18(token);
        uint256 prev = lastAcceptedPrice[token];
        if (prev != 0) {
            uint256 diff = price1e18 > prev ? price1e18 - prev : prev - price1e18;
            if (diff * BPS > prev * info.maxOracleDeviationBps) {
                revert PriceDeviation(token, price1e18, prev, info.maxOracleDeviationBps);
            }
        }
        lastAcceptedPrice[token] = price1e18;
    }
```

Update `swap()` to call `_readAndGuardPrice` instead of `_readUsdPrice1e18` for both tokenIn and tokenOut. `quote()` continues to use `_readUsdPrice1e18` (view-only) so it does not mutate state.

```solidity
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

        (uint256 pIn,  IStablecoinRegistry.TokenInfo memory iIn)  = _readAndGuardPrice(tokenIn);
        (uint256 pOut, IStablecoinRegistry.TokenInfo memory iOut) = _readAndGuardPrice(tokenOut);

        uint256 gross = _grossOut(amountIn, pIn, pOut, iIn.decimals, iOut.decimals);
        uint256 fee   = (gross * swapFeeBps) / BPS;
        amountOut     = gross - fee;

        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        uint256 outReserve = reserves[tokenOut];
        if (gross > outReserve) revert InsufficientLiquidity(tokenOut, gross, outReserve);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        reserves[tokenIn]  = reserves[tokenIn] + amountIn;
        reserves[tokenOut] = outReserve - gross;
        protocolFeesAccrued[tokenOut] += fee;

        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, fee, recipient);
    }
```

- [ ] **Step 4: Run, verify all StablePool tests pass**

Run: `cd packages/contracts && forge test --match-contract StablePoolTest -vv`
Expected: PASS — including new PriceGuard tests.

- [ ] **Step 5: Commit**

```bash
git add packages/contracts/src/pool/StablePool.sol packages/contracts/test/StablePool.t.sol
git commit -m "feat(contracts): per-token PriceGuard with last-accepted price tracking"
```

---

## Task 9: MintableERC20 (production-deployable testnet token)

**Files:**
- Create: `packages/contracts/src/testnet/MintableERC20.sol`

- [ ] **Step 1: Create the contract**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 }   from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MintableERC20
/// @notice Owner-mintable ERC20 with configurable decimals. Testnet stablecoin mock.
contract MintableERC20 is ERC20, Ownable {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address initialOwner)
        ERC20(name_, symbol_)
        Ownable(initialOwner)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd packages/contracts && forge build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add packages/contracts/src/testnet/MintableERC20.sol
git commit -m "feat(contracts): add MintableERC20 for testnet stable mocks"
```

---

## Task 10: Refactor ArcFXGateway to v0.7 (route through StablePool + Registry)

**Files:**
- Modify: `packages/contracts/src/ArcFXGateway.sol`

- [ ] **Step 1: Update imports + immutables block**

Replace the `import` block (lines 1-12) with:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable }           from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }      from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IStablePool }           from "./pool/IStablePool.sol";
import { IStablecoinRegistry }   from "./registry/IStablecoinRegistry.sol";
```

Replace the immutables block (`POOL`, `ORACLE`, `USDC`, `EURC`, `USDC_INDEX`, `EURC_INDEX`, `MAX_ORACLE_DEVIATION_BPS`) with:

```solidity
    // ── Immutable config (v0.7) ────────────────────────────────────────
    IStablePool          public immutable POOL;
    IStablecoinRegistry  public immutable REGISTRY;
    uint256              public immutable PROTOCOL_FEE_BPS;

    /// @dev Max iterations for _estimateAmountIn (carried from v0.5).
    uint256 internal constant ESTIMATE_MAX_STEPS = 8;
```

Change the contract declaration to use `Ownable2Step`:

```solidity
contract ArcFXGateway is Ownable2Step, ReentrancyGuard {
```

- [ ] **Step 2: Update the constructor**

Replace the constructor with:

```solidity
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
```

- [ ] **Step 3: Update `registerMerchant` payout-token validation**

Find the existing `registerMerchant` body and replace the payout token check with:

```solidity
        if (!REGISTRY.isActive(payoutToken)) revert InvalidPayoutToken();
```

Same substitution inside `updatePayoutToken`.

- [ ] **Step 4: Replace `_estimateAmountIn` body**

Replace the body of `_estimateAmountIn` so it calls `POOL.quote` and reads decimals from the registry:

```solidity
    function _estimateAmountIn(address tokenIn, address tokenOut, uint256 amountOut)
        internal
        view
        returns (uint256 amountIn)
    {
        uint8 decIn = REGISTRY.tokenInfo(tokenIn).decimals;
        uint256 probeIn  = 10 ** decIn;
        uint256 probeOut = POOL.quote(tokenIn, tokenOut, probeIn);
        if (probeOut == 0) return type(uint256).max;
        amountIn = (amountOut * probeIn + probeOut - 1) / probeOut;
        for (uint256 i = 0; i < ESTIMATE_MAX_STEPS; i++) {
            if (POOL.quote(tokenIn, tokenOut, amountIn) >= amountOut) return amountIn;
            unchecked { amountIn++; }
        }
    }
```

- [ ] **Step 5: Refactor `pay()` to route through `POOL.swap`**

Replace the body of `pay()`. Locate the function. The new pay flow:

1. Lookup invoice + merchant; existing checks unchanged.
2. If `inv.payIn == merchant.payoutToken`: same-token branch (transfer payIn → merchant minus fee, no swap).
3. Else: estimate amountIn, transfer from payer to gateway, approve pool, call `POOL.swap(payIn, payoutToken, amountIn, amountOut, deadline, address(this))`, then split `received` into `merchantPayout` + `protocolFee`, transfer to merchant, accrue fee.

Replace the swap section (everything that previously called `pool.swap(i, j, ...)` with index params) with:

```solidity
        if (inv.payIn == m.payoutToken) {
            // Same-token: direct, no swap, fee taken in payoutToken.
            uint256 grossIn = inv.amountOut;
            uint256 fee = (grossIn * PROTOCOL_FEE_BPS) / 10_000;
            uint256 merchantPayout = grossIn - fee;

            IERC20(inv.payIn).safeTransferFrom(payer, m.payoutAddress, merchantPayout);
            if (fee > 0) {
                IERC20(inv.payIn).safeTransferFrom(payer, address(this), fee);
                protocolFeesAccrued[inv.payIn] += fee;
            }

            payments[globalId] = InvoicePayment({ merchantPayout: merchantPayout, fee: fee });
            inv.status = InvoiceStatus.Paid;
            inv.paidBy = payer;

            emit InvoicePaid(globalId, payer, grossIn, grossIn, merchantPayout, fee);
            return;
        }

        // Cross-token: swap through the shared pool.
        uint256 amountIn = _estimateAmountIn(inv.payIn, m.payoutToken, inv.amountOut);
        if (amountIn > maxAmountIn) revert SlippageExceeded(amountIn, maxAmountIn);

        IERC20(inv.payIn).safeTransferFrom(payer, address(this), amountIn);
        IERC20(inv.payIn).forceApprove(address(POOL), amountIn);

        uint256 received = POOL.swap(
            inv.payIn,
            m.payoutToken,
            amountIn,
            inv.amountOut,
            block.timestamp,
            address(this)
        );

        // Apply protocol fee on the received payoutToken.
        uint256 fee = (received * PROTOCOL_FEE_BPS) / 10_000;
        uint256 merchantPayout = received - fee;
        IERC20(m.payoutToken).safeTransfer(m.payoutAddress, merchantPayout);
        if (fee > 0) protocolFeesAccrued[m.payoutToken] += fee;

        payments[globalId] = InvoicePayment({ merchantPayout: merchantPayout, fee: fee });
        inv.status = InvoiceStatus.Paid;
        inv.paidBy = payer;

        emit InvoicePaid(globalId, payer, amountIn, received, merchantPayout, fee);
```

- [ ] **Step 6: Drop the old `MAX_ORACLE_DEVIATION_BPS` PriceGuard call**

The pool now enforces deviation per-token. Remove any `PriceGuard.check(...)` reference in the gateway. The `import { PriceGuard }` line must be removed too.

- [ ] **Step 7: Verify compile (tests will be broken until Task 11)**

Run: `cd packages/contracts && forge build`
Expected: PASS for `src/`, but tests will fail to compile because `ArcFXGateway`'s constructor signature changed. That's resolved in Task 11.

- [ ] **Step 8: Commit**

```bash
git add packages/contracts/src/ArcFXGateway.sol
git commit -m "feat(contracts): refactor ArcFXGateway to v0.7 (token-agnostic, pool-routed)"
```

---

## Task 11: Migrate gateway test setup to v0.7

**Files:**
- Modify: `packages/contracts/test/ArcFXGateway.t.sol`
- Modify: `packages/contracts/test/ArcFXGateway.fuzz.t.sol`
- Modify: `packages/contracts/test/ArcFXGateway.invariant.t.sol`
- Modify: `packages/contracts/test/handlers/GatewayHandler.sol`

- [ ] **Step 1: Replace `setUp` in `ArcFXGateway.t.sol`**

Replace the import block + `setUp` with:

```solidity
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ArcFXGateway }       from "../src/ArcFXGateway.sol";
import { StablecoinRegistry } from "../src/registry/StablecoinRegistry.sol";
import { StablePool }         from "../src/pool/StablePool.sol";
import { IStablePool }        from "../src/pool/IStablePool.sol";
import { IStablecoinRegistry } from "../src/registry/IStablecoinRegistry.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";
import { MockChainlinkFeed } from "../src/testnet/MockChainlinkFeed.sol";
import { MockERC20 }         from "./helpers/MockERC20.sol";

contract ArcFXGatewayTest is Test {
    StablecoinRegistry  reg;
    StablePool          pool;
    MockERC20           usdc;
    MockERC20           eurc;
    MockChainlinkFeed   usdcFeed;
    MockChainlinkFeed   eurcFeed;
    ArcFXGateway        gw;

    address merchant = makeAddr("merchant");
    address customer = makeAddr("customer");

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        usdc     = new MockERC20("USDC", "USDC", 6);
        eurc     = new MockERC20("EURC", "EURC", 6);
        usdcFeed = new MockChainlinkFeed(8, 1.0000e8);
        eurcFeed = new MockChainlinkFeed(8, 1.0863e8);

        reg  = new StablecoinRegistry(address(this));
        pool = new StablePool(address(reg), 5, address(this));

        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(usdcFeed)), 50);
        reg.listToken(address(eurc), 6, IChainlinkAggregator(address(eurcFeed)), 150);

        // Seed pool with 1M of each.
        usdc.mint(address(this), 1_000_000e6);
        eurc.mint(address(this), 1_000_000e6);
        IERC20(address(usdc)).approve(address(pool), 1_000_000e6);
        IERC20(address(eurc)).approve(address(pool), 1_000_000e6);
        pool.deposit(address(usdc), 1_000_000e6);
        pool.deposit(address(eurc), 1_000_000e6);

        gw = new ArcFXGateway(
            IStablePool(address(pool)),
            IStablecoinRegistry(address(reg)),
            10,
            address(this)
        );
    }
```

- [ ] **Step 2: Apply identical setup migration to fuzz + invariant + handler**

For each of:
- `packages/contracts/test/ArcFXGateway.fuzz.t.sol`
- `packages/contracts/test/ArcFXGateway.invariant.t.sol`
- `packages/contracts/test/handlers/GatewayHandler.sol`

Replace any `MockStableSwapPool` / `MockChainlink` usage with the same `(reg + pool + usdc + eurc + usdcFeed + eurcFeed)` setup. Constructor of `ArcFXGateway` takes `(IStablePool pool, IStablecoinRegistry registry, uint256 feeBps, address owner)` everywhere.

- [ ] **Step 3: Run full gateway test suite**

Run: `cd packages/contracts && forge test --match-contract ArcFXGatewayTest -vv`
Expected: PASS — all 117+ pre-existing tests green with the new setup. Any new test failures here indicate a v0.7 behavior bug; fix in `ArcFXGateway.sol` until green.

- [ ] **Step 4: Run fuzz + invariant**

Run: `cd packages/contracts && forge test --match-path "test/ArcFXGateway.*.t.sol" -vv`
Expected: PASS — fuzz + invariant suites green.

- [ ] **Step 5: Commit**

```bash
git add packages/contracts/test/
git commit -m "test(contracts): migrate gateway tests to v0.7 setup (registry + StablePool)"
```

---

## Task 12: New cross-stable end-to-end gateway tests

**Files:**
- Modify: `packages/contracts/test/ArcFXGateway.t.sol`

- [ ] **Step 1: Add 5 new mocks to `setUp`**

Edit `setUp` to also create `usdt`, `pyusd`, `dai`, `tryc`, `brlc` and their feeds, list them, and seed the pool with 1M each (DAI 1e18 scaled).

```solidity
    MockERC20 usdt;
    MockERC20 pyusd;
    MockERC20 dai;
    MockERC20 tryc;
    MockERC20 brlc;
    MockChainlinkFeed usdtFeed;
    MockChainlinkFeed pyusdFeed;
    MockChainlinkFeed daiFeed;
    MockChainlinkFeed trycFeed;
    MockChainlinkFeed brlcFeed;

    // Inside setUp(), after the existing usdc/eurc listing:
    usdt     = new MockERC20("USDT",  "USDT",  6);
    pyusd    = new MockERC20("PYUSD", "PYUSD", 6);
    dai      = new MockERC20("DAI",   "DAI",   18);
    tryc     = new MockERC20("TRYC",  "TRYC",  6);
    brlc     = new MockERC20("BRLC",  "BRLC",  6);
    usdtFeed  = new MockChainlinkFeed(8, 1.0001e8);
    pyusdFeed = new MockChainlinkFeed(8, 1.0000e8);
    daiFeed   = new MockChainlinkFeed(8, 1.0000e8);
    trycFeed  = new MockChainlinkFeed(8, 0.0291e8);
    brlcFeed  = new MockChainlinkFeed(8, 0.1980e8);

    reg.listToken(address(usdt),  6,  IChainlinkAggregator(address(usdtFeed)),  50);
    reg.listToken(address(pyusd), 6,  IChainlinkAggregator(address(pyusdFeed)), 50);
    reg.listToken(address(dai),   18, IChainlinkAggregator(address(daiFeed)),   50);
    reg.listToken(address(tryc),  6,  IChainlinkAggregator(address(trycFeed)),  150);
    reg.listToken(address(brlc),  6,  IChainlinkAggregator(address(brlcFeed)),  150);

    address[7] memory list = [address(usdc), address(eurc), address(usdt), address(pyusd), address(dai), address(tryc), address(brlc)];
    uint256[7] memory amts = [
        uint256(1_000_000e6),
        uint256(1_000_000e6),
        uint256(1_000_000e6),
        uint256(1_000_000e6),
        uint256(1_000_000e18),  // DAI 18dec
        uint256(34_000_000e6),  // TRY ≈ $1M / 0.029 
        uint256(5_000_000e6)    // BRL ≈ $1M / 0.198
    ];
    for (uint256 i = 2; i < 7; i++) { // 0,1 already seeded
        MockERC20(list[i]).mint(address(this), amts[i]);
        IERC20(list[i]).approve(address(pool), amts[i]);
        pool.deposit(list[i], amts[i]);
    }
```

- [ ] **Step 2: Add a helper for end-to-end pay-flow**

```solidity
    function _payFlow(address payIn, address payoutToken, uint256 amountOut) internal returns (bytes32 globalId) {
        // Register merchant for payoutToken (or update if already registered).
        if (gw.merchants(merchant).payoutToken == address(0)) {
            vm.prank(merchant);
            gw.registerMerchant(merchant, payoutToken);
        } else {
            vm.prank(merchant);
            gw.updatePayoutToken(payoutToken);
        }

        // Create invoice.
        bytes32 mInvId = keccak256(abi.encodePacked("inv-", payIn, payoutToken, block.timestamp));
        vm.prank(merchant);
        globalId = gw.createInvoice(mInvId, payIn, amountOut, uint64(block.timestamp + 1 hours));

        // Customer pays.
        uint256 maxIn = type(uint256).max;
        // Mint enough payIn to cover any quote.
        MockERC20(payIn).mint(customer, 10_000_000 * 10 ** MockERC20(payIn).decimals());
        vm.startPrank(customer);
        IERC20(payIn).approve(address(gw), type(uint256).max);
        gw.pay(globalId, maxIn);
        vm.stopPrank();
    }
```

- [ ] **Step 3: Add tests for each new path**

```solidity
    function test_Pay_USDTtoUSDC_NewPath() public {
        bytes32 id = _payFlow(address(usdt), address(usdc), 100e6);
        (, , , , , ArcFXGateway.InvoiceStatus status, ) = gw.invoices(id);
        assertEq(uint256(status), uint256(ArcFXGateway.InvoiceStatus.Paid));
        assertGt(usdc.balanceOf(merchant), 0);
    }

    function test_Pay_PYUSDtoDAI_CrossDecimal() public {
        bytes32 id = _payFlow(address(pyusd), address(dai), 100e18);
        assertGt(dai.balanceOf(merchant), 99e18); // approximately 100 - fee
    }

    function test_Pay_DAItoTRYC_CrossDecimalAndFX() public {
        // Payout 100 USD worth of TRYC (~3,448 TRYC at 0.029 USD/TRY)
        bytes32 id = _payFlow(address(dai), address(tryc), 3_448e6);
        assertGe(tryc.balanceOf(merchant), 3_400e6);
    }

    function test_Pay_BRLCtoEURC_BothFX() public {
        // Payout 100 EURC (~$108.6 USD) — BRLC needed: ~548 BRLC (108.6 / 0.198)
        bytes32 id = _payFlow(address(brlc), address(eurc), 100e6);
        assertGe(eurc.balanceOf(merchant), 99e6);
    }

    function test_Pay_USDCtoUSDC_SameToken_Unchanged() public {
        bytes32 id = _payFlow(address(usdc), address(usdc), 100e6);
        // Same-token: no swap fees from pool, only protocol fee from gateway
        (, , , , , ArcFXGateway.InvoiceStatus status, ) = gw.invoices(id);
        assertEq(uint256(status), uint256(ArcFXGateway.InvoiceStatus.Paid));
        assertGt(usdc.balanceOf(merchant), 99e6); // 100 - 0.10% gateway fee
    }
```

(If the destructuring of `invoices()` returns a different shape, look up the exact tuple in `ArcFXGateway.sol:38-46` — adjust to match the existing `Invoice` struct.)

- [ ] **Step 4: Run new tests**

Run: `cd packages/contracts && forge test --match-test test_Pay_ -vv`
Expected: PASS for all 5 new tests.

- [ ] **Step 5: Commit**

```bash
git add packages/contracts/test/ArcFXGateway.t.sol
git commit -m "test(contracts): cross-stable pay flows for USDT/PYUSD/DAI/TRYC/BRLC"
```

---

## Task 13: DeployV07 script

**Files:**
- Create: `packages/contracts/script/DeployV07.s.sol`

- [ ] **Step 1: Write the deploy script**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { StablecoinRegistry }   from "../src/registry/StablecoinRegistry.sol";
import { StablePool }           from "../src/pool/StablePool.sol";
import { ArcFXGateway }         from "../src/ArcFXGateway.sol";
import { MintableERC20 }        from "../src/testnet/MintableERC20.sol";
import { MockChainlinkFeed }    from "../src/testnet/MockChainlinkFeed.sol";
import { IStablePool }          from "../src/pool/IStablePool.sol";
import { IStablecoinRegistry }  from "../src/registry/IStablecoinRegistry.sol";
import { IChainlinkAggregator } from "../src/interfaces/IChainlinkAggregator.sol";

/// @notice Deploys the v0.7 stack: registry + 7 mock tokens + 7 mock feeds + pool + gateway.
/// @dev Required env: DEPLOYER_PRIVATE_KEY, TREASURY_OWNER, PROTOCOL_FEE_BPS, SWAP_FEE_BPS.
contract DeployV07 is Script {
    struct TokenSpec {
        string  name;
        string  symbol;
        uint8   decimals;
        int256  initialPrice;     // Chainlink-shaped, 8 decimals
        uint16  deviationBps;
        uint256 seedAmount;       // pool reserve to seed (in token units)
        bool    deployMock;       // true for all 7; if false, expect address from env
    }

    function run()
        external
        returns (
            StablecoinRegistry reg,
            StablePool pool,
            ArcFXGateway gw,
            address[7] memory tokens,
            address[7] memory feeds
        )
    {
        uint256 pk        = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner     = vm.envAddress("TREASURY_OWNER");
        uint256 feeBps    = vm.envUint("PROTOCOL_FEE_BPS");
        uint256 swapFee   = vm.envUint("SWAP_FEE_BPS");

        TokenSpec[7] memory specs = [
            TokenSpec("USD Coin",          "USDC",  6,  1.0000e8, 50,    1_000_000e6,  true),
            TokenSpec("Tether USD",        "USDT",  6,  1.0001e8, 50,    1_000_000e6,  true),
            TokenSpec("PayPal USD",        "PYUSD", 6,  1.0000e8, 50,    1_000_000e6,  true),
            TokenSpec("Dai Stablecoin",    "DAI",   18, 1.0000e8, 50,    1_000_000e18, true),
            TokenSpec("Euro Coin",         "EURC",  6,  1.0863e8, 150,     920_000e6,  true),
            TokenSpec("Lira Coin",         "TRYC",  6,  0.0291e8, 150, 34_000_000e6,   true),
            TokenSpec("Real Coin",         "BRLC",  6,  0.1980e8, 150,  5_050_000e6,   true)
        ];

        vm.startBroadcast(pk);

        reg  = new StablecoinRegistry(owner);
        pool = new StablePool(address(reg), uint16(swapFee), owner);
        gw   = new ArcFXGateway(
            IStablePool(address(pool)),
            IStablecoinRegistry(address(reg)),
            feeBps,
            owner
        );

        // Deploy mock tokens + feeds, register, seed reserves.
        for (uint256 i = 0; i < 7; i++) {
            TokenSpec memory s = specs[i];
            MintableERC20 t = new MintableERC20(s.name, s.symbol, s.decimals, owner);
            MockChainlinkFeed f = new MockChainlinkFeed(8, s.initialPrice);
            tokens[i] = address(t);
            feeds[i]  = address(f);
        }

        vm.stopBroadcast();

        // Owner-side calls: list + mint + deposit. These need owner's pk; if owner == deployer
        // they happen in the same broadcast. If owner is a different address, run a follow-up
        // script as `owner`. For testnet we set owner = deployer.
        require(vm.addr(pk) == owner, "owner must equal deployer for one-shot setup");

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < 7; i++) {
            TokenSpec memory s = specs[i];
            reg.listToken(tokens[i], s.decimals, IChainlinkAggregator(feeds[i]), s.deviationBps);
            MintableERC20(tokens[i]).mint(owner, s.seedAmount);
            IERC20(tokens[i]).approve(address(pool), s.seedAmount);
            pool.deposit(tokens[i], s.seedAmount);
        }
        vm.stopBroadcast();

        console2.log("Registry: ", address(reg));
        console2.log("Pool:     ", address(pool));
        console2.log("Gateway:  ", address(gw));
        for (uint256 i = 0; i < 7; i++) {
            console2.log(string.concat("Token[", vm.toString(i), "]:"), tokens[i]);
            console2.log(string.concat("Feed [", vm.toString(i), "]:"), feeds[i]);
        }
    }
}
```

- [ ] **Step 2: Verify compile**

Run: `cd packages/contracts && forge build`
Expected: PASS.

- [ ] **Step 3: Dry-run on local fork**

Run: `cd packages/contracts && forge script script/DeployV07.s.sol:DeployV07 -vvvv`
Expected: PASS in simulation; logs show 3 contract addresses + 7 tokens + 7 feeds.

- [ ] **Step 4: Commit**

```bash
git add packages/contracts/script/DeployV07.s.sol
git commit -m "feat(contracts): DeployV07 single-shot script (registry + pool + gateway + 7 stables)"
```

---

## Task 14: Live deploy to Arc testnet + smoke

**Files:** none (operational task)

- [ ] **Step 1: Confirm env vars**

```bash
cd packages/contracts
grep -E "DEPLOYER_PRIVATE_KEY|TREASURY_OWNER|PROTOCOL_FEE_BPS|SWAP_FEE_BPS|ARC_TESTNET_RPC|ARC_EXPLORER_KEY" .env
```
Expected: all six variables present. Set `SWAP_FEE_BPS=5`, `PROTOCOL_FEE_BPS=10`. `TREASURY_OWNER` MUST equal `vm.addr(DEPLOYER_PRIVATE_KEY)`.

- [ ] **Step 2: Broadcast**

```bash
cd packages/contracts
forge script script/DeployV07.s.sol:DeployV07 \
  --rpc-url arc_testnet \
  --broadcast \
  --legacy \
  -vvvv
```
Expected: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`. Note the printed addresses.

- [ ] **Step 3: Verify addresses are real (foundry-broadcast-lies trap)**

For each printed address `<addr>`:
```bash
cast code <addr> --rpc-url arc_testnet | head -c 20
```
Expected: non-empty bytecode (i.e. starts with `0x60...`). If any address shows `0x` or empty: **abort**, do not proceed.

- [ ] **Step 4: Live smoke — 7 paths**

For each of the 7 smoke flows (same-token USDC, USDC→EURC, EURC→USDC, USDT→USDC, PYUSD→DAI, DAI→TRYC, BRLC→EURC):

a. Mint payIn token to the smoke wallet:
```bash
cast send <token> 'mint(address,uint256)' <smoke-wallet> <amount> \
  --rpc-url arc_testnet --legacy --private-key <deployer-pk>
```

b. Approve gateway:
```bash
cast send <token> 'approve(address,uint256)' <gateway> <amount> \
  --rpc-url arc_testnet --legacy --private-key <smoke-pk>
```

c. Register merchant + create invoice + pay (use the existing demo merchant flow). Capture the `pay()` tx hash.

d. Verify with `cast receipt <hash> --rpc-url arc_testnet` that `status: 0x1` and there are emitted logs.

- [ ] **Step 5: Record addresses + tx hashes in the rollout note**

Create `docs/rollouts/2026-04-30-v0.7-deploy.md` capturing:
- Deployer wallet address.
- All 3 deployed contract addresses (registry, pool, gateway) with verified `cast code` non-empty.
- All 7 token + 7 feed addresses.
- All 7 smoke tx hashes (with arcscan URLs).

- [ ] **Step 6: Commit rollout note**

```bash
git add docs/rollouts/2026-04-30-v0.7-deploy.md
git commit -m "docs(rollouts): record v0.7 testnet deploy + 7-path smoke results"
```

---

## Task 15: VPS keeper extension (multi-feed push)

**Files:**
- Create: `ops/keepalive/multi-feed-push.ts`
- Modify: `ops/keepalive/.env.example` (or whatever the existing env config is)
- Modify: existing systemd unit on VPS (`arcora-oracle-keepalive.service`)

- [ ] **Step 1: Inspect existing keeper layout**

```bash
ls ops/keepalive/
cat ops/keepalive/*.ts | head -100
```
Note the patterns used (provider, signing, env vars).

- [ ] **Step 2: Write the new keeper script**

Create `ops/keepalive/multi-feed-push.ts`:

```typescript
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";

type FeedConfig = {
  symbol: string;
  feedAddress: `0x${string}`;
  coingeckoId?: string;        // for stable→USD
  coingeckoVsCurrency?: string; // for fiat→USD (TRY/USD, BRL/USD)
  hardcodedAnswer1e8?: bigint;  // for USDC peg
  band: { min: number; max: number }; // sanity check before push
};

const FEEDS: FeedConfig[] = [
  { symbol: "USDC",  feedAddress: process.env.FEED_USDC  as `0x${string}`, hardcodedAnswer1e8: 100_000_000n, band: { min: 1, max: 1 } },
  { symbol: "USDT",  feedAddress: process.env.FEED_USDT  as `0x${string}`, coingeckoId: "tether",       band: { min: 0.95, max: 1.05 } },
  { symbol: "PYUSD", feedAddress: process.env.FEED_PYUSD as `0x${string}`, coingeckoId: "paypal-usd",   band: { min: 0.95, max: 1.05 } },
  { symbol: "DAI",   feedAddress: process.env.FEED_DAI   as `0x${string}`, coingeckoId: "dai",          band: { min: 0.95, max: 1.05 } },
  { symbol: "EURC",  feedAddress: process.env.FEED_EURC  as `0x${string}`, coingeckoVsCurrency: "eur",  band: { min: 1.00, max: 1.20 } },
  { symbol: "TRYC",  feedAddress: process.env.FEED_TRYC  as `0x${string}`, coingeckoVsCurrency: "try",  band: { min: 0.01, max: 0.10 } },
  { symbol: "BRLC",  feedAddress: process.env.FEED_BRLC  as `0x${string}`, coingeckoVsCurrency: "brl",  band: { min: 0.10, max: 0.30 } },
];

const ABI_SET_ANSWER = [
  { type: "function", name: "setAnswer", inputs: [{ type: "int256" }], outputs: [], stateMutability: "nonpayable" },
] as const;

async function getPriceUsd(f: FeedConfig): Promise<number> {
  if (f.hardcodedAnswer1e8 !== undefined) return Number(f.hardcodedAnswer1e8) / 1e8;
  if (f.coingeckoId) {
    const url = `https://api.coingecko.com/api/v3/simple/price?ids=${f.coingeckoId}&vs_currencies=usd`;
    const res = await fetch(url).then((r) => r.json());
    return res[f.coingeckoId].usd;
  }
  if (f.coingeckoVsCurrency) {
    // Use 1 USD vs target currency, invert.
    const url = `https://api.coingecko.com/api/v3/simple/price?ids=usd&vs_currencies=${f.coingeckoVsCurrency}`;
    const res = await fetch(url).then((r) => r.json());
    return 1 / res.usd[f.coingeckoVsCurrency];
  }
  throw new Error(`feed ${f.symbol} has no price source`);
}

async function main() {
  const rpc = process.env.ARC_TESTNET_RPC!;
  const pk = process.env.KEEPER_PRIVATE_KEY! as `0x${string}`;
  const account = privateKeyToAccount(pk);
  const wallet = createWalletClient({ account, transport: http(rpc) });

  for (const f of FEEDS) {
    try {
      const usd = await getPriceUsd(f);
      if (usd < f.band.min || usd > f.band.max) {
        console.warn(`[skip] ${f.symbol} = ${usd} outside band [${f.band.min}, ${f.band.max}]`);
        continue;
      }
      const answer = BigInt(Math.round(usd * 1e8));
      const hash = await wallet.writeContract({
        address: f.feedAddress,
        abi: ABI_SET_ANSWER,
        functionName: "setAnswer",
        args: [answer],
        chain: null,
      });
      console.log(`[ok] ${f.symbol} = ${usd} (1e8=${answer}) tx=${hash}`);
    } catch (e) {
      console.error(`[err] ${f.symbol}:`, e);
    }
  }
}

main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
```

- [ ] **Step 3: Test locally with current testnet feeds**

```bash
cd ops/keepalive
FEED_USDC=0x... FEED_USDT=0x... <fill all 7> ARC_TESTNET_RPC=... KEEPER_PRIVATE_KEY=... \
  pnpm exec tsx multi-feed-push.ts
```
Expected: 7 lines of `[ok]` (or `[skip]` for USDC band-check that's identical).

- [ ] **Step 4: Update VPS systemd unit**

SSH to VPS:
```bash
ssh root@194.163.136.1
```

Update `/etc/systemd/system/arcora-oracle-keepalive.service` to point at `multi-feed-push.ts` and add the 7 `FEED_*` env vars from the rollout note. Then:
```bash
systemctl daemon-reload
systemctl restart arcora-oracle-keepalive.service
journalctl -u arcora-oracle-keepalive.service -f
```
Expected: timer fires on schedule, logs show 7 `[ok]` lines per tick.

- [ ] **Step 5: Commit script + env example**

```bash
git add ops/keepalive/multi-feed-push.ts
git commit -m "feat(ops): keeper script for 7-feed CoinGecko push"
```

---

## Task 16: Final regression sweep + PR

- [ ] **Step 1: Run full contract suite**

```bash
cd packages/contracts && forge test
```
Expected: all tests green (target ≥ 140).

- [ ] **Step 2: Run gas snapshot**

```bash
cd packages/contracts && forge snapshot
```
Expected: snapshot updates; review the diff vs prior snapshot for unexpected gas regressions.

- [ ] **Step 3: Push branch + open PR**

```bash
git push -u origin plan-1-protocol
gh pr create --title "v0.7: multi-stablecoin shared-vault pool" --body "$(cat <<'EOF'
## Summary
- New `StablecoinRegistry` (Ownable2Step) for token + USD oracle metadata
- New `StablePool` (Ownable2Step + Pausable) shared vault, no pairs, oracle-priced
- `ArcFXGateway` v0.7: token-agnostic, routes through pool, preserves same-token branch
- 7 stables day-one: USDC, USDT, PYUSD, DAI, EURC, TRYC, BRLC
- Live on Arc testnet (see docs/rollouts/2026-04-30-v0.7-deploy.md)

## Test plan
- [x] `forge test` — full suite passes (≥140 tests)
- [x] Live smoke — 7 pay flows verified on Arc testnet
- [x] Keeper running on VPS — 6 feeds updated on schedule

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Update memory with deployed addresses**

Update `~/.claude/projects/-Users-huseyinarslan-arc-fx-gateway/memory/roadmap_open_items.md` with v0.7 status, new addresses, and the next milestone (app-side integration).

---

## Self-review notes (filled in 2026-04-30)

Spec coverage:
- `StablecoinRegistry` with Ownable2Step + 7-token listing → Tasks 1–3 ✓
- `StablePool` shared vault + per-token PriceGuard + Pausable → Tasks 4–8 ✓
- `ArcFXGateway` v0.7 refactor → Task 10 ✓
- Existing test suite migration → Task 11 ✓
- New cross-stable tests → Task 12 ✓
- 6 mock tokens + 6 mock feeds + deploy → Tasks 9, 13 ✓
- Live deploy + smoke → Task 14 ✓
- VPS keeper extension → Task 15 ✓
- Self-review + PR → Task 16 ✓

Open spec questions deferred to live tuning (per-token deviation bps, swap fee value): handled by `setDeviation` / `setSwapFeeBps` mutations on the deployed contracts; no plan task needed.

App-side integration (`/api/tokens`, dashboard picker, indexer ABI): explicitly **out of scope** for this plan; queued as follow-up plan after this PR merges.
