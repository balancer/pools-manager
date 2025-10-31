// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TokenConfig } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

interface IPoolController {
    error InvalidTimeRange();
    error AlreadyInitialized();

    function updateWeights(uint256[] memory newWeights, uint256 startChangingTime, uint256 endChangingTime) external;

    function removeToken(IERC20 token, uint256 startChangingTime, uint256 endChangingTime) external;

    function addToken(TokenConfig memory tokenConfig, uint256 weight, uint256 initialVirtualBalance) external;

    function migrateToNewManager(address) external;
}
