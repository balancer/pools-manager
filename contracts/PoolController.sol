// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/console.sol";

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

    IManagedPool internal _managedPool;

    IVault internal immutable _vault;
    IRouter internal immutable _router;
    AdaptiveWeightedPoolFactory internal immutable _poolFactory;

    constructor(
        address initialOwner,
        IVault vault,
        IRouter router,
        AdaptiveWeightedPoolFactory poolFactory
    ) Ownable(initialOwner) {
        _vault = vault;
        _router = router;
        _poolFactory = poolFactory;
    }

    function initialize(IManagedPool managedPool) external onlyOwner {
        if (address(_managedPool) != address(0)) {
            revert AlreadyInitialized();
        }

        _managedPool = managedPool;
    }

    function updateWeights(
        uint256[] memory newWeights,
        uint256 startChangingTime,
        uint256 endChangingTime
    ) external onlyOwner {
        uint256 duration = endChangingTime - startChangingTime;

        if (duration < _MIN_CHANGE_DURATION || duration > _MAX_CHANGE_DURATION) {
            revert InvalidTimeRange();
        }

        _managedPool.updateWeights(newWeights, startChangingTime, endChangingTime);
    }

    function removeToken(IERC20 token, uint256 startChangingTime, uint256 endChangingTime) external onlyOwner {
        IAdaptiveWeightedPool pool = IAdaptiveWeightedPool(_managedPool.getBptToken());
        uint256[] memory weights = pool.getNormalizedWeights();
        IERC20[] memory tokens = _vault.getPoolTokens(address(pool));

        int256 indexToRemove = _findTokenIndex(tokens, token);
        if (indexToRemove == -1) {
            revert InvalidToken();
        }

        uint256 weight = weights[uint256(indexToRemove)];
        uint256 factor = FixedPoint.ONE.divDown(FixedPoint.ONE - weight);

        weights[uint256(indexToRemove)] = 0;

        uint256 sumWeights = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            if (i == uint256(indexToRemove)) {
                continue;
            }

            weights[i] = weights[i].mulDown(factor);
            sumWeights += weights[i];
        }

        uint256 remainder = FixedPoint.ONE - sumWeights;
        for (uint256 i = 0; i < weights.length; i++) {
            if (weights[i] == 0) {
                continue;
            }

            weights[i] += remainder;
            break;
        }

        _managedPool.updateWeights(weights, startChangingTime, endChangingTime);
    }

    function addToken(
        TokenConfig memory tokenConfig,
        uint256 weight,
        uint256 initialVirtualBalance
    ) external onlyOwner {
        address pool = _managedPool.getBptToken();

        (IERC20[] memory tokens, TokenInfo[] memory tokensInfo, , ) = _vault.getPoolTokenInfo(address(pool));

        uint256 newTokensLength = tokens.length + 1;
        if (newTokensLength > _MAX_TOKENS) {
            revert ExceedsMaxTokens();
        }

        int256 index = _findTokenIndex(tokens, tokenConfig.token);

        if (index != -1) {
            uint256 factor = (FixedPoint.ONE - weight).divDown(FixedPoint.ONE);
            uint256[] memory weights = IAdaptiveWeightedPool(pool).getNormalizedWeights();

            uint256 sumWeights = weight;
            weights[uint256(index)] = weight;
            for (uint256 i = 0; i < weights.length; i++) {
                if (i == uint256(index)) {
                    continue;
                }

                weights[i] = weights[i].mulDown(factor);
                sumWeights += weights[i];
            }

            uint256 remainder = FixedPoint.ONE - sumWeights;
            for (uint256 i = 0; i < weights.length; i++) {
                if (weights[i] == 0) {
                    continue;
                }

                weights[i] += remainder;
                break;
            }

            _managedPool.updateWeights(weights, block.timestamp, block.timestamp);
            _managedPool.setVirtualBalances(uint256(index), initialVirtualBalance);
            return;
        } else {
            PoolConfig memory poolConfig = _vault.getPoolConfig(pool);
            AdaptiveWeightedPoolFactory.CreationParams memory poolParams = AdaptiveWeightedPoolFactory.CreationParams({
                name: IERC20Metadata(pool).name(),
                symbol: IERC20Metadata(pool).symbol(),
                tokens: new TokenConfig[](newTokensLength),
                normalizedWeights: new uint256[](newTokensLength),
                virtualBalances: new uint256[](newTokensLength),
                roleAccounts: _vault.getPoolRoleAccounts(pool),
                swapFeePercentage: poolConfig.staticSwapFeePercentage,
                poolHooksContract: _vault.getHooksConfig(pool).hooksContract,
                enableDonation: poolConfig.liquidityManagement.enableDonation,
                disableUnbalancedLiquidity: poolConfig.liquidityManagement.disableUnbalancedLiquidity,
                managedPool: address(_managedPool),
                salt: bytes32(block.timestamp)
            });

            IERC20[] memory newTokens = new IERC20[](newTokensLength);

            {
                uint256 factor = (FixedPoint.ONE - weight).divDown(FixedPoint.ONE);
                uint256[] memory weights = IAdaptiveWeightedPool(pool).getNormalizedWeights();

                // Stack too deep
                TokenInfo[] memory _tokensInfo = tokensInfo;
                TokenConfig memory _tokenConfig = tokenConfig;
                uint256 _weight = weight;
                uint256 _initialVirtualBalance = initialVirtualBalance;
                IERC20[] memory _tokens = tokens;

                // TODO: refactor this part
                uint256[] memory virtualBalances = IAdaptiveWeightedPool(pool).getVirtualBalances();
                bool inserted;
                uint256 j;
                for (uint256 i = 0; i < _tokens.length + 1; i++) {
                    if (i == _tokens.length) {
                        if (!inserted) {
                            newTokens[j] = _tokenConfig.token;
                            poolParams.normalizedWeights[j] = _weight;
                            poolParams.virtualBalances[j] = _initialVirtualBalance;
                            poolParams.tokens[j] = _tokenConfig;
                            j++;
                        }
                        break;
                    }

                    console.log("token address:", address(_tokens[i]));
                    console.log("_tokenConfig.token address:", address(_tokenConfig.token));
                    if (!inserted && address(_tokenConfig.token) < address(_tokens[i])) {
                        newTokens[j] = _tokenConfig.token;
                        poolParams.normalizedWeights[j] = _weight;
                        poolParams.virtualBalances[j] = _initialVirtualBalance;
                        poolParams.tokens[j] = _tokenConfig;
                        inserted = true;
                        j++;

                        console.log("aaa: ", weights[i]);
                    }

                    newTokens[j] = _tokens[i];
                    poolParams.normalizedWeights[j] = weights[i].mulDown(factor);
                    poolParams.virtualBalances[j] = virtualBalances[i];
                    poolParams.tokens[j] = TokenConfig({
                        token: _tokens[i],
                        tokenType: _tokensInfo[i].tokenType,
                        rateProvider: _tokensInfo[i].rateProvider,
                        paysYieldFees: _tokensInfo[i].paysYieldFees
                    });
                    j++;

                    console.log(weights[i]);
                }
            }

            address newPool = _poolFactory.create(poolParams);

            uint256 removeBptAmount = _managedPool.balanceOf(address(this));
            IERC20(pool).approve(address(_router), removeBptAmount);
            uint256[] memory amountsOut = _router.removeLiquidityProportional(
                pool,
                removeBptAmount,
                new uint256[](tokensInfo.length),
                false,
                bytes("")
            );

            uint256[] memory exactAmountsIn = new uint256[](newTokens.length);

            // Here we iterate through the list of previous tokens, get the amountsOut, and fill them into exactAmountsIn for the new list.
            for (uint256 i = 0; i < tokensInfo.length; i++) {
                int256 tokenIndex = _findTokenIndex(newTokens, tokens[i]);
                if (tokenIndex == -1) {
                    continue;
                }

                exactAmountsIn[uint256(tokenIndex)] = amountsOut[i];
                tokens[i].transfer(address(_vault), exactAmountsIn[uint256(tokenIndex)]);
            }

            uint256 bptAmountOut = _router.initialize(newPool, newTokens, exactAmountsIn, 0, false, bytes(""));

            _managedPool.migratePool(newPool, removeBptAmount.mulDown(bptAmountOut));
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
