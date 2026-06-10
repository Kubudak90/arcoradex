// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IArcoraDexLPV2} from "./interfaces/IArcoraDexLPV2.sol";
import {IArcoraDexPoolV2} from "./interfaces/IArcoraDexPoolV2.sol";

/// @title ArcoraDexLPV2
/// @notice ERC20 LP receipt. Mint/burn permission immutably bound to the Pool.
/// Mirrors the V1 sender-gate min-hold hook (H-1): a non-zero wallet-to-wallet
/// transfer reverts unless the SENDER's own min-hold has elapsed.
contract ArcoraDexLPV2 is ERC20, IArcoraDexLPV2 {
    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    address public immutable override MINTER;

    constructor(address minter_) ERC20("Arcora DEX LP V2", "ADEX-LP2") {
        if (minter_ == address(0)) revert ZeroAddress();
        MINTER = minter_;
        emit MinterSet(minter_);
    }

    function mint(address to, uint256 amount) external override {
        if (msg.sender != MINTER) revert NotMinter();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override {
        if (msg.sender != MINTER) revert NotMinter();
        _burn(from, amount);
    }

    /// @dev H-1 sender-gate: defers to the Pool on non-zero wallet-to-wallet transfers.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && value > 0) {
            IArcoraDexPoolV2(MINTER).notifyLPTransfer(from, to);
        }
    }
}
