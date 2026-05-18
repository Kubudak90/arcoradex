// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable }       from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step }  from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CumulativeDeviationGuard
/// @notice Tracks a 24 h tumbling-window price deviation per token. Permissionless
/// `record` updates the window and emits structured events. Off-chain monitoring
/// consumes `PriceObserved` / `CircuitBreakerTripped` and decides whether to
/// trigger the Pause Guardian Safe. No on-chain auto-pause in P3.
///
/// @dev Tumbling-window limitation: deviation is measured against a per-window
/// anchor price (the first observation of each window). A slow drift that stays
/// just under the cap within each window but accumulates across many windows is
/// intentionally NOT detected. This tumbling-window approach is a deliberate P3
/// MVP trade-off — it is significantly cheaper (gas and off-chain complexity) than
/// a true rolling-window implementation. A rolling/multi-window detector is
/// deferred to P5.
///
/// @dev Permissionless-record trust boundary: `record` is unauthenticated — anyone
/// can call it, and the first caller in a fresh window anchors `startPrice1e18`.
/// An adversary can therefore anchor the window at a favorable or unfavorable price,
/// or spam observations to force window resets. This is acceptable in P3 ONLY
/// because the contract is event-only: nothing on-chain is gated on the output of
/// `record`. The off-chain monitor MUST treat `PriceObserved` and
/// `CircuitBreakerTripped` as untrusted hints and re-validate the price and anchor
/// against its own trusted feed before paging the Pause Guardian. If a future phase
/// wires on-chain auto-pause to this contract, `record` MUST first be made
/// keeper-only.
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
        // Integer division truncates, so deviationBps rounds DOWN. Combined with
        // the strict `>` trip test this biases slightly toward under-tripping at
        // the sub-bps margin — acceptable for an advisory (event-only) breaker.
        uint256 deviationBps = (diff * 10_000) / win.startPrice1e18;
        if (deviationBps > cfg.maxCumulativeBps) {
            emit CircuitBreakerTripped(token, deviationBps, block.timestamp);
        }
    }
}
