// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.24;

import "forge-std/console.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { WeightedPool } from "@balancer-labs/v3-pool-weighted/contracts/WeightedPool.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { AdaptiveWeightedPool } from "../../contracts/AdaptiveWeightedPool.sol";

contract AdaptiveWeightedPoolTest is BaseVaultTest {
    using ArrayHelpers for *;

    address fakeManagedPool = makeAddr("fakeManagedPool");

    function testChangingWeights() public {
        uint256 startTime = block.timestamp + 1 hours;
        uint256 endTime = block.timestamp + 2 hours;

        uint256 tokenCount = 4;
        uint256[] memory weights = new uint256[](tokenCount);
        weights[0] = 4e17; // 0.4
        weights[1] = 3e17; // 0.3
        weights[2] = 2e17; // 0.2
        weights[3] = 1e17; // 0.1

        uint256[] memory newWeights = new uint256[](tokenCount);
        newWeights[0] = 1e17; // 0.1
        newWeights[1] = 2e17; // 0.2
        newWeights[2] = 3e17; // 0.3
        newWeights[3] = 4e17; // 0.4

        uint256[] memory initialVirtualBalances = new uint256[](tokenCount);

        AdaptiveWeightedPool adaptiveWeightedPool = new AdaptiveWeightedPool(
            AdaptiveWeightedPool.NewPoolParams({
                name: "Test Pool",
                symbol: "TP",
                managedPool: fakeManagedPool,
                normalizedWeights: weights,
                initialVirtualBalances: initialVirtualBalances,
                version: "0.0.1"
            }),
            vault
        );

        vm.prank(fakeManagedPool);
        adaptiveWeightedPool.updateWeights(newWeights, startTime, endTime);

        {
            vm.warp(block.timestamp + 30 minutes);
            (
                uint256 _startChangingTime,
                uint256 _endChangingTime,
                uint256[] memory _initialWeights,
                uint256[] memory _targetWeights
            ) = adaptiveWeightedPool.getChangingWeightsInfo();
            assertEq(_startChangingTime, startTime, "startChangingTime mismatch (after 30 mins)");
            assertEq(_endChangingTime, endTime, "endChangingTime mismatch (after 30 mins)");
            assertEq(_initialWeights, weights, "initialWeights mismatch (after 30 mins)");
            assertEq(_targetWeights, newWeights, "targetWeights mismatch (after 30 mins)");
        }

        uint256 halfTime = startTime + (endTime - startTime) / 2;
        vm.warp(halfTime);
        {
            (
                uint256 _startChangingTime,
                uint256 _endChangingTime,
                uint256[] memory _initialWeights,
                uint256[] memory _targetWeights
            ) = adaptiveWeightedPool.getChangingWeightsInfo();
            assertEq(_startChangingTime, startTime, "startChangingTime mismatch (after mid time)");
            assertEq(_endChangingTime, endTime, "endChangingTime mismatch (after mid time)");
            assertEq(_initialWeights, weights, "initialWeights mismatch (after mid time)");
            assertEq(_targetWeights, newWeights, "targetWeights mismatch (after mid time)");
        }

        uint256[] memory currentWeights = adaptiveWeightedPool.getNormalizedWeights();
        for (uint256 i = 0; i < tokenCount; i++) {
            int256 differencePerTime = ((int256(newWeights[i]) - int256(weights[i])) *
                int256(block.timestamp - startTime)) / int256(endTime - startTime);

            assertEq(
                currentWeights[i],
                uint256(int256(weights[i]) + differencePerTime),
                "current weight mismatch (after mid time)"
            );
        }

        vm.warp(endTime + 1);
        {
            (
                uint256 _startChangingTime,
                uint256 _endChangingTime,
                uint256[] memory _initialWeights,
                uint256[] memory _targetWeights
            ) = adaptiveWeightedPool.getChangingWeightsInfo();
            assertEq(_startChangingTime, startTime, "startChangingTime mismatch (after endTime)");
            assertEq(_endChangingTime, endTime, "endChangingTime mismatch (after endTime)");
            assertEq(_initialWeights, weights, "initialWeights mismatch (after endTime)");
            assertEq(_targetWeights, newWeights, "targetWeights mismatch (after endTime)");
        }

        currentWeights = adaptiveWeightedPool.getNormalizedWeights();
        for (uint256 i = 0; i < tokenCount; i++) {
            assertEq(currentWeights[i], newWeights[i], "current weight mismatch (after endTime)");
        }
    }

    function testVirtualBalances() public {
        uint256 tokenCount = 4;
        uint256[] memory weights = new uint256[](tokenCount);
        weights[0] = 4e17; // 0.4
        weights[1] = 3e17; // 0.3
        weights[2] = 2e17; // 0.2
        weights[3] = 1e17; // 0.1

        uint256[] memory initialVirtualBalances = new uint256[](tokenCount);
        initialVirtualBalances[0] = 1000e18;

        uint256[] memory balances = new uint256[](tokenCount);
        balances[1] = 2000e18;
        balances[2] = 3000e18;
        balances[3] = 4000e18;

        AdaptiveWeightedPool adaptiveWeightedPool = new AdaptiveWeightedPool(
            AdaptiveWeightedPool.NewPoolParams({
                name: "Adaptive Weighted Pool",
                symbol: "AWP",
                managedPool: fakeManagedPool,
                normalizedWeights: weights,
                initialVirtualBalances: initialVirtualBalances,
                version: "0.0.1"
            }),
            vault
        );
        PoolSwapParams memory request = PoolSwapParams({
            kind: SwapKind.EXACT_IN,
            amountGivenScaled18: 10e18,
            balancesScaled18: balances,
            indexIn: 0,
            indexOut: 1,
            router: address(0),
            userData: bytes("")
        });

        uint256 amountOut = adaptiveWeightedPool.onSwap(request);
        uint256[] memory currentVirtualBalances = adaptiveWeightedPool.getVirtualBalances();
        assertEq(
            currentVirtualBalances[0],
            initialVirtualBalances[0] - request.amountGivenScaled18,
            "virtual balance token 0 mismatch"
        );
        for (uint256 i = 1; i < tokenCount; i++) {
            assertEq(currentVirtualBalances[i], initialVirtualBalances[i], "virtual balance token mismatch");
        }

        WeightedPool weightedPool = new WeightedPool(
            WeightedPool.NewPoolParams({
                name: "Test Pool",
                symbol: "TP",
                numTokens: tokenCount,
                normalizedWeights: weights,
                version: "0.0.1"
            }),
            vault
        );
        uint256[] memory weightedPoolBalances = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            weightedPoolBalances[i] = balances[i] + initialVirtualBalances[i];
        }

        uint256 expectedAmountOut = weightedPool.onSwap(
            PoolSwapParams({
                kind: SwapKind.EXACT_IN,
                amountGivenScaled18: request.amountGivenScaled18,
                balancesScaled18: weightedPoolBalances,
                indexIn: 0,
                indexOut: 1,
                router: address(0),
                userData: bytes("")
            })
        );
        assertEq(amountOut, expectedAmountOut, "amount out mismatch");
    }

    function assertEq(uint256[] memory a, uint256[] memory b, string memory errMsg) internal pure override {
        require(a.length == b.length, errMsg);
        for (uint256 i = 0; i < a.length; i++) {
            assertEq(a[i], b[i], errMsg);
        }
    }
}
