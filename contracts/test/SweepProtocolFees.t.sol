// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SweepProtocolFees} from "../script/SweepProtocolFees.s.sol";
import {ArcoraDexPool} from "../src/ArcoraDexPool.sol";
import {ArcoraDexRegistry} from "../src/ArcoraDexRegistry.sol";
import {ArcoraDexLP} from "../src/ArcoraDexLP.sol";
import {IArcoraDexPool} from "../src/interfaces/IArcoraDexPool.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {MintableERC20} from "../src/testnet/MintableERC20.sol";
import {MockChainlinkFeed} from "../src/testnet/MockChainlinkFeed.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Couples the protocol-fee SWEEP to the REAL script logic.
///
/// CRITICAL DESIGN: this contract INHERITS `SweepProtocolFees`, so the asserts
/// below drive the script's OWN `_sweepAll(...)` / `_sweepToken(...)` — the exact
/// internal functions `run()` calls between `vm.startBroadcast`/`vm.stopBroadcast`.
/// A regression in the sweep logic (e.g. mis-wiring the `to` address, or not
/// zeroing the accrual) therefore fails these tests in CI, mirroring how
/// `DeployPublicTestnetGaps.t.sol` couples to its orchestrator's helpers rather
/// than re-implementing the pattern in `setUp()`.
///
/// Verified mutation-coverage (see PR description / report):
///   - `to = address(this)` (or any non-TREASURY) instead of `treasury` in
///     `_sweepToken` -> test_sweep_movesEachTokensAccruedToTreasury FAILS
///     (treasury balance assertion).
contract SweepProtocolFeesTest is Test, SweepProtocolFees {
    ArcoraDexPool pool;
    ArcoraDexRegistry reg;
    ArcoraDexLP lp;
    MintableERC20 usdc;
    MockChainlinkFeed fUsdc;
    MintableERC20 eurc;
    MockChainlinkFeed fEurc;
    MintableERC20 dai;
    MockChainlinkFeed fDai;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    // The user-held treasury EOA: the destination of every swept fee. Only its
    // ADDRESS matters here (the script takes TREASURY as an address, never a key).
    address treasury = makeAddr("treasury");

    uint16 constant SWAP_FEE_BPS_DEFAULT = 30;
    uint16 constant PROT_SHARE_DEFAULT = 1000; // 10%

    function setUp() public {
        usdc = new MintableERC20("USD Coin", "USDC", 6, owner);
        eurc = new MintableERC20("Euro Coin", "EURC", 6, owner);
        dai = new MintableERC20("Dai", "DAI", 18, owner);
        fUsdc = new MockChainlinkFeed(8, int256(1e8));
        fEurc = new MockChainlinkFeed(8, int256(11e7)); // $1.10
        fDai = new MockChainlinkFeed(8, int256(1e8));

        reg = new ArcoraDexRegistry(owner);
        // Pool owned by `owner` — stands in for the deferred-governance / deployer-
        // owned Pool that this script's path targets.
        pool = new ArcoraDexPool(address(reg), SWAP_FEE_BPS_DEFAULT, PROT_SHARE_DEFAULT, owner);
        lp = ArcoraDexLP(address(pool.LP()));

        vm.startPrank(owner);
        reg.listToken(address(usdc), 6, IChainlinkAggregator(address(fUsdc)), 50, 3600);
        reg.listToken(address(eurc), 6, IChainlinkAggregator(address(fEurc)), 150, 14400);
        reg.listToken(address(dai), 18, IChainlinkAggregator(address(fDai)), 50, 3600);
        usdc.mint(alice, 100_000e6);
        eurc.mint(alice, 100_000e6);
        dai.mint(alice, 100_000e18);
        vm.stopPrank();
    }

    /// @dev Seed all three tokens with liquidity (so swaps can route through them).
    function _seedAllThree() internal {
        vm.startPrank(alice);
        usdc.approve(address(pool), 5_000e6);
        eurc.approve(address(pool), 5_000e6);
        dai.approve(address(pool), 5_000e18);
        pool.deposit(address(usdc), 5_000e6, 0, block.timestamp);
        pool.deposit(address(eurc), 5_000e6, 0, block.timestamp);
        pool.deposit(address(dai), 5_000e18, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Accrue non-zero protocol fees in BOTH `eurc` and `dai` (the tokenOut of
    /// each swap), leaving `usdc` with ZERO accrued so the skip path is exercised.
    /// Mirrors `ArcoraDexPool.t.sol::test_swap_charges_protocol_fee_in_tokenOut`.
    function _accrueFeesOnEurcAndDai() internal {
        _seedAllThree();
        vm.prank(owner);
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 1_000e6);
        // USDC -> EURC: protocol fee accrues in EURC.
        pool.swap(address(usdc), address(eurc), 500e6, 0, block.timestamp, bob);
        // USDC -> DAI: protocol fee accrues in DAI.
        pool.swap(address(usdc), address(dai), 500e6, 0, block.timestamp, bob);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Happy path — drives the script's REAL _sweepAll against the test Pool.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice After accruing fees in EURC and DAI (and leaving USDC at zero), the
    /// script's `_sweepAll` must: move each token's full accrued amount to the
    /// treasury EOA, zero each `protocolFeesAccrued`, and SKIP the zero-accrued USDC.
    function test_sweep_movesEachTokensAccruedToTreasury() public {
        _accrueFeesOnEurcAndDai();

        uint256 eurcAccrued = pool.protocolFeesAccrued(address(eurc));
        uint256 daiAccrued = pool.protocolFeesAccrued(address(dai));
        uint256 usdcAccrued = pool.protocolFeesAccrued(address(usdc));
        assertGt(eurcAccrued, 0, "EURC must have accrued protocol fees to sweep");
        assertGt(daiAccrued, 0, "DAI must have accrued protocol fees to sweep");
        assertEq(usdcAccrued, 0, "USDC must have ZERO accrued (skip path)");

        uint256 eurcTreasuryBefore = eurc.balanceOf(treasury);
        uint256 daiTreasuryBefore = dai.balanceOf(treasury);
        uint256 usdcTreasuryBefore = usdc.balanceOf(treasury);

        // Drive the script's REAL sweep, acting as the Pool owner (deployer path).
        // startPrank (not prank): _sweepAll makes several external calls into the
        // Pool and the persistent prank must hold for the withdrawProtocolFees
        // calls, not just the first reservesAccrued read.
        vm.startPrank(owner);
        (uint256 swept, uint256 skipped) = _sweepAll(IArcoraDexPool(address(pool)), treasury, false);
        vm.stopPrank();

        // Two tokens swept (EURC, DAI); one skipped (USDC).
        assertEq(swept, 2, "exactly two tokens should be swept");
        assertEq(skipped, 1, "exactly one (zero-accrued) token should be skipped");

        // Treasury received EXACTLY the accrued amount for each swept token.
        assertEq(eurc.balanceOf(treasury) - eurcTreasuryBefore, eurcAccrued, "treasury EURC += accrued");
        assertEq(dai.balanceOf(treasury) - daiTreasuryBefore, daiAccrued, "treasury DAI += accrued");
        // Skipped token: treasury untouched.
        assertEq(usdc.balanceOf(treasury) - usdcTreasuryBefore, 0, "treasury USDC unchanged (skipped)");

        // Accruals zeroed on the swept tokens; the skipped token stays at zero.
        assertEq(pool.protocolFeesAccrued(address(eurc)), 0, "EURC accrual must be zeroed");
        assertEq(pool.protocolFeesAccrued(address(dai)), 0, "DAI accrual must be zeroed");
        assertEq(pool.protocolFeesAccrued(address(usdc)), 0, "USDC accrual stays zero");
    }

    /// @notice The per-token helper `_sweepToken` returns swept=false (and touches
    /// nothing) for a zero-accrued token — the explicit skip branch.
    function test_sweepToken_skipsZeroAccrued() public {
        _seedAllThree(); // no swaps => zero protocol fees anywhere
        assertEq(pool.protocolFeesAccrued(address(usdc)), 0, "precondition: USDC accrual zero");

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.startPrank(owner);
        SweepResult memory r = _sweepToken(IArcoraDexPool(address(pool)), address(usdc), treasury, false);
        vm.stopPrank();

        assertFalse(r.swept, "zero-accrued token must be reported as skipped");
        assertEq(r.amount, 0, "skipped token reports zero amount");
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "treasury untouched for skipped token");
    }

    /// @notice The per-token helper moves the FULL accrued balance to the treasury
    /// and zeroes the accrual.
    function test_sweepToken_movesFullAccrual() public {
        _accrueFeesOnEurcAndDai();
        uint256 eurcAccrued = pool.protocolFeesAccrued(address(eurc));
        assertGt(eurcAccrued, 0);

        uint256 treasuryBefore = eurc.balanceOf(treasury);
        vm.startPrank(owner);
        SweepResult memory r = _sweepToken(IArcoraDexPool(address(pool)), address(eurc), treasury, false);
        vm.stopPrank();

        assertTrue(r.swept, "non-zero accrual must be swept");
        assertEq(r.amount, eurcAccrued, "reported amount must equal accrued");
        assertEq(eurc.balanceOf(treasury) - treasuryBefore, eurcAccrued, "treasury += full accrual");
        assertEq(pool.protocolFeesAccrued(address(eurc)), 0, "accrual zeroed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Negative path — owner gate.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Sweeping from a NON-owner must revert at the Pool's `onlyOwner` gate
    /// on `withdrawProtocolFees` (OZ `OwnableUnauthorizedAccount`). This is the
    /// on-chain backstop behind the script's pre-broadcast `msg.sender == owner()`
    /// guard: even if the broadcaster check were bypassed, the Pool itself rejects
    /// a non-owner sweep.
    /// @dev Driven through an external `SweepRunner` so the Pool genuinely sees a
    /// non-owner `msg.sender` (the runner). The runner re-uses the SAME inherited
    /// `_sweepToken` script logic, so this exercises the real sweep, not a stub.
    function test_sweep_fromNonOwnerReverts() public {
        _accrueFeesOnEurcAndDai();
        assertGt(pool.protocolFeesAccrued(address(eurc)), 0, "precondition: fees accrued");

        SweepRunner runner = new SweepRunner(); // a non-owner caller
        assertTrue(address(runner) != owner, "runner must not be the Pool owner");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(runner)));
        runner.sweepToken(IArcoraDexPool(address(pool)), address(eurc), treasury);
    }

    /// @notice Symmetry with the script's `whenNotPaused` precondition (audit I-3):
    /// when the Pool is paused, the underlying `withdrawProtocolFees` reverts
    /// `PoolPaused`, so the sweep cannot run even by the owner. Here the runner is
    /// made the Pool owner (so the onlyOwner gate passes and the whenNotPaused gate
    /// is the one that fires), proving pause — not ownership — is what blocks it.
    function test_sweep_whenPausedReverts() public {
        _accrueFeesOnEurcAndDai();

        // Hand Pool ownership to the runner so it clears onlyOwner; the revert must
        // then come from the whenNotPaused gate, not the ownership gate.
        SweepRunner runner = new SweepRunner();
        vm.prank(owner);
        pool.transferOwnership(address(runner));
        runner.acceptPoolOwnership(IArcoraDexPool(address(pool)));
        assertEq(_poolOwner(address(pool)), address(runner), "runner must own the Pool");

        runner.poolPause(IArcoraDexPool(address(pool)));

        vm.expectRevert(IArcoraDexPool.PoolPaused.selector);
        runner.sweepToken(IArcoraDexPool(address(pool)), address(eurc), treasury);
    }
}

/// @dev External caller that re-uses the SAME `SweepProtocolFees._sweepToken` logic
/// the production `run()` uses, but exposes it via an EXTERNAL function so the Pool
/// observes the runner as `msg.sender`. This lets the negative tests exercise the
/// real sweep code against the Pool's `onlyOwner` / `whenNotPaused` gates without
/// the internal-call `vm.expectRevert`/prank flattening problem.
contract SweepRunner is SweepProtocolFees {
    function sweepToken(IArcoraDexPool pool, address token, address treasury) external returns (SweepResult memory) {
        return _sweepToken(pool, token, treasury, false);
    }

    function acceptPoolOwnership(IArcoraDexPool pool) external {
        IOwnable2Step(address(pool)).acceptOwnership();
    }

    function poolPause(IArcoraDexPool pool) external {
        pool.pause();
    }
}

interface IOwnable2Step {
    function acceptOwnership() external;
}
