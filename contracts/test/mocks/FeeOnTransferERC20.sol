// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MintableERC20} from "../../src/testnet/MintableERC20.sol";

/// @notice Test-only fee-on-transfer (deflationary) token. Burns `feeBps` of every
/// wallet→wallet transfer to 0xdead. Mint (from == 0) and burn (to == 0) are exempt,
/// so the owner-minted starting balances are exact. Used to exercise L-10: the pool
/// must credit the *measured* balance delta, not the requested amount.
contract FeeOnTransferERC20 is MintableERC20 {
    uint16 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address initialOwner, uint16 feeBps_)
        MintableERC20(name_, symbol_, decimals_, initialOwner)
    {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / 10_000;
            if (fee > 0) {
                super._update(from, address(0xdead), fee);
                value -= fee;
            }
        }
        super._update(from, to, value);
    }
}
