// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IArcoraDexLP} from "./interfaces/IArcoraDexLP.sol";
import {IArcoraDexPool} from "./interfaces/IArcoraDexPool.sol";

/// @title ArcoraDexLP
/// @notice ERC20 LP receipt token. Mint/burn permission immutably bound to a single minter (the Pool).
contract ArcoraDexLP is ERC20, IArcoraDexLP {
    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    address public immutable override MINTER;

    constructor(address minter_) ERC20("Arcora DEX LP", "ADEX-LP") {
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

    /// @dev Enforces the pool's min-hold lock on LP transfers (H-1 sender-gate).
    /// On a non-zero wallet-to-wallet transfer (from != 0 && to != 0 && value > 0)
    /// the pool reverts unless the SENDER's own min-hold has elapsed. The recipient's
    /// clock is never bumped. Zero-value transfers, mints (from == 0) and burns
    /// (to == 0) skip the notification: zero-value transfers move no claim and could
    /// otherwise be weaponised to grief a victim's lock, while mint/burn are already
    /// gated by the pool's deposit/withdraw paths.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && value > 0) {
            IArcoraDexPool(MINTER).notifyLPTransfer(from, to);
        }
    }
}
