// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IPoolVersion } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IPoolVersion.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    TokenConfig,
    PoolRoleAccounts,
    LiquidityManagement
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BasePoolFactory } from "@balancer-labs/v3-pool-utils/contracts/BasePoolFactory.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";

import { AdaptiveWeightedPool } from "./AdaptiveWeightedPool.sol";

/**
 * @notice General Weighted Pool factory
 * @dev This is the most general factory, which allows up to eight tokens and arbitrary weights.
 */
contract AdaptiveWeightedPoolFactory is IPoolVersion, BasePoolFactory, Version {
    struct CreationParams {
        string name;
        string symbol;
        TokenConfig[] tokens;
        uint256[] normalizedWeights;
        uint256[] virtualBalances;
        PoolRoleAccounts roleAccounts;
        uint256 swapFeePercentage;
        address poolHooksContract;
        bool enableDonation;
        bool disableUnbalancedLiquidity;
        address managedPool;
        bytes32 salt;
    }

    string private _poolVersion;

    constructor(
        IVault vault,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        string memory poolVersion
    ) BasePoolFactory(vault, pauseWindowDuration, type(AdaptiveWeightedPool).creationCode) Version(factoryVersion) {
        _poolVersion = poolVersion;
    }

    /// @inheritdoc IPoolVersion
    function getPoolVersion() external view returns (string memory) {
        return _poolVersion;
    }

    function create(CreationParams memory params) external returns (address pool) {
        if (params.roleAccounts.poolCreator != address(0)) {
            revert StandardPoolWithCreator();
        }

        LiquidityManagement memory liquidityManagement = getDefaultLiquidityManagement();
        liquidityManagement.enableDonation = params.enableDonation;
        // disableUnbalancedLiquidity must be set to true if a hook has the flag enableHookAdjustedAmounts = true.
        liquidityManagement.disableUnbalancedLiquidity = params.disableUnbalancedLiquidity;

        pool = _create(
            abi.encode(
                AdaptiveWeightedPool.NewPoolParams({
                    name: params.name,
                    symbol: params.symbol,
                    managedPool: params.managedPool,
                    initialVirtualBalances: params.virtualBalances,
                    normalizedWeights: params.normalizedWeights,
                    version: _poolVersion
                }),
                getVault()
            ),
            params.salt
        );

        _registerPoolWithVault(
            pool,
            params.tokens,
            params.swapFeePercentage,
            false, // not exempt from protocol fees
            params.roleAccounts,
            params.poolHooksContract,
            liquidityManagement
        );
    }
}
