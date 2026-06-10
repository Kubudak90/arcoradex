// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexRegistryV2} from "../../src/v2/ArcoraDexRegistryV2.sol";
import {IArcoraDexRegistryV2} from "../../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "../../src/v2/interfaces/IOracleAdapterV2.sol";
import {FeeBandMathV2} from "../../src/v2/lib/FeeBandMathV2.sol";
import {MockOracleAdapterV2} from "./mocks/MockOracleAdapterV2.sol";
import {MintableERC20} from "../../src/testnet/MintableERC20.sol";

contract ArcoraDexRegistryV2Test is Test {
    ArcoraDexRegistryV2 reg;
    MockOracleAdapterV2 adapter;
    MintableERC20 usdc;
    address owner = makeAddr("owner");
    address rando = makeAddr("rando");

    function _defaultBands() internal pure returns (FeeBandMathV2.Band[] memory b) {
        b = new FeeBandMathV2.Band[](4);
        b[0] = FeeBandMathV2.Band({upperHealthBps: 10_000, rateBps: 5});
        b[1] = FeeBandMathV2.Band({upperHealthBps: 7_500, rateBps: 20});
        b[2] = FeeBandMathV2.Band({upperHealthBps: 5_000, rateBps: 75});
        b[3] = FeeBandMathV2.Band({upperHealthBps: 2_500, rateBps: 300});
    }

    function _cfg(FeeBandMathV2.Band[] memory bands) internal view returns (IArcoraDexRegistryV2.TokenConfigV2 memory) {
        return IArcoraDexRegistryV2.TokenConfigV2({
            decimals: 6,
            isActive: true,
            adapter: IOracleAdapterV2(address(adapter)),
            minimumReserveUsd: 1_000_000e18,
            targetReserveUsd: 2_000_000e18,
            depositCapUsd: 0,
            bands: bands
        });
    }

    function setUp() public {
        adapter = new MockOracleAdapterV2();
        usdc = new MintableERC20("USDC", "USDC", 6, owner);
        reg = new ArcoraDexRegistryV2(owner);
    }

    function test_listToken_happyPath() public {
        vm.prank(owner);
        reg.listToken(address(usdc), _cfg(_defaultBands()));
        assertTrue(reg.isActive(address(usdc)));
        assertEq(reg.tokensLength(), 1);
    }

    function test_listToken_onlyOwner() public {
        vm.prank(rando);
        vm.expectRevert();
        reg.listToken(address(usdc), _cfg(_defaultBands()));
    }

    function test_reject_targetNotAboveMin() public {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = _cfg(_defaultBands());
        c.targetReserveUsd = c.minimumReserveUsd; // not strictly greater
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidReserveBounds.selector, address(usdc)));
        reg.listToken(address(usdc), c);
    }

    // O1: a zero protected floor would let priced ops drain a reserve fully (§6.2).
    function test_reject_zeroMinimumReserve() public {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = _cfg(_defaultBands());
        c.minimumReserveUsd = 0; // floor must be non-zero
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidReserveBounds.selector, address(usdc)));
        reg.listToken(address(usdc), c);
    }

    // Dedicated InvalidDecimals out-of-range coverage: 0 (too low) and 19 (too high) both revert.
    function test_reject_decimalsOutOfRange() public {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = _cfg(_defaultBands());
        c.decimals = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidDecimals.selector, uint8(0)));
        reg.listToken(address(usdc), c);

        c.decimals = 19;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidDecimals.selector, uint8(19)));
        reg.listToken(address(usdc), c);
    }

    function test_reject_firstBandNot100pct() public {
        FeeBandMathV2.Band[] memory b = _defaultBands();
        b[0].upperHealthBps = 9_000; // must be 10_000
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidBands.selector, address(usdc)));
        reg.listToken(address(usdc), _cfg(b));
    }

    function test_reject_nonDescendingBands() public {
        FeeBandMathV2.Band[] memory b = _defaultBands();
        b[2].upperHealthBps = 7_500; // equal to b[1], not strictly descending
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidBands.selector, address(usdc)));
        reg.listToken(address(usdc), _cfg(b));
    }

    function test_reject_decreasingRate() public {
        FeeBandMathV2.Band[] memory b = _defaultBands();
        b[3].rateBps = 10; // lower than b[2] (75) — rate must NOT decrease as health falls
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidBands.selector, address(usdc)));
        reg.listToken(address(usdc), _cfg(b));
    }

    function test_reject_rateAboveMax() public {
        FeeBandMathV2.Band[] memory b = _defaultBands();
        b[3].rateBps = 1_001; // > MAX_FEE_BPS (1000)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.InvalidBands.selector, address(usdc)));
        reg.listToken(address(usdc), _cfg(b));
    }

    function test_reject_decimalMismatch() public {
        IArcoraDexRegistryV2.TokenConfigV2 memory c = _cfg(_defaultBands());
        c.decimals = 18; // usdc is 6
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IArcoraDexRegistryV2.TokenDecimalMismatch.selector, address(usdc), 18, 6)
        );
        reg.listToken(address(usdc), c);
    }

    // O2: setPool must reject the zero address so the I-1 deactivate-with-reserves guard
    // cannot be silently bypassed by un-wiring the pool.
    function test_setPool_rejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IArcoraDexRegistryV2.ZeroAddress.selector);
        reg.setPool(address(0));
    }

    function test_setPool_and_deactivate_guard() public {
        vm.startPrank(owner);
        reg.listToken(address(usdc), _cfg(_defaultBands()));
        reg.setPool(address(this)); // this contract implements reserves() below
        vm.stopPrank();
        _reserveOf[address(usdc)] = 5; // non-zero
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.TokenHasReserves.selector, address(usdc)));
        reg.deactivateToken(address(usdc));
        _reserveOf[address(usdc)] = 0;
        vm.prank(owner);
        reg.deactivateToken(address(usdc));
        assertFalse(reg.isActive(address(usdc)));
    }

    function test_remove_requires_inactive() public {
        vm.prank(owner);
        reg.listToken(address(usdc), _cfg(_defaultBands()));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArcoraDexRegistryV2.TokenStillActive.selector, address(usdc)));
        reg.removeToken(address(usdc));
    }

    mapping(address => uint256) internal _reserveOf;

    function reserves(address token) external view returns (uint256) {
        return _reserveOf[token];
    }
}
