// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable }       from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }  from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CumulativeDeviationGuard
/// @notice Tracks a 24 h tumbling-window price deviation per token. Permissionless
/// `record` updates the window and emits structured events. Off-chain monitoring
/// consumes `PriceObserved` / `CircuitBreakerTripped` and decides whether to
/// trigger the Pause Guardian Safe. No on-chain auto-pause in P3.
contract CumulativeDeviationGuard is Ownable2Step {
    struct WindowState {
        uint256 startPrice1e18;
        uint256 startTimestamp;
    }
    struct Config {
        uint32 maxCumulativeBps;
        uint32 windowSeconds;
    }

    mapping(address token => WindowState) public windows;
    mapping(address token => Config)      public configs;

    event PriceObserved(address indexed token, uint256 price1e18, uint256 timestamp);
    event CircuitBreakerTripped(address indexed token, uint256 deviationBps, uint256 timestamp);
    event ConfigUpdated(address indexed token, uint32 maxCumulativeBps, uint32 windowSeconds);

    error InvalidConfig(uint32 maxCumulativeBps, uint32 windowSeconds);
    error PriceMustBePositive();

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setConfig(address token, uint32 maxCumulativeBps_, uint32 windowSeconds_)
        external
        onlyOwner
    {
        if (
            maxCumulativeBps_ == 0 || maxCumulativeBps_ > 10_000 ||
            windowSeconds_   < 60  || windowSeconds_  > 30 days
        ) {
            revert InvalidConfig(maxCumulativeBps_, windowSeconds_);
        }
        configs[token] = Config(maxCumulativeBps_, windowSeconds_);
        emit ConfigUpdated(token, maxCumulativeBps_, windowSeconds_);
    }

    function record(address token, uint256 price1e18) external {
        if (price1e18 == 0) revert PriceMustBePositive();

        Config memory cfg = configs[token];
        if (cfg.windowSeconds == 0) {
            // Token not tracked — emit observation and return without trip evaluation.
            emit PriceObserved(token, price1e18, block.timestamp);
            return;
        }

        WindowState memory win = windows[token];
        if (win.startTimestamp == 0 || block.timestamp - win.startTimestamp > cfg.windowSeconds) {
            // First observation or window expired — reset.
            windows[token] = WindowState(price1e18, block.timestamp);
            emit PriceObserved(token, price1e18, block.timestamp);
            return;
        }

        emit PriceObserved(token, price1e18, block.timestamp);

        uint256 diff = price1e18 > win.startPrice1e18
            ? price1e18 - win.startPrice1e18
            : win.startPrice1e18 - price1e18;
        uint256 deviationBps = (diff * 10_000) / win.startPrice1e18;
        if (deviationBps > cfg.maxCumulativeBps) {
            emit CircuitBreakerTripped(token, deviationBps, block.timestamp);
        }
    }
}
