// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";
import { MockCalculationRule } from "../../../../contracts/test/MockCalculationRule.sol";
import { MockPool } from "../../../../contracts/test/MockPool.sol";
import { MockQuantAMMMathGuard } from "../../../../contracts/test/MockQuantAMMMathGuard.sol";

contract QuantAMMMathGuardTest is Test {
    using PRBMathSD59x18 for int256;

    MockCalculationRule mockCalculationRule;
    MockPool mockPool;
    MockQuantAMMMathGuard mockQuantAMMMathGuard;

    int256 constant UPDATE_INTERVAL = 1800e18; // 1800 seconds in fixed-point format
    int128 constant LAMBDA = 5e17; // Lambda is 0.5 in fixed-point format

    function setUp() public {
        mockCalculationRule = new MockCalculationRule();
        mockPool = new MockPool(3600, 1e18, address(mockCalculationRule)); // 3600 sec update interval
        mockQuantAMMMathGuard = new MockQuantAMMMathGuard();
    }

    function testClampWeights_AllWeightsWithinGuardRail() public view {
        int256[] memory weights = new int256[](3);
        weights[0] = 0.3e18;
        weights[1] = 0.3e18;
        weights[2] = 0.4e18;

        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory clampedWeights = mockQuantAMMMathGuard.mockClampWeights(weights, absoluteWeightGuardRail);

        assertEq(clampedWeights[0], 0.3e18, "Weight should remain unchanged");
        assertEq(clampedWeights[1], 0.3e18, "Weight should remain unchanged");
        assertEq(clampedWeights[2], 0.4e18, "Weight should remain unchanged");
    }

    function testClampWeights_WeightBelowGuardRail() public view {
        int256[] memory weights = new int256[](3);
        weights[0] = 0.05e18;
        weights[1] = 0.45e18;
        weights[2] = 0.5e18;

        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory clampedWeights = mockQuantAMMMathGuard.mockClampWeights(weights, absoluteWeightGuardRail);

        assertEq(clampedWeights[0], 0.1e18, "Weight should be clamped to minimum guard rail");
        assertEq(clampedWeights[1], 0.426315789473684210e18, "Weight should remain unchanged");
        assertEq(clampedWeights[2], 0.473684210526315789e18, "Weight should be adjusted proportionally");
    }

    function testClampWeights_WeightAboveGuardRail() public view {
        int256[] memory weights = new int256[](3);
        weights[0] = 0.8e18;
        weights[1] = 0.1e18;
        weights[2] = 0.1e18;

        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory clampedWeights = mockQuantAMMMathGuard.mockClampWeights(weights, absoluteWeightGuardRail);

        assertEq(clampedWeights[0], 0.8e18, "Weight should remain unchanged");
        assertEq(clampedWeights[1], 0.1e18, "Weight should remain unchanged");
        assertEq(clampedWeights[2], 0.1e18, "Weight should remain unchanged");
    }

    function testClampWeights_WeightExceedsMax() public view {
        int256[] memory weights = new int256[](3);
        weights[0] = 0.95e18;
        weights[1] = 0.025e18;
        weights[2] = 0.025e18;

        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory clampedWeights = mockQuantAMMMathGuard.mockClampWeights(weights, absoluteWeightGuardRail);

        assertEq(clampedWeights[0], 0.8e18, "Weight should be clamped to maximum guard rail");
        assertEq(clampedWeights[1], 0.1e18, "Weight should be adjusted proportionally");
        assertEq(clampedWeights[2], 0.1e18, "Weight should be adjusted proportionally");
    }

    function testClampWeights_ProportionalAdjustment() public view {
        int256[] memory weights = new int256[](3);
        weights[0] = 0.2e18;
        weights[1] = 0.2e18;
        weights[2] = 0.6e18;

        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory clampedWeights = mockQuantAMMMathGuard.mockClampWeights(weights, absoluteWeightGuardRail);

        assertEq(clampedWeights[0], 0.2e18, "Weight should remain unchanged");
        assertEq(clampedWeights[1], 0.2e18, "Weight should remain unchanged");
        assertEq(clampedWeights[2], 0.6e18, "Weight should remain unchanged");
    }

    function testClampWeights_ZeroWeights() public view {
        int256[] memory weights = new int256[](3);
        weights[0] = 0;
        weights[1] = 0;
        weights[2] = 0;

        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory clampedWeights = mockQuantAMMMathGuard.mockClampWeights(weights, absoluteWeightGuardRail);

        assertEq(clampedWeights[0], 0.1e18, "Weight should be clamped to minimum guard rail");
        assertEq(clampedWeights[1], 0.1e18, "Weight should be clamped to minimum guard rail");
        assertEq(clampedWeights[2], 0.1e18, "Weight should be clamped to minimum guard rail");
    }

    function testClampWeights_NegativeWeights() public view {
        int256[] memory weights = new int256[](3);
        weights[0] = -0.1e18;
        weights[1] = 0.5e18;
        weights[2] = 0.6e18;

        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory clampedWeights = mockQuantAMMMathGuard.mockClampWeights(weights, absoluteWeightGuardRail);

        //TODO MW review
        assertEq(clampedWeights[0], 0.1e18, "Negative weight should be clamped to minimum guard rail");
        assertEq(clampedWeights[1], 0.409090909090909091e18, "Weight should be adjusted proportionally");
        assertEq(clampedWeights[2], 0.490909090909090909e18, "Weight should be adjusted proportionally");
    }

    function testClampWeights_SumExceedsOne() public view {
        int256[] memory weights = new int256[](3);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        weights[2] = 0.5e18;

        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory clampedWeights = mockQuantAMMMathGuard.mockClampWeights(weights, absoluteWeightGuardRail);

        assertEq(clampedWeights[0], 0.333333333333333333e18, "Weight should be adjusted proportionally");
        assertEq(clampedWeights[1], 0.333333333333333333e18, "Weight should be adjusted proportionally");
        assertEq(clampedWeights[2], 0.333333333333333333e18, "Weight should be adjusted proportionally");
    }

    function testClampWeights_SumLessThanOne() public view {
        int256[] memory weights = new int256[](3);
        weights[0] = 0.1e18;
        weights[1] = 0.1e18;
        weights[2] = 0.1e18;

        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory clampedWeights = mockQuantAMMMathGuard.mockClampWeights(weights, absoluteWeightGuardRail);

        assertEq(clampedWeights[0], 0.1e18, "Weight should remain unchanged");
        assertEq(clampedWeights[1], 0.1e18, "Weight should remain unchanged");
        assertEq(clampedWeights[2], 0.1e18, "Weight should remain unchanged");
    }

    function testNormalizeWeightUpdates_RoundingErrorPositive() public view {
        int256[] memory prevWeights = new int256[](3);
        prevWeights[0] = 0.4e18;
        prevWeights[1] = 0.3e18;
        prevWeights[2] = 0.3e18;

        int256[] memory newWeights = new int256[](3);
        newWeights[0] = 0.45e18;
        newWeights[1] = 0.25e18;
        newWeights[2] = 0.3e18;

        int256 epsilonMax = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockNormalizeWeightUpdates(prevWeights, newWeights, epsilonMax);

        int256 sum = res[0] + res[1] + res[2];
        assertEq(sum, 1e18, "Weights do not sum to 1");

        // Check if rounding error is handled correctly
        assertEq(res[1], 0.25e18 + (1e18 - sum), "Rounding error not handled correctly");
    }

    function testNormalizeWeightUpdates_RoundingErrorNegative() public view {
        int256[] memory prevWeights = new int256[](3);
        prevWeights[0] = 0.4e18;
        prevWeights[1] = 0.3e18;
        prevWeights[2] = 0.3e18;

        int256[] memory newWeights = new int256[](3);
        newWeights[0] = 0.45e18;
        newWeights[1] = 0.25e18;
        newWeights[2] = 0.3e18;

        int256 epsilonMax = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockNormalizeWeightUpdates(prevWeights, newWeights, epsilonMax);

        int256 sum = res[0] + res[1] + res[2];
        assertEq(sum, 1e18, "Weights do not sum to 1");

        // Check if rounding error is handled correctly
        assertEq(res[0], 0.45e18 - (sum - 1e18), "Rounding error not handled correctly");
    }

    function testNormalizeWeightUpdates_MaxAbsChange() public view {
        int256[] memory prevWeights = new int256[](3);
        prevWeights[0] = 0.4e18;
        prevWeights[1] = 0.3e18;
        prevWeights[2] = 0.3e18;

        int256[] memory newWeights = new int256[](3);
        newWeights[0] = 0.6e18;
        newWeights[1] = 0.2e18;
        newWeights[2] = 0.2e18;

        int256 epsilonMax = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockNormalizeWeightUpdates(prevWeights, newWeights, epsilonMax);

        int256 sum = res[0] + res[1] + res[2];
        assertEq(sum, 1e18, "Weights do not sum to 1");

        // Check if maxAbsChange is handled correctly
        assertLe((res[0] - prevWeights[0]).abs(), epsilonMax, "MaxAbsChange not handled correctly");
    }

    function testNormalizeWeightUpdates_ZeroWeights() public view {
        int256[] memory prevWeights = new int256[](3);
        prevWeights[0] = 0;
        prevWeights[1] = 0;
        prevWeights[2] = 0;

        int256[] memory newWeights = new int256[](3);
        newWeights[0] = 0.4e18;
        newWeights[1] = 0.3e18;
        newWeights[2] = 0.3e18;

        int256 epsilonMax = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockNormalizeWeightUpdates(prevWeights, newWeights, epsilonMax);

        int256 sum = res[0] + res[1] + res[2];
        assertEq(sum, 1e18, "Weights do not sum to 1");
    }

    function testNormalizeWeightUpdates_ProportionalAdjustment() public view {
        int256[] memory prevWeights = new int256[](3);
        prevWeights[0] = 0.2e18;
        prevWeights[1] = 0.2e18;
        prevWeights[2] = 0.6e18;

        int256[] memory newWeights = new int256[](3);
        newWeights[0] = 0.3e18;
        newWeights[1] = 0.3e18;
        newWeights[2] = 0.4e18;

        int256 epsilonMax = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockNormalizeWeightUpdates(prevWeights, newWeights, epsilonMax);

        int256 sum = res[0] + res[1] + res[2];
        assertEq(sum, 1e18, "Weights do not sum to 1");
    }

    function testNormalizeWeightUpdates_ZeroEpsilonMax() public view {
        int256[] memory prevWeights = new int256[](3);
        prevWeights[0] = 0.4e18;
        prevWeights[1] = 0.3e18;
        prevWeights[2] = 0.3e18;

        int256[] memory newWeights = new int256[](3);
        newWeights[0] = 0.45e18;
        newWeights[1] = 0.25e18;
        newWeights[2] = 0.3e18;

        int256 epsilonMax = 0;

        int256[] memory res = mockQuantAMMMathGuard.mockNormalizeWeightUpdates(prevWeights, newWeights, epsilonMax);

        int256 sum = res[0] + res[1] + res[2];
        assertEq(sum, 1e18, "Weights do not sum to 1");
    }

    function testNormalizeWeightUpdates_MaxEpsilonMax() public view {
        int256[] memory prevWeights = new int256[](3);
        prevWeights[0] = 0.4e18;
        prevWeights[1] = 0.3e18;
        prevWeights[2] = 0.3e18;

        int256[] memory newWeights = new int256[](3);
        newWeights[0] = 0.45e18;
        newWeights[1] = 0.25e18;
        newWeights[2] = 0.3e18;

        int256 epsilonMax = 1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockNormalizeWeightUpdates(prevWeights, newWeights, epsilonMax);

        int256 sum = res[0] + res[1] + res[2];
        assertEq(sum, 1e18, "Weights do not sum to 1");
    }

    // Weight Guards
    // the correct behavior.
    // 2 tokens below epsilon max
    function testFuzz_WeightGuards2TokensBelowEpsilonMax(int256 epsilonMax, int256 absGuardRail) public view {
        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory newWeights = new int256[](2);
        newWeights[0] = 0.55e18;
        newWeights[1] = 0.45e18;

        int256 boundEpsilonMax = bound(epsilonMax, 0.1e18, 0.9999999e18);
        int256 boundAbsGuardRail = bound(absGuardRail, 1, 0.44e18);

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            boundEpsilonMax,
            boundAbsGuardRail
        );

        assertEq(res[0], newWeights[0]);
        assertEq(res[1], newWeights[1]);
    }

    // 2 tokens above epsilon max
    function testFuzz_WeightGuards2TokensAboveEpsilonMax(int256 newWeight) public view {
        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory newWeights = new int256[](2);
        newWeights[0] = bound(newWeight, 0.61e18, 0.9e18);
        newWeights[1] = 1e18 - newWeights[0];

        int256 epsilonMax = 0.1e18;
        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            absoluteWeightGuardRail
        );

        assertEq(res[0], 0.6e18);
        assertEq(res[1], 0.4e18);
    }

    // 2 tokens clamped
    function testFuzz_WeightGuards2TokensClamped(int256 newWeight) public view {
        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory newWeights = new int256[](2);
        newWeights[0] = bound(newWeight, 0.91e18, 0.9999999999999e18);
        newWeights[1] = 1e18 - newWeights[0];

        int256 epsilonMax = 1e18; //unlimted speed
        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            absoluteWeightGuardRail
        );

        assertEq(res[0], 0.9e18);
        assertEq(res[1], 0.1e18);
    }

    function testFuzz_WeightGuardsNTokensBelowEpsilonMax(
        uint256 tokens,
        int256 epsilonMax,
        int256 weightChange
    ) public view {
        uint256 boundTokenLength = bound(tokens, 2, 8);
        int256 boundEpsilonMax = bound(epsilonMax, 0.001e18, 0.1e18);
        int256 absoluteWeightGuardRail = 0.0000001e18;
        int256[] memory prevWeights = new int256[](boundTokenLength);
        for (uint256 i = 0; i < boundTokenLength; i++) {
            prevWeights[i] = 1e18 / int256(boundTokenLength);
        }

        int256[] memory newWeights = new int256[](boundTokenLength);
        int256 totalNewWeight = 0;

        for (uint256 i = 0; i < boundTokenLength; i++) {
            int256 minBound = prevWeights[i] - boundEpsilonMax;
            int256 maxBound = prevWeights[i] + boundEpsilonMax;

            // Ensure bounds stay within reasonable limits
            minBound = minBound < int256(0) ? int256(0) : minBound;

            newWeights[i] = bound(weightChange, minBound, maxBound); // Random value generation placeholder
            totalNewWeight += newWeights[i];
        }

        int256 adjustment = 1e18 - totalNewWeight;
        for (uint256 i = 0; i < boundTokenLength && adjustment != 0; i++) {
            // Calculate possible adjustment without violating bounds
            int256 minBound = prevWeights[i] - boundEpsilonMax;
            int256 maxBound = prevWeights[i] + boundEpsilonMax;

            int256 adjustedWeight = newWeights[i] + adjustment;

            if (adjustedWeight < minBound) {
                adjustment -= (minBound - newWeights[i]);
                newWeights[i] = minBound;
            } else if (adjustedWeight > maxBound) {
                adjustment -= (maxBound - newWeights[i]);
                newWeights[i] = maxBound;
            } else {
                newWeights[i] = adjustedWeight;
                adjustment = 0; // Fully adjusted
            }
        }

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            boundEpsilonMax,
            absoluteWeightGuardRail
        );

        for (uint256 i = 0; i < boundTokenLength; i++) {
            assertEq(res[i], newWeights[i]);
        }
    }

    function testWeightGuards2TokensBelowEpsilonMax() public view {
        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory newWeights = new int256[](2);
        newWeights[0] = 0.55e18;
        newWeights[1] = 0.45e18;

        int256 epsilonMax = 0.1e18;
        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            absoluteWeightGuardRail
        );

        assertEq(res[0], newWeights[0]);
        assertEq(res[1], newWeights[1]);
    }

    function testWeightGuards2TokensAboveEpsilonMax() public view {
        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory newWeights = new int256[](2);
        newWeights[0] = 0.7e18;
        newWeights[1] = 0.3e18;

        int256 epsilonMax = 0.1e18;
        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            absoluteWeightGuardRail
        );

        assertEq(res[0], 0.6e18);
        assertEq(res[1], 0.4e18);
    }

    function testWeightGuards2TokensClamped() public view {
        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory newWeights = new int256[](2);
        newWeights[0] = 0.95e18;
        newWeights[1] = 0.05e18;

        int256 epsilonMax = 0.1e18;
        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            absoluteWeightGuardRail
        );

        assertEq(res[0], 0.6e18);
        assertEq(res[1], 0.4e18);
    }

    function testWeightGuards3TokensBelowEpsilonMax() public view {
        int256[] memory prevWeights = new int256[](3);
        prevWeights[0] = 0.3e18;
        prevWeights[1] = 0.3e18;
        prevWeights[2] = 0.4e18;

        int256[] memory newWeights = new int256[](3);
        newWeights[0] = 0.35e18;
        newWeights[1] = 0.24e18;
        newWeights[2] = 0.41e18;

        int256 epsilonMax = 0.1e18;
        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            absoluteWeightGuardRail
        );

        assertEq(res[0], newWeights[0]);
        assertEq(res[1], newWeights[1]);
        assertEq(res[2], newWeights[2]);
    }

    function testWeightGuards3TokensAboveEpsilonMax() public view {
        int256[] memory prevWeights = new int256[](3);
        prevWeights[0] = 0.3e18;
        prevWeights[1] = 0.3e18;
        prevWeights[2] = 0.4e18;

        int256[] memory newWeights = new int256[](3);
        newWeights[0] = 0.5e18;
        newWeights[1] = 0.1e18;
        newWeights[2] = 0.4e18;

        int256 epsilonMax = 0.1e18;
        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            absoluteWeightGuardRail
        );

        assertEq(res[0], 0.4e18);
        assertEq(res[1], 0.2e18);
        assertEq(res[2], 0.4e18);
    }

    function testWeightGuards3TokensClamped() public view {
        int256[] memory prevWeights = new int256[](3);
        prevWeights[0] = 0.3e18;
        prevWeights[1] = 0.3e18;
        prevWeights[2] = 0.4e18;

        int256[] memory newWeights = new int256[](3);
        newWeights[0] = 0.9e18;
        newWeights[1] = 0.06e18;
        newWeights[2] = 0.04e18;

        int256 epsilonMax = 0.1e18;
        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            absoluteWeightGuardRail
        );

        assertEq(res[0], 0.4e18);
        assertEq(res[1], 0.26e18);
        assertEq(res[2], 0.34e18);
    }

    function testWeightGuards4TokensBelowEpsilonMax() public view {
        int256[] memory prevWeights = new int256[](4);
        prevWeights[0] = 0.3e18;
        prevWeights[1] = 0.3e18;
        prevWeights[2] = 0.2e18;
        prevWeights[3] = 0.2e18;

        int256[] memory newWeights = new int256[](4);
        newWeights[0] = 0.35e18;
        newWeights[1] = 0.25e18;
        newWeights[2] = 0.25e18;
        newWeights[3] = 0.15e18;

        int256 epsilonMax = 0.1e18;
        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            absoluteWeightGuardRail
        );

        assertEq(res[0], newWeights[0]);
        assertEq(res[1], newWeights[1]);
        assertEq(res[2], newWeights[2]);
        assertEq(res[3], newWeights[3]);
    }

    function testWeightGuards4TokensAboveEpsilonMax() public view {
        int256[] memory prevWeights = new int256[](4);
        prevWeights[0] = 0.3e18;
        prevWeights[1] = 0.3e18;
        prevWeights[2] = 0.2e18;
        prevWeights[3] = 0.2e18;

        int256[] memory newWeights = new int256[](4);
        newWeights[0] = 0.15e18;
        newWeights[1] = 0.45e18;
        newWeights[2] = 0.05e18;
        newWeights[3] = 0.35e18;

        int256 epsilonMax = 0.1e18;
        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            absoluteWeightGuardRail
        );

        assertEq(res[0], 0.2e18);
        assertEq(res[1], 0.38e18);
        assertEq(res[2], 0.136666666666666667e18);
        assertEq(res[3], 0.283333333333333333e18);
    }

    function testWeightGuards4TokensClamped() public view {
        int256[] memory prevWeights = new int256[](4);
        prevWeights[0] = 0.3e18;
        prevWeights[1] = 0.3e18;
        prevWeights[2] = 0.2e18;
        prevWeights[3] = 0.2e18;

        int256[] memory newWeights = new int256[](4);
        newWeights[0] = 0.97e18;
        newWeights[1] = 0.01e18;
        newWeights[2] = 0.01e18;
        newWeights[3] = 0.01e18;

        int256 epsilonMax = 0.1e18;
        int256 absoluteWeightGuardRail = 0.1e18;

        int256[] memory res = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            absoluteWeightGuardRail
        );

        assertEq(res[0], 0.4e18);
        assertEq(res[1], 0.25e18);
        assertEq(res[2], 0.175e18);
        assertEq(res[3], 0.175e18);
    }

    function test_EpsilonViolationExact() public view {
        // Exact values from second fuzzing failure
        int256[] memory prevWeights = new int256[](3);
        prevWeights[0] = 0.979999999999999947e18; // ~98%
        prevWeights[1] = 0.018530000200344578e18; // ~1.85%
        prevWeights[2] = 0.001469999799655475e18; // ~0.15%

        int256[] memory newWeights = new int256[](3);
        newWeights[0] = 0.949168597366431485e18; // Attempted ~3% decrease
        newWeights[1] = 0.049361402833913040e18; // Attempted large increase
        newWeights[2] = 0.001469999799655475e18; // No change

        int256 epsilonMax = 0.015415701316784231e18; // ~1.54%

        int256[] memory result = mockQuantAMMMathGuard.mockGuardQuantAMMWeights(
            newWeights,
            prevWeights,
            epsilonMax,
            0.01e18 // absoluteWeightGuardRail
        );

        // Log all weight changes for analysis
        for (uint i = 0; i < 3; i++) {
            int256 change = (result[i] - prevWeights[i]).abs();
            assertLe(change, epsilonMax, "Change exceeded epsilonMax");
        }
    }
}
