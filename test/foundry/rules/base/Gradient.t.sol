// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";
import { MockCalculationRule } from "../../../../contracts/test/MockCalculationRule.sol";
import { MockPool } from "../../../../contracts/test/MockPool.sol";
import { MockQuantAMMMathGuard } from "../../../../contracts/test/MockQuantAMMMathGuard.sol";

import { QuantAMMTestUtils } from "../../utils.t.sol";

contract QuantAMMGradientRuleTests is Test, QuantAMMTestUtils {
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

    // Utility to compare results with some tolerance
    function closeTo(int256 a, int256 b, int256 tolerance) internal pure {
        int256 delta = (a - b).abs();
        require(delta <= tolerance, "Values are not within tolerance");
    }

    function calculateGradient(
        int256[][] memory priceData,
        int256[][] memory priceDataBn,
        int256[][] memory movingAverages,
        int256[] memory initialGradients,
        int128[] memory lambdas
    ) internal returns (int256[][] memory) {
        mockCalculationRule.setInitialGradient(address(mockPool), initialGradients, movingAverages[0].length);

        int256[][] memory results = new int256[][](movingAverages.length);

        require(priceData.length == priceDataBn.length, "1Length mismatch");
        require(priceData.length == movingAverages.length, "2Length mismatch");
        require(movingAverages.length == results.length, "3Length mismatch");
        for (uint256 i = 0; i < movingAverages.length; ++i) {
            mockCalculationRule.externalCalculateQuantAMMGradient(
                priceDataBn[i],
                movingAverages[i],
                address(mockPool),
                lambdas,
                initialGradients.length
            );
            results[i] = mockCalculationRule.getResults();
        }

        return results;
    }

    // Function to test gradient calculation
    function testGradient(
        int256[][] memory priceData,
        int256[][] memory priceDataBn,
        int256[][] memory movingAverages,
        int256[] memory initialGradients,
        int128[] memory lambdas,
        int256[][] memory expectedRes
    ) internal {
        int256[][] memory results = calculateGradient(
            priceData,
            priceDataBn,
            movingAverages,
            initialGradients,
            lambdas
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
                assertEq(res[i][j], expectedRes[i][j]); // Compare for exact equality
            }
        }
    }

    function testInitialSettingOfGradients(uint256 unboundedNumberOfAssets) public {
        uint256 numberOfAssets = bound(unboundedNumberOfAssets, 2, 8);

        mockPool.setNumberOfAssets(numberOfAssets);

        int256[] memory initialGradients = new int256[](numberOfAssets);
        for (uint256 i = 0; i < numberOfAssets; i++) {
            initialGradients[i] = PRBMathSD59x18.fromInt(int256(i + 1));
        }

        mockCalculationRule.setInitialGradient(address(mockPool), initialGradients, numberOfAssets);

        int256[] memory intermediateResults = mockCalculationRule.getIntermediateGradientState(
            address(mockPool),
            numberOfAssets
        );
        int256[] memory results = mockCalculationRule.getInitialGradient(address(mockPool), numberOfAssets);

        for (uint256 i = 0; i < numberOfAssets; i++) {
            assertEq(results[i], initialGradients[i]);
            assertEq(intermediateResults[i], initialGradients[i]);
        }
    }

    function testBreakGlassSettingOfGradients(uint256 unboundedNumberOfAssets) public {
        uint256 numberOfAssets = bound(unboundedNumberOfAssets, 2, 8);

        mockPool.setNumberOfAssets(numberOfAssets);

        int256[] memory initialGradients = new int256[](numberOfAssets);
        for (uint256 i = 0; i < numberOfAssets; i++) {
            initialGradients[i] = PRBMathSD59x18.fromInt(int256(i + 1));
        }

        mockCalculationRule.setInitialGradient(address(mockPool), initialGradients, numberOfAssets);

        int256[] memory results = mockCalculationRule.getInitialGradient(address(mockPool), numberOfAssets);
        int256[] memory intermediateResults = mockCalculationRule.getIntermediateGradientState(
            address(mockPool),
            numberOfAssets
        );

        for (uint256 i = 0; i < numberOfAssets; i++) {
            assertEq(results[i], initialGradients[i]);
            assertEq(intermediateResults[i], initialGradients[i]);
        }

        for (uint256 i = 0; i < numberOfAssets; i++) {
            initialGradients[i] = PRBMathSD59x18.fromInt(int256(i + 3));
        }

        mockCalculationRule.setInitialGradient(address(mockPool), initialGradients, numberOfAssets);

        results = mockCalculationRule.getInitialGradient(address(mockPool), numberOfAssets);
        intermediateResults = mockCalculationRule.getIntermediateGradientState(address(mockPool), numberOfAssets);

        for (uint256 i = 0; i < numberOfAssets; i++) {
            assertEq(results[i], initialGradients[i]);
            assertEq(intermediateResults[i], initialGradients[i]);
        }
    }

    // Mock gradient calculation for different datasets
    // Scalar Lambda parameters
    // 2 tokens
    function testGradientCalculation2Tokens() public {
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
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1050), PRBMathSD59x18.fromInt(1050)],
                [PRBMathSD59x18.fromInt(1079) + 5e17, PRBMathSD59x18.fromInt(1078)],
                [PRBMathSD59x18.fromInt(1087) + 25e16, PRBMathSD59x18.fromInt(1088)]
            ]
        );

        int256[] memory gradients = new int256[](2);
        gradients[0] = PRBMathSD59x18.fromInt(0);
        gradients[1] = PRBMathSD59x18.fromInt(0);

        int128[] memory lambdas = new int128[](1);
        lambdas[0] = LAMBDA;

        int256[] memory lambdaNumbers = new int256[](1);
        lambdaNumbers[0] = 0.5e18;

        int256[][] memory expectedRes = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0)],
                [PRBMathSD59x18.fromInt(25), PRBMathSD59x18.fromInt(25)],
                [PRBMathSD59x18.fromInt(27) + 25e16, PRBMathSD59x18.fromInt(26) + 5e17],
                [PRBMathSD59x18.fromInt(17) + 5e17, PRBMathSD59x18.fromInt(18) + 25e16]
            ]
        );

        testGradient(priceData, priceDataBn, movingAverages, gradients, lambdas, expectedRes);
    }

    // 3 tokens
    function testGradientCalculation3Tokens() public {
        mockPool.setNumberOfAssets(3);

        int256[][] memory priceData = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
                [PRBMathSD59x18.fromInt(1105), PRBMathSD59x18.fromInt(1105), PRBMathSD59x18.fromInt(1105)],
                [PRBMathSD59x18.fromInt(1108), PRBMathSD59x18.fromInt(1108), PRBMathSD59x18.fromInt(1108)],
                [PRBMathSD59x18.fromInt(1111), PRBMathSD59x18.fromInt(1111), PRBMathSD59x18.fromInt(1111)]
            ]
        );

        int256[][] memory priceDataBn = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
                [PRBMathSD59x18.fromInt(1105), PRBMathSD59x18.fromInt(1105), PRBMathSD59x18.fromInt(1105)],
                [PRBMathSD59x18.fromInt(1108), PRBMathSD59x18.fromInt(1108), PRBMathSD59x18.fromInt(1108)],
                [PRBMathSD59x18.fromInt(1111), PRBMathSD59x18.fromInt(1111), PRBMathSD59x18.fromInt(1111)]
            ]
        );

        int256[][] memory movingAverages = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1050), PRBMathSD59x18.fromInt(1050), PRBMathSD59x18.fromInt(1050)],
                [
                    PRBMathSD59x18.fromInt(1077) + 5e17,
                    PRBMathSD59x18.fromInt(1077) + 5e17,
                    PRBMathSD59x18.fromInt(1077) + 5e17
                ],
                [
                    PRBMathSD59x18.fromInt(1092) + 75e16,
                    PRBMathSD59x18.fromInt(1092) + 75e16,
                    PRBMathSD59x18.fromInt(1092) + 75e16
                ],
                [
                    PRBMathSD59x18.fromInt(1101) + 875e15,
                    PRBMathSD59x18.fromInt(1101) + 875e15,
                    PRBMathSD59x18.fromInt(1101) + 875e15
                ]
            ]
        );

        int256[] memory gradients = new int256[](3);
        gradients[0] = PRBMathSD59x18.fromInt(0);
        gradients[1] = PRBMathSD59x18.fromInt(0);
        gradients[2] = PRBMathSD59x18.fromInt(0);

        int128[] memory lambdas = new int128[](1);
        lambdas[0] = LAMBDA;

        int256[] memory lambdaNumbers = new int256[](1);
        lambdaNumbers[0] = 0.5e18;

        int256[][] memory expectedRes = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0)],
                [PRBMathSD59x18.fromInt(25), PRBMathSD59x18.fromInt(25), PRBMathSD59x18.fromInt(25)],
                [
                    PRBMathSD59x18.fromInt(26) + 25e16,
                    PRBMathSD59x18.fromInt(26) + 25e16,
                    PRBMathSD59x18.fromInt(26) + 25e16
                ],
                [
                    PRBMathSD59x18.fromInt(20) + 75e16,
                    PRBMathSD59x18.fromInt(20) + 75e16,
                    PRBMathSD59x18.fromInt(20) + 75e16
                ],
                [
                    PRBMathSD59x18.fromInt(14) + 9375e14,
                    PRBMathSD59x18.fromInt(14) + 9375e14,
                    PRBMathSD59x18.fromInt(14) + 9375e14
                ]
            ]
        );

        testGradient(priceData, priceDataBn, movingAverages, gradients, lambdas, expectedRes);
    }

    // Vector Lambda parameters
    // 2 tokens
    function testGradientCalculation2TokensVectorLambda() public {
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
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1050), PRBMathSD59x18.fromInt(1050)],
                [PRBMathSD59x18.fromInt(1079) + 5e17, PRBMathSD59x18.fromInt(1078)],
                [PRBMathSD59x18.fromInt(1087) + 25e16, PRBMathSD59x18.fromInt(1088)]
            ]
        );

        int256[] memory gradients = new int256[](2);
        gradients[0] = PRBMathSD59x18.fromInt(0);
        gradients[1] = PRBMathSD59x18.fromInt(0);

        int128[] memory lambdas = new int128[](2);
        lambdas[0] = LAMBDA;
        lambdas[1] = LAMBDA;

        int256[] memory lambdaNumbers = new int256[](2);
        lambdaNumbers[0] = 0.5e18;
        lambdaNumbers[1] = 0.5e18;

        int256[2][4] memory expectedResArray = [
            [PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0)],
            [PRBMathSD59x18.fromInt(25), PRBMathSD59x18.fromInt(25)],
            [PRBMathSD59x18.fromInt(27) + 25e16, PRBMathSD59x18.fromInt(26) + 5e17],
            [PRBMathSD59x18.fromInt(17) + 5e17, PRBMathSD59x18.fromInt(18) + 25e16]
        ];

        int256[][] memory expectedRes = convert2DArrayToDynamic(expectedResArray);

        testGradient(priceData, priceDataBn, movingAverages, gradients, lambdas, expectedRes);
    }

    // 3 tokens
    function testGradientCalculation3TokensVectorLambda() public {
        mockPool.setNumberOfAssets(3);

        int256[3][5] memory priceDataArray = [
            [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
            [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
            [PRBMathSD59x18.fromInt(1105), PRBMathSD59x18.fromInt(1105), PRBMathSD59x18.fromInt(1105)],
            [PRBMathSD59x18.fromInt(1108), PRBMathSD59x18.fromInt(1108), PRBMathSD59x18.fromInt(1108)],
            [PRBMathSD59x18.fromInt(1111), PRBMathSD59x18.fromInt(1111), PRBMathSD59x18.fromInt(1111)]
        ];

        int256[][] memory priceData = convert2DArrayToDynamic(priceDataArray);
        int256[3][5] memory priceDataBnArray = [
            [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
            [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
            [PRBMathSD59x18.fromInt(1105), PRBMathSD59x18.fromInt(1105), PRBMathSD59x18.fromInt(1105)],
            [PRBMathSD59x18.fromInt(1108), PRBMathSD59x18.fromInt(1108), PRBMathSD59x18.fromInt(1108)],
            [PRBMathSD59x18.fromInt(1111), PRBMathSD59x18.fromInt(1111), PRBMathSD59x18.fromInt(1111)]
        ];

        int256[][] memory priceDataBn = convert2DArrayToDynamic(priceDataBnArray);
        int256[3][5] memory averages = [
            [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
            [PRBMathSD59x18.fromInt(1050), PRBMathSD59x18.fromInt(1050), PRBMathSD59x18.fromInt(1050)],
            [
                PRBMathSD59x18.fromInt(1077) + 5e17,
                PRBMathSD59x18.fromInt(1077) + 5e17,
                PRBMathSD59x18.fromInt(1077) + 5e17
            ],
            [
                PRBMathSD59x18.fromInt(1092) + 75e16,
                PRBMathSD59x18.fromInt(1092) + 75e16,
                PRBMathSD59x18.fromInt(1092) + 75e16
            ],
            [
                PRBMathSD59x18.fromInt(1101) + 875e15,
                PRBMathSD59x18.fromInt(1101) + 875e15,
                PRBMathSD59x18.fromInt(1101) + 875e15
            ]
        ];

        int256[][] memory movingAverages = convert2DArrayToDynamic(averages);

        int256[] memory gradients = new int256[](3);
        gradients[0] = PRBMathSD59x18.fromInt(0);
        gradients[1] = PRBMathSD59x18.fromInt(0);
        gradients[2] = PRBMathSD59x18.fromInt(0);

        int128[] memory lambdas = new int128[](3);
        lambdas[0] = LAMBDA;
        lambdas[1] = LAMBDA;
        lambdas[2] = int128(uint128(0.9e18));

        int256[] memory lambdaNumbers = new int256[](3);
        lambdaNumbers[0] = 0.5e18;
        lambdaNumbers[1] = 0.5e18;
        lambdaNumbers[2] = 0.9e18;

        int256[3][5] memory expectedResArray = [
            [PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0)],
            [PRBMathSD59x18.fromInt(25), PRBMathSD59x18.fromInt(25), int256(555555555555555500)],
            [PRBMathSD59x18.fromInt(26) + 25e16, PRBMathSD59x18.fromInt(26) + 25e16, int256(805555555555555475)],
            [PRBMathSD59x18.fromInt(20) + 75e16, PRBMathSD59x18.fromInt(20) + 75e16, int256(894444444444444355)],
            [PRBMathSD59x18.fromInt(14) + 9375e14, PRBMathSD59x18.fromInt(14) + 9375e14, int256(906388888888888798)]
        ];

        int256[][] memory expectedRes = convert2DArrayToDynamic(expectedResArray);

        testGradient(priceData, priceDataBn, movingAverages, gradients, lambdas, expectedRes);
    }

    // Fuzz test for gradient calculation with random number of assets
    function testFuzz_GradientCalculationAccess(
        uint256 unboundNumAssets,
        uint256 unboundNumberOfCalculations,
        bool scalarLambda
    ) public {
        uint256 numAssets = bound(unboundNumAssets, 2, 8);
        uint256 numberOfCalculations = bound(unboundNumberOfCalculations, 1, 20);

        mockPool.setNumberOfAssets(numAssets);

        int256[][] memory priceData = new int256[][](numberOfCalculations);
        int256[][] memory priceDataBn = new int256[][](numberOfCalculations);
        int256[][] memory movingAverages = new int256[][](numberOfCalculations);

        for (uint256 i = 0; i < numberOfCalculations; i++) {
            priceData[i] = new int256[](numAssets);
            priceDataBn[i] = new int256[](numAssets);
            movingAverages[i] = new int256[](numAssets);
            for (uint256 j = 0; j < numAssets; j++) {
                priceData[i][j] = PRBMathSD59x18.fromInt(1000 + int256(i * 100 + j * 10));
                priceDataBn[i][j] = PRBMathSD59x18.fromInt(1000 + int256(i * 100 + j * 10));
                movingAverages[i][j] = PRBMathSD59x18.fromInt(1000 + int256(i * 50 + j * 5));
            }
        }

        int256[] memory gradients = new int256[](numAssets);

        for (uint256 i = 0; i < numAssets; i++) {
            gradients[i] = PRBMathSD59x18.fromInt(0);
        }

        int128[] memory lambdas;
        if (scalarLambda) {
            lambdas = new int128[](1);
            lambdas[0] = LAMBDA;
        } else {
            lambdas = new int128[](numAssets);
            for (uint256 i = 0; i < numAssets; i++) {
                lambdas[i] = LAMBDA;
            }
        }

        calculateGradient(priceData, priceDataBn, movingAverages, gradients, lambdas);
    }
}
