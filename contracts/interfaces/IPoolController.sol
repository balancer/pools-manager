// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TokenConfig } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

interface IPoolController {
    error InvalidTimeRange();

    function updateWeights(uint256[] memory newWeights, uint256 startChangingTime, uint256 endChangingTime) external;
    function updateTokens(
        IERC20[] memory newTokens,
        TokenConfig[] memory newTokensInfo,
        uint256[] memory newWeights,
        uint256[] memory newVirtualBalances
    ) external;

    function enableToken() external;

    function disableToken(IERC20 token) external;

    function migrateToNewManager(address) external;
}
