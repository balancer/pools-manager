// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IManagedPool is IERC20, IERC20Metadata {
    error SenderNotAllowed();
    error InitializedAlready();

    function getBptToken() external view returns (address);

    function migrateToNewManager(address newManager) external;

    function migratePool(address newBptToken, uint256 coefficient) external;

    function updateWeights(uint256[] memory newWeights, uint256 startChangingTime, uint256 endChangingTime) external;

    function setVirtualBalances(uint256 tokenIndex, uint256 amountScaled18) external;
}
