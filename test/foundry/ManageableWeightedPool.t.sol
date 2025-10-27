// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.24;

import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { AdaptiveWeightedPool } from "../../contracts/AdaptiveWeightedPool.sol";

contract AdaptiveWeightedPoolTest is BaseVaultTest {
    using ArrayHelpers for *;

    address fakeWrappedBPT = makeAddr("fakeWrappedBPT");

    function setUp() public override {}

    function testChangingWeights__Fuzz(
        uint256 tokenCount,
        uint256[8] memory weightsRaw,
        uint256[8] memory newWeightsRaw
    ) public {
        tokenCount = bound(tokenCount, 2, 8);
        uint256[] memory weights = new uint256[](tokenCount);
        uint256[] memory newWeights = new uint256[](tokenCount);
        uint256[] memory initialVirtualBalances = new uint256[](tokenCount);

        uint256 sumRemainder = 1e18;
        uint256 newSumRemainder = 1e18;
        for (uint256 i = 0; i < weights.length; i++) {
            weights[i] = bound(weightsRaw[i], 1e16, sumRemainder);
            sumRemainder -= weights[i];

            newWeights[i] = bound(newWeightsRaw[i], 1e16, newSumRemainder);
            newSumRemainder -= newWeights[i];
        }
        weights[0] += sumRemainder > 0 ? sumRemainder : 0;
        newWeights[0] += newSumRemainder > 0 ? newSumRemainder : 0;

        AdaptiveWeightedPool adaptiveWeightedPool = new AdaptiveWeightedPool(
            AdaptiveWeightedPool.NewPoolParams({
                name: "Test Pool",
                symbol: "TP",
                wrappedBpt: fakeWrappedBPT,
                normalizedWeights: weights,
                initialVirtualBalances: initialVirtualBalances,
                version: "0.0.1"
            }),
            vault
        );
    }
}
