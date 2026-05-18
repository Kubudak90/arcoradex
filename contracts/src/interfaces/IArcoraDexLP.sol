// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IArcoraDexLP is IERC20 {
    error NotMinter();
    error ZeroAddress();

    event MinterSet(address indexed minter);

    // Justification [naming-convention]: UPPER_CASE marks an immutable, per project convention.
    // slither-disable-next-line naming-convention
    function MINTER() external view returns (address);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
