// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 }        from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IArcoraDexLP } from "./interfaces/IArcoraDexLP.sol";

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
}
