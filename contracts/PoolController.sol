// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PoolConfig, TokenConfig, TokenInfo } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { IAdaptiveWeightedPool } from "./interfaces/IAdaptiveWeightedPool.sol";

import { AdaptiveWeightedPoolFactory } from "./AdaptiveWeightedPoolFactory.sol";
import { IManagedPool } from "./interfaces/IManagedPool.sol";
import { IPoolController } from "./interfaces/IPoolController.sol";

contract PoolController is IPoolController, Ownable2Step {
    using FixedPoint for uint256;

    error InvalidToken();
    error ExceedsMaxTokens();

    uint256 internal constant _MAX_TOKENS = 8;

    uint256 internal constant _MIN_CHANGE_DURATION = 1 days;
    uint256 internal constant _MAX_CHANGE_DURATION = 10 days;

    IVault internal immutable _vault;
    IRouter internal immutable _router;
    IManagedPool internal immutable _ManagedPool;
    AdaptiveWeightedPoolFactory internal immutable _poolFactory;

    constructor(
        address initialOwner,
        IManagedPool ManagedPool,
        IVault vault,
        IRouter router,
        AdaptiveWeightedPoolFactory poolFactory
    ) Ownable(initialOwner) {
        _ManagedPool = ManagedPool;
        _vault = vault;
        _router = router;
        _poolFactory = poolFactory;
    }

    function updateWeights(
        uint256[] memory newWeights,
        uint256 startChangingTime,
        uint256 endChangingTime
    ) external onlyOwner {
        _updateWeights(newWeights, startChangingTime, endChangingTime);
    }

    function _updateWeights(uint256[] memory newWeights, uint256 startChangingTime, uint256 endChangingTime) internal {
        uint256 duration = endChangingTime - startChangingTime;
        if (duration < _MIN_CHANGE_DURATION || duration > _MAX_CHANGE_DURATION) {
            revert InvalidTimeRange();
        }

        _ManagedPool.updateWeights(newWeights, startChangingTime, endChangingTime);
    }

    function removeToken(IERC20 token, uint256 startChangingTime, uint256 endChangingTime) external onlyOwner {
        IAdaptiveWeightedPool pool = IAdaptiveWeightedPool(_ManagedPool.getBptToken());
        uint256[] memory weights = pool.getNormalizedWeights();
        IERC20[] memory tokens = _vault.getPoolTokens(address(pool));

        int256 indexToRemove = _findTokenIndex(tokens, token);
        if (indexToRemove == -1) {
            revert InvalidToken();
        }

        uint256 weight = weights[uint256(indexToRemove)];
        uint256 factor = FixedPoint.ONE.divDown(FixedPoint.ONE - weight);

        weights[uint256(indexToRemove)] = 0;

        // TODO: rounding issues?
        for (uint256 i = 0; i < weights.length; i++) {
            if (i == uint256(indexToRemove)) {
                continue;
            }

            weights[i] = weights[i].mulDown(factor);
        }

        _updateWeights(weights, startChangingTime, endChangingTime);
    }

    function addToken(IERC20 token, uint256 weight) external onlyOwner {
        IAdaptiveWeightedPool pool = IAdaptiveWeightedPool(_ManagedPool.getBptToken());

        (IERC20[] memory tokens, TokenInfo[] memory tokensInfo, , ) = _vault.getPoolTokenInfo(address(pool));
        uint256[] memory weights = pool.getNormalizedWeights();
        //   TokenConfig[] memory newTokensInfo,
        //    if (newTokensInfo.length > _MAX_TOKENS) {
        //     revert ExceedsMaxTokens();
        // }

        uint256 factor = (FixedPoint.ONE - weight).divDown(FixedPoint.ONE);

        int256 index = _findTokenIndex(tokens, token);
        bool tokenExists = index != -1;
        if (tokenExists) {
            // TODO: rounding issues?
            for (uint256 i = 0; i < weights.length; i++) {
                weights[i] = weights[i].mulDown(factor);
            }
            _updateWeights(weights, block.timestamp, block.timestamp);
        } else {
            uint256 newTokensLength = tokens.length + 1;
            IERC20[] memory newTokens = new IERC20[](newTokensLength);
            uint256[] memory newWeights = new uint256[](newTokensLength);

            bool inserted;
            uint256 j;
            for (uint256 i = 0; i < tokens.length; i++) {
                if (!inserted && address(token) < address(tokens[i])) {
                    newTokens[j] = token;
                    newWeights[j] = weight;
                    inserted = true;
                    j++;
                }

                newTokens[j] = tokens[i];
                newWeights[j] = weights[i].mulDown(factor);
                j++;
            }

            PoolConfig memory poolConfig = _vault.getPoolConfig(pool);
            address newPool = _poolFactory.create(
                AdaptiveWeightedPoolFactory.CreationParams({
                    name: IERC20Metadata(pool).name(),
                    symbol: IERC20Metadata(pool).symbol(),
                    tokens: newTokensInfo,
                    normalizedWeights: newWeights,
                    virtualBalances: newVirtualBalances,
                    roleAccounts: _vault.getPoolRoleAccounts(pool),
                    swapFeePercentage: poolConfig.staticSwapFeePercentage,
                    poolHooksContract: _vault.getHooksConfig(pool).hooksContract,
                    enableDonation: poolConfig.liquidityManagement.enableDonation,
                    disableUnbalancedLiquidity: poolConfig.liquidityManagement.disableUnbalancedLiquidity,
                    wrappedBpt: address(_ManagedPool),
                    salt: bytes32(block.timestamp)
                })
            );

            uint256[] memory minAmountsOut = new uint256[](originalTokensInfo.length);
            uint256 removeBptAmount = _ManagedPool.balanceOf(address(this));
            IERC20(pool).approve(address(_router), removeBptAmount);
            uint256[] memory amountsOut = _router.removeLiquidityProportional(
                pool,
                removeBptAmount,
                minAmountsOut,
                false,
                bytes("")
            );

            // Stack too deep
            IERC20[] memory _newTokens = newTokens;
            uint256[] memory exactAmountsIn = new uint256[](newTokensInfo.length);

            // Here we iterate through the list of previous tokens, get the amountsOut, and fill them into exactAmountsIn for the new list.
            for (uint256 i = 0; i < originalTokensInfo.length; i++) {
                int256 index = _findTokenIndex(_newTokens, originalTokens[i]);

                if (index == -1) {
                    continue;
                }
                exactAmountsIn[uint256(index)] = amountsOut[i];
                originalTokens[i].transfer(address(_vault), exactAmountsIn[uint256(index)]);
            }

            uint256 bptAmountOut = _router.initialize(newPool, _newTokens, exactAmountsIn, 0, false, bytes(""));

            _ManagedPool.migratePool(newPool, removeBptAmount.mulDown(bptAmountOut));
        }
    }

    function migrateToNewManager(address) external view onlyOwner {
        revert("Not implemented");
    }

    /***************************************************************************
                                Internal functions                                
    ***************************************************************************/

    function _findTokenIndex(IERC20[] memory tokens, IERC20 token) internal pure returns (int256) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != token) {
                continue;
            }

            return int256(i);
        }

        return -1;
    }
}
