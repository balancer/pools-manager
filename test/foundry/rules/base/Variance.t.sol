// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";

import { MockCalculationRule } from "../../../../contracts/test/MockCalculationRule.sol";
import { MockPool } from "../../../../contracts/test/MockPool.sol";
import { MockQuantAMMMathGuard } from "../../../../contracts/test/MockQuantAMMMathGuard.sol";

import { QuantAMMTestUtils } from "../../utils.t.sol";

contract QuantAMMVarianceRuleTest is Test, QuantAMMTestUtils {
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

    function calculateVariance(
        int256[][] memory priceData,
        int256[][] memory priceDataBn,
        int256[][] memory movingAverages,
        int256[] memory initialVariance,
        bool vectorLambda
    ) internal returns (int256[][] memory) {
        mockCalculationRule.setInitialVariance(address(mockPool), initialVariance, priceData[0].length);
        mockCalculationRule.setPrevMovingAverage(movingAverages[0]);

        int256[][] memory results = new int256[][](movingAverages.length);

        int128[] memory lambda;
        if (vectorLambda) {
            lambda = new int128[](priceData[0].length);
            for (uint i = 0; i < priceData[0].length; i++) {
                lambda[i] = int128(uint128(0.5e18));
            }
        } else {
            lambda = new int128[](1);
            lambda[0] = int128(uint128(0.5e18));
        }

        for (uint256 i = 0; i < movingAverages.length; ++i) {
            if (i > 0) {
                mockCalculationRule.setPrevMovingAverage(movingAverages[i - 1]);
            }
            mockCalculationRule.externalCalculateQuantAMMVariance(
                priceDataBn[i],
                movingAverages[i],
                address(mockPool),
                lambda,
                initialVariance.length
            );
            results[i] = mockCalculationRule.getResults();
        }
        return results;
    }

    // Function to test Variance calculation
    function testVariance(
        int256[][] memory priceData,
        int256[][] memory priceDataBn,
        int256[][] memory movingAverages,
        int256[] memory initialVariance,
        int256[][] memory expectedRes,
        bool vectorLambda
    ) internal {
        int256[][] memory results = calculateVariance(
            priceData,
            priceDataBn,
            movingAverages,
            initialVariance,
            vectorLambda
        );

        checkResult(priceData, results, expectedRes);
    }

    // Check results with tolerance
    function checkResult(
        int256[][] memory priceData,
        int256[][] memory res,
        int256[][] memory expectedRes
    ) internal pure {
        for (uint256 i = 0; i < priceData.length; i++) {
            for (uint256 j = 0; j < priceData[i].length; j++) {
                assertEq(expectedRes[i][j], res[i][j]); // Compare for exact equality
            }
        }
    }

    // Check results with tolerance
    function checkResult(int256[][] memory res, int256[][] memory expectedRes) internal pure {
        for (uint256 i = 0; i < res.length; i++) {
            assertEq(expectedRes[i], res[i]); // Compare for exact equality
        }
    }

    // Variance Matrix Calculation
    // 2 tokens
    function testVarianceCalculation2Tokens(bool vectorLambda) public {
        mockPool.setNumberOfAssets(2);
        int256[][] memory priceData = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
                [PRBMathSD59x18.fromInt(1109), PRBMathSD59x18.fromInt(1106)],
                [PRBMathSD59x18.fromInt(1095), PRBMathSD59x18.fromInt(1098)]
            ]
        );

        int256[][] memory priceDataBn = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
                [PRBMathSD59x18.fromInt(1109), PRBMathSD59x18.fromInt(1106)],
                [PRBMathSD59x18.fromInt(1095), PRBMathSD59x18.fromInt(1098)]
            ]
        );

        int256[][] memory movingAverages = convert2DArrayToDynamic(
            [
                [
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000)
                ],
                [
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000)
                ],
                [
                    PRBMathSD59x18.fromInt(1079) + 5e17,
                    PRBMathSD59x18.fromInt(1078),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050)
                ],
                [
                    PRBMathSD59x18.fromInt(1087) + 25e16,
                    PRBMathSD59x18.fromInt(1088),
                    PRBMathSD59x18.fromInt(1079) + 5e17,
                    PRBMathSD59x18.fromInt(1078)
                ]
            ]
        );

        int256[] memory initialVariance = new int256[](2);
        initialVariance[0] = 0;
        initialVariance[1] = 0;

        int256[][] memory expectedRes = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0)],
                [PRBMathSD59x18.fromInt(2500), PRBMathSD59x18.fromInt(2500)],
                [PRBMathSD59x18.fromInt(2120) + 0.25e18, PRBMathSD59x18.fromInt(2034)],
                [PRBMathSD59x18.fromInt(1120) + 0.1875e18, PRBMathSD59x18.fromInt(1117)]
            ]
        );

        testVariance(priceData, priceDataBn, movingAverages, initialVariance, expectedRes, vectorLambda);
    }

    // Variance Matrix Calculation
    // 2 tokens
    function testVarianceCalculation3Tokens(bool vectorLambda) public {
        mockPool.setNumberOfAssets(3);
        int256[][] memory priceData = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
                [PRBMathSD59x18.fromInt(1109), PRBMathSD59x18.fromInt(1106), PRBMathSD59x18.fromInt(1106)],
                [PRBMathSD59x18.fromInt(1095), PRBMathSD59x18.fromInt(1098), PRBMathSD59x18.fromInt(1098)]
            ]
        );

        int256[][] memory priceDataBn = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
                [PRBMathSD59x18.fromInt(1109), PRBMathSD59x18.fromInt(1106), PRBMathSD59x18.fromInt(1106)],
                [PRBMathSD59x18.fromInt(1095), PRBMathSD59x18.fromInt(1098), PRBMathSD59x18.fromInt(1098)]
            ]
        );

        int256[][] memory movingAverages = convert2DArrayToDynamic(
            [
                [
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000)
                ],
                [
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000)
                ],
                [
                    PRBMathSD59x18.fromInt(1079) + 5e17,
                    PRBMathSD59x18.fromInt(1078),
                    PRBMathSD59x18.fromInt(1078),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050)
                ],
                [
                    PRBMathSD59x18.fromInt(1087) + 25e16,
                    PRBMathSD59x18.fromInt(1088),
                    PRBMathSD59x18.fromInt(1088),
                    PRBMathSD59x18.fromInt(1079) + 5e17,
                    PRBMathSD59x18.fromInt(1078),
                    PRBMathSD59x18.fromInt(1078)
                ]
            ]
        );

        int256[] memory initialVariance = new int256[](3);
        initialVariance[0] = 0;
        initialVariance[1] = 0;
        initialVariance[2] = 0;

        int256[][] memory expectedRes = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0)],
                [PRBMathSD59x18.fromInt(2500), PRBMathSD59x18.fromInt(2500), PRBMathSD59x18.fromInt(2500)],
                [PRBMathSD59x18.fromInt(2120) + 0.25e18, PRBMathSD59x18.fromInt(2034), PRBMathSD59x18.fromInt(2034)],
                [PRBMathSD59x18.fromInt(1120) + 0.1875e18, PRBMathSD59x18.fromInt(1117), PRBMathSD59x18.fromInt(1117)]
            ]
        );

        testVariance(priceData, priceDataBn, movingAverages, initialVariance, expectedRes, vectorLambda);
    }

    function testFuzz_VarianceSetIntermediateVariance(uint unboundNumAssets) public {
        uint numAssets = bound(unboundNumAssets, 2, 8);
        mockPool.setNumberOfAssets(numAssets);
        int256[] memory initialVariance = new int256[](numAssets);
        for (uint i = 0; i < numAssets; i++) {
            initialVariance[i] = PRBMathSD59x18.fromInt(int256(i));
        }

        mockCalculationRule.setInitialVariance(address(mockPool), initialVariance, numAssets);

        int256[] memory savedInitialVariance = mockCalculationRule.getIntermediateVariance(
            address(mockPool),
            numAssets
        );

        checkResult(initialVariance, savedInitialVariance);

        // Additional check using getIntermediateVarianceState
        int256[] memory stateVariance = mockCalculationRule.getIntermediateVarianceState(address(mockPool), numAssets);
        checkResult(initialVariance, stateVariance);

        for (uint i = 0; i < numAssets; i++) {
            initialVariance[i] = PRBMathSD59x18.fromInt(int256(i)) + PRBMathSD59x18.fromInt(int256(1));
        }

        //break glass post initialisation
        mockCalculationRule.setInitialVariance(address(mockPool), initialVariance, numAssets);

        savedInitialVariance = mockCalculationRule.getIntermediateVariance(address(mockPool), numAssets);

        checkResult(initialVariance, savedInitialVariance);

        // Additional check using getIntermediateVarianceState
        stateVariance = mockCalculationRule.getIntermediateVarianceState(address(mockPool), numAssets);
        checkResult(initialVariance, stateVariance);
    }

    // Fuzz test for Variance calculation with varying number of assets
    function testVarianceStorageAccessFuzz(
        uint256 unboundNumAssets,
        uint256 unboundNumCalcs,
        bool vectorLambda
    ) public {
        uint256 numAssets = bound(unboundNumAssets, 2, 8);
        uint256 boundNumCalcs = bound(unboundNumCalcs, 1, 20);
        mockPool.setNumberOfAssets(numAssets);

        int256[][] memory priceData = new int256[][](boundNumCalcs);
        int256[][] memory priceDataBn = new int256[][](boundNumCalcs);
        int256[][] memory movingAverages = new int256[][](boundNumCalcs);
        int256[] memory initialVariance = new int256[](numAssets);

        for (uint256 i = 0; i < boundNumCalcs; i++) {
            priceData[i] = new int256[](numAssets);
            priceDataBn[i] = new int256[](numAssets);
            movingAverages[i] = new int256[](numAssets * 2);

            for (uint256 j = 0; j < numAssets; j++) {
                priceData[i][j] = PRBMathSD59x18.fromInt(int256(1000 + i * 100 + j * 10));
                priceDataBn[i][j] = PRBMathSD59x18.fromInt(int256(1000 + i * 100 + j * 10));
                movingAverages[i][j] = PRBMathSD59x18.fromInt(int256(1000 + i * 50 + j * 5));
                movingAverages[i][j + numAssets] = PRBMathSD59x18.fromInt(int256(1000 + i * 50 + j * 5));
            }
        }

        for (uint256 i = 0; i < numAssets; i++) {
            initialVariance[i] = 0;
        }

        calculateVariance(priceData, priceDataBn, movingAverages, initialVariance, vectorLambda);
    }
}
