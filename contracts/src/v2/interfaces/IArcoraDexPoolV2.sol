// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IArcoraDexPoolV2 {
    /// @notice Called by the LP token on every non-zero wallet-to-wallet transfer to
    /// enforce the sender-gate min-hold lock (H-1). Only the LP contract may call it.
    function notifyLPTransfer(address from, address to) external;
}
