// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcoraDexPoolV2} from "../../../src/v2/ArcoraDexPoolV2.sol";
import {ArcoraDexRegistryV2} from "../../../src/v2/ArcoraDexRegistryV2.sol";
import {ArcoraDexLPV2} from "../../../src/v2/ArcoraDexLPV2.sol";
import {IArcoraDexRegistryV2} from "../../../src/v2/interfaces/IArcoraDexRegistryV2.sol";
import {IOracleAdapterV2} from "../../../src/v2/interfaces/IOracleAdapterV2.sol";
import {FeeBandMathV2} from "../../../src/v2/lib/FeeBandMathV2.sol";
import {MockOracleAdapterV2} from "../mocks/MockOracleAdapterV2.sol";
import {MintableERC20} from "../../../src/testnet/MintableERC20.sol";

/// @notice Shared V2 test scaffold: Registry+Pool+LP, 3 stablecoin mocks (USDC/EURC/USDT),
/// a single mock adapter priced at $1.00, and the default §7 fee schedule.
abstract contract V2Fixture is Test {
    ArcoraDexPoolV2 internal pool;
    ArcoraDexRegistryV2 internal reg;
    ArcoraDexLPV2 internal lp;
    MockOracleAdapterV2 internal adapter;
    MintableERC20 internal usdc; // 6
    MintableERC20 internal eurc; // 6
    MintableERC20 internal usdt; // 6

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint16 internal constant PROT_SHARE = 1_000; // 10%

    function _defaultBands() internal pure returns (FeeBandMathV2.Band[] memory b) {
        b = new FeeBandMathV2.Band[](4);
        b[0] = FeeBandMathV2.Band({upperHealthBps: 10_000, rateBps: 5}); // 75-100% : 0.05%
        b[1] = FeeBandMathV2.Band({upperHealthBps: 7_500, rateBps: 20}); // 50-75%  : 0.20%
        b[2] = FeeBandMathV2.Band({upperHealthBps: 5_000, rateBps: 75}); // 25-50%  : 0.75%
        b[3] = FeeBandMathV2.Band({upperHealthBps: 2_500, rateBps: 300}); // 0-25%   : 3.00%
    }

    function _cfg(uint256 minUsd, uint256 targetUsd) internal view returns (IArcoraDexRegistryV2.TokenConfigV2 memory) {
        return IArcoraDexRegistryV2.TokenConfigV2({
            decimals: 6,
            isActive: true,
            adapter: IOracleAdapterV2(address(adapter)),
            minimumReserveUsd: minUsd,
            targetReserveUsd: targetUsd,
            depositCapUsd: 0,
            protocolFeeShareBps: PROT_SHARE,
            bands: _defaultBands()
        });
    }

    function _deployV2() internal {
        adapter = new MockOracleAdapterV2();
        usdc = new MintableERC20("USD Coin", "USDC", 6, owner);
        eurc = new MintableERC20("Euro Coin", "EURC", 6, owner);
        usdt = new MintableERC20("Tether", "USDT", 6, owner);

        reg = new ArcoraDexRegistryV2(owner);
        pool = new ArcoraDexPoolV2(address(reg), PROT_SHARE, owner);
        lp = ArcoraDexLPV2(address(pool.LP()));

        // All three priced at $1.00, safe.
        adapter.setPrice(address(usdc), 1e18, true);
        adapter.setPrice(address(eurc), 1e18, true);
        adapter.setPrice(address(usdt), 1e18, true);

        vm.startPrank(owner);
        // min 1,000,000 USD ; target 2,000,000 USD ; available = 1,000,000 USD.
        reg.listToken(address(usdc), _cfg(1_000_000e18, 2_000_000e18));
        reg.listToken(address(eurc), _cfg(1_000_000e18, 2_000_000e18));
        reg.listToken(address(usdt), _cfg(1_000_000e18, 2_000_000e18));
        reg.setPool(address(pool));
        pool.setPauseGuardian(guardian);
        vm.stopPrank();
    }

    function _mint(MintableERC20 t, address to, uint256 amt) internal {
        vm.prank(owner);
        t.mint(to, amt);
    }

    function _seed(MintableERC20 t, address who, uint256 amt) internal {
        _mint(t, who, amt);
        vm.startPrank(who);
        t.approve(address(pool), amt);
        pool.deposit(address(t), amt, 0, block.timestamp + 1);
        vm.stopPrank();
    }
}
