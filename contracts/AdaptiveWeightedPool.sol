// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.24;

import "forge-std/console.sol";

import { ISwapFeePercentageBounds } from "@balancer-labs/v3-interfaces/contracts/vault/ISwapFeePercentageBounds.sol";
import {
    IUnbalancedLiquidityInvariantRatioBounds
} from "@balancer-labs/v3-interfaces/contracts/vault/IUnbalancedLiquidityInvariantRatioBounds.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    IWeightedPool,
    WeightedPoolDynamicData,
    WeightedPoolImmutableData
} from "@balancer-labs/v3-interfaces/contracts/pool-weighted/IWeightedPool.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { WeightedMath } from "@balancer-labs/v3-solidity-utils/contracts/math/WeightedMath.sol";
import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";
import { PoolInfo } from "@balancer-labs/v3-pool-utils/contracts/PoolInfo.sol";

import { IAdaptiveWeightedPool } from "./interfaces/IAdaptiveWeightedPool.sol";

contract AdaptiveWeightedPool is IAdaptiveWeightedPool, BalancerPoolToken, PoolInfo, Version {
    /// @dev Struct with data for deploying a new WeightedPool. `normalizedWeights` length must match `numTokens`.
    struct NewPoolParams {
        string name;
        string symbol;
        address managedPool;
        uint256[] normalizedWeights;
        uint256[] initialVirtualBalances;
        string version;
    }

    /**
     * @notice `getRate` from `IRateProvider` was called on a Weighted Pool.
     * @dev It is not safe to nest Weighted Pools as WITH_RATE tokens in other pools, where they function as their own
     * rate provider. The default `getRate` implementation from `BalancerPoolToken` computes the BPT rate using the
     * invariant, which has a non-trivial (and non-linear) error. Without the ability to specify a rounding direction,
     * the rate could be manipulable.
     *
     * It is fine to nest Weighted Pools as STANDARD tokens, or to use them with external rate providers that are
     * stable and have at most 1 wei of rounding error (e.g., oracle-based).
     */
    error WeightedPoolBptRateUnsupported();

    // Fees are 18-decimal, floating point values, which will be stored in the Vault using 24 bits.
    // This means they have 0.00001% resolution (i.e., any non-zero bits < 1e11 will cause precision loss).
    // Minimum values help make the math well-behaved (i.e., the swap fee should overwhelm any rounding error).
    // Maximum values protect users by preventing permissioned actors from setting excessively high swap fees.
    uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint256 private constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%
    uint256 private constant _MAX_TOKENS = 8;

    // A minimum normalized weight imposes a maximum weight ratio. We need this due to limitations in the
    // implementation of the fixed point power function, as these ratios are often exponents.
    uint256 internal constant _MIN_WEIGHT = 1e16; // 1%

    address internal immutable _managedPool;

    uint256[] internal _weights;
    uint256[] internal _targetWeights;
    uint256 internal _startChangingTime;
    uint256 internal _endChangingTime;
    uint256[] internal _virtualBalances;

    constructor(
        NewPoolParams memory params,
        IVault vault
    ) BalancerPoolToken(vault, params.name, params.symbol) PoolInfo(vault) Version(params.version) {
        InputHelpers.ensureInputLengthMatch(params.normalizedWeights.length, params.initialVirtualBalances.length);

        if (params.managedPool == address(0)) {
            revert InvalidManagedPool();
        } else if (params.normalizedWeights.length > _MAX_TOKENS) {
            revert IVaultErrors.MaxTokens();
        }

        _managedPool = params.managedPool;

        // Ensure each normalized weight is above the minimum.
        uint256 normalizedSum = 0;
        for (uint256 i = 0; i < params.normalizedWeights.length; ++i) {
            uint256 normalizedWeight = params.normalizedWeights[i];
            if (normalizedWeight < _MIN_WEIGHT) {
                revert MinWeight();
            }

            normalizedSum += normalizedWeight;
            _weights.push(normalizedWeight);

            _targetWeights.push(0); // Initialize target weights to zero
            _virtualBalances.push(params.initialVirtualBalances[i]);
        }

        // Ensure that the normalized weights sum to ONE.
        if (normalizedSum != FixedPoint.ONE) {
            revert NormalizedWeightInvariant();
        }
    }

    modifier onlyManagedPool() {
        if (msg.sender != _managedPool) {
            revert SenderNotAllowed();
        }
        _;
    }

    /// @inheritdoc IBasePool
    function computeInvariant(uint256[] memory balancesLiveScaled18, Rounding rounding) public view returns (uint256) {
        function(uint256[] memory, uint256[] memory) internal pure returns (uint256) _upOrDown = rounding ==
            Rounding.ROUND_UP
            ? WeightedMath.computeInvariantUp
            : WeightedMath.computeInvariantDown;

        for (uint256 i = 0; i < balancesLiveScaled18.length; i++) {
            balancesLiveScaled18[i] += _virtualBalances[i];
        }

        return _upOrDown(_getNormalizedWeights(), balancesLiveScaled18);
    }

    /// @inheritdoc IBasePool
    function computeBalance(
        uint256[] memory balancesLiveScaled18,
        uint256 tokenInIndex,
        uint256 invariantRatio
    ) external view returns (uint256 newBalance) {
        return
            WeightedMath.computeBalanceOutGivenInvariant(
                balancesLiveScaled18[tokenInIndex] + _virtualBalances[tokenInIndex],
                _getNormalizedWeight(tokenInIndex),
                invariantRatio
            );
    }

    /// @inheritdoc IWeightedPool
    function getNormalizedWeights() external view returns (uint256[] memory) {
        return _getNormalizedWeights();
    }

    /// @inheritdoc IBasePool
    function onSwap(PoolSwapParams memory request) public virtual returns (uint256) {
        uint256 virtualBalanceTokenIn = _virtualBalances[request.indexIn];
        uint256 virtualBalanceTokenOut = _virtualBalances[request.indexOut];

        uint256 balanceTokenInScaled18 = request.balancesScaled18[request.indexIn] + virtualBalanceTokenIn;
        uint256 balanceTokenOutScaled18 = request.balancesScaled18[request.indexOut] + virtualBalanceTokenOut;

        uint256 amountInScaled18;
        uint256 amountOutScaled18;
        if (request.kind == SwapKind.EXACT_IN) {
            amountInScaled18 = request.amountGivenScaled18;
            amountOutScaled18 = WeightedMath.computeOutGivenExactIn(
                balanceTokenInScaled18,
                _getNormalizedWeight(request.indexIn),
                balanceTokenOutScaled18,
                _getNormalizedWeight(request.indexOut),
                amountInScaled18
            );
        } else {
            // Fees are added after scaling happens, to reduce the complexity of the rounding direction analysis.
            amountOutScaled18 = request.amountGivenScaled18;
            amountInScaled18 = WeightedMath.computeInGivenExactOut(
                balanceTokenInScaled18,
                _getNormalizedWeight(request.indexIn),
                balanceTokenOutScaled18,
                _getNormalizedWeight(request.indexOut),
                amountOutScaled18
            );
        }

        if (virtualBalanceTokenIn > 0) {
            if (amountInScaled18 <= virtualBalanceTokenIn) {
                virtualBalanceTokenIn -= amountInScaled18;
            } else {
                virtualBalanceTokenIn = 0;
            }

            _virtualBalances[request.indexIn] = virtualBalanceTokenIn;
        }

        return request.kind == SwapKind.EXACT_IN ? amountOutScaled18 : amountInScaled18;
    }

    function updateWeights(
        uint256[] memory newWeights,
        uint256 startChangingTime,
        uint256 endChangingTime
    ) external onlyManagedPool {
        InputHelpers.ensureInputLengthMatch(_weights.length, newWeights.length);

        uint256 normalizedSum = 0;
        for (uint256 i = 0; i < newWeights.length; i++) {
            uint256 normalizedWeight = newWeights[i];
            console.log("new weight", normalizedWeight);

            _weights[i] = _computeWeight(i);
            _targetWeights[i] = normalizedWeight;

            normalizedSum += normalizedWeight;
        }

        // Ensure that the normalized weights sum to ONE.
        if (normalizedSum != FixedPoint.ONE) {
            revert NormalizedWeightInvariant();
        }

        if (startChangingTime < block.timestamp || endChangingTime < startChangingTime) {
            revert InvalidTimeRange();
        }

        _startChangingTime = startChangingTime;
        _endChangingTime = endChangingTime;
    }

    function setVirtualBalances(uint256 tokenIndex, uint256 amountScaled18) external onlyManagedPool {
        _virtualBalances[tokenIndex] = amountScaled18;
    }

    function getVirtualBalances() external view returns (uint256[] memory virtualBalances) {
        return _virtualBalances;
    }

    function getChangingWeightsInfo()
        external
        view
        returns (
            uint256 startChangingTime,
            uint256 endChangingTime,
            uint256[] memory initialWeights,
            uint256[] memory targetWeights
        )
    {
        return (_startChangingTime, _endChangingTime, _weights, _targetWeights);
    }

    function _getNormalizedWeight(uint256 tokenIndex) internal view virtual returns (uint256) {
        if (tokenIndex >= _weights.length) {
            revert IVaultErrors.InvalidToken();
        }

        return _computeWeight(tokenIndex);
    }

    function _getNormalizedWeights() internal view virtual returns (uint256[] memory) {
        uint256[] memory computedWeights = new uint256[](_weights.length);
        for (uint256 i = 0; i < _weights.length; i++) {
            computedWeights[i] = _computeWeight(i);
        }

        return computedWeights;
    }

    function _computeWeight(uint256 tokenIndex) private view returns (uint256) {
        uint256 startChangingTime = _startChangingTime;
        uint256 endChangingTime = _endChangingTime;

        if (startChangingTime == 0 && endChangingTime == 0) {
            return _weights[tokenIndex];
        }

        if (block.timestamp < startChangingTime) {
            return _weights[tokenIndex];
        } else if (block.timestamp >= endChangingTime) {
            return _targetWeights[tokenIndex];
        }

        uint256 targetWeight = _targetWeights[tokenIndex];
        uint256 currentWeight = _weights[tokenIndex];

        if (currentWeight == targetWeight) {
            return currentWeight;
        }

        uint256 timeElapsed = block.timestamp - startChangingTime;
        uint256 totalDuration = endChangingTime - startChangingTime;
        int256 weightDifference = int256(targetWeight) - int256(currentWeight);
        int256 differencePerTime = (weightDifference * int256(timeElapsed)) / int256(totalDuration);

        return uint256(int256(currentWeight) + differencePerTime);
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMinimumSwapFeePercentage() external pure returns (uint256) {
        return _MIN_SWAP_FEE_PERCENTAGE;
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMaximumSwapFeePercentage() external pure returns (uint256) {
        return _MAX_SWAP_FEE_PERCENTAGE;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMinimumInvariantRatio() external pure returns (uint256) {
        return WeightedMath._MIN_INVARIANT_RATIO;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMaximumInvariantRatio() external pure returns (uint256) {
        return WeightedMath._MAX_INVARIANT_RATIO;
    }

    /// @inheritdoc IWeightedPool
    function getWeightedPoolDynamicData() external view virtual returns (WeightedPoolDynamicData memory data) {
        data.balancesLiveScaled18 = _vault.getCurrentLiveBalances(address(this));
        (, data.tokenRates) = _vault.getPoolTokenRates(address(this));
        data.staticSwapFeePercentage = _vault.getStaticSwapFeePercentage((address(this)));
        data.totalSupply = totalSupply();

        PoolConfig memory poolConfig = _vault.getPoolConfig(address(this));
        data.isPoolInitialized = poolConfig.isPoolInitialized;
        data.isPoolPaused = poolConfig.isPoolPaused;
        data.isPoolInRecoveryMode = poolConfig.isPoolInRecoveryMode;
    }

    /// @inheritdoc IWeightedPool
    function getWeightedPoolImmutableData() external view virtual returns (WeightedPoolImmutableData memory data) {
        data.tokens = _vault.getPoolTokens(address(this));
        (data.decimalScalingFactors, ) = _vault.getPoolTokenRates(address(this));
        data.normalizedWeights = _getNormalizedWeights();
    }

    /// @inheritdoc IRateProvider
    function getRate() public pure override returns (uint256) {
        revert WeightedPoolBptRateUnsupported();
    }
}
