// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 }         from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IArcoraDexLP }  from "./interfaces/IArcoraDexLP.sol";
import { IArcoraDexPool } from "./interfaces/IArcoraDexPool.sol";

/// @title ArcoraDexLP
/// @notice ERC20 LP receipt token. Mint/burn permission immutably bound to a single minter (the Pool).
contract ArcoraDexLP is ERC20, IArcoraDexLP {
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

    /// @dev Propagates the pool's min-hold lock through LP transfers.
    /// On a normal transfer (from != 0 && to != 0), notifies the pool so it can
    /// extend the recipient's `lastMintAt` to max(to.lastMintAt, from.lastMintAt).
    /// Mints (from == 0) and burns (to == 0) skip the notification — they are
    /// already gated by the pool's deposit/withdraw paths.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0)) {
            IArcoraDexPool(MINTER).notifyLPTransfer(from, to);
        }
    }
}
