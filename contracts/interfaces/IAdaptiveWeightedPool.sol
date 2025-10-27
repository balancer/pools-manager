// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-weighted/IWeightedPool.sol";

/// @notice Manageable Weighted pool interface.
interface IAdaptiveWeightedPool is IWeightedPool {
    error InvalidWrappedBptLink();
    error SenderNotAllowed();
    error InvalidTimeRange();

    function updateWeights(uint256[] memory newWeights, uint256 startChangingTime, uint256 endChangingTime) external;
    function getVirtualBalances() external view returns (uint256[] memory virtualBalances);
    function getChangingWeightsInfo()
        external
        view
        returns (
            uint256 startChangingTime,
            uint256 endChangingTime,
            uint256[] memory initialWeights,
            uint256[] memory targetWeights
        );
}
