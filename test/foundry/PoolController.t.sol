// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.24;

import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { TokenConfig, PoolRoleAccounts, TokenType } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ERC20TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { AdaptiveWeightedPoolFactory } from "../../contracts/AdaptiveWeightedPoolFactory.sol";
import { AdaptiveWeightedPool } from "../../contracts/AdaptiveWeightedPool.sol";
import { ManagedPoolMock } from "../../contracts/test/ManagedPoolMock.sol";
import { PoolController } from "../../contracts/PoolController.sol";

contract PoolControllerTest is BaseVaultTest {
    AdaptiveWeightedPoolFactory adaptivePoolFactory;
    AdaptiveWeightedPool adaptiveWeightedPool;
    ManagedPoolMock managedPool;
    PoolController poolController;

    uint256 tokenCount = 4;
    uint256[] initialWeights;
    IERC20[] poolTokens;

    function setUp() public override {
        BaseVaultTest.setUp();

        adaptivePoolFactory = new AdaptiveWeightedPoolFactory(vault, 365 days, "Factory v1", "Pool v1");

        IERC20[] memory tokens = new IERC20[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            tokens[i] = IERC20(address(new ERC20TestToken("Test Token", "TTK", 18)));
        }
        tokens = InputHelpers.sortTokens(tokens);

        TokenConfig[] memory tokensConfig = new TokenConfig[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            tokensConfig[i] = TokenConfig({
                token: tokens[i],
                tokenType: TokenType.STANDARD,
                rateProvider: IRateProvider(address(0)),
                paysYieldFees: false
            });
        }
        poolTokens = tokens;

        uint256[] memory weights = new uint256[](tokenCount);
        uint256[] memory virtualBalances = new uint256[](tokenCount);
        weights[0] = 0.25e18;
        weights[1] = 0.25e18;
        weights[2] = 0.25e18;
        weights[3] = 0.25e18;

        for (uint256 i = 0; i < tokenCount; i++) {
            initialWeights.push(weights[i]);
        }

        PoolRoleAccounts memory roleAccounts = PoolRoleAccounts({
            pauseManager: address(0),
            swapFeeManager: address(0),
            poolCreator: address(0)
        });

        poolController = new PoolController(alice, vault, router, adaptivePoolFactory);
        managedPool = new ManagedPoolMock(poolController);

        vm.prank(alice);
        poolController.initialize(managedPool);

        adaptiveWeightedPool = AdaptiveWeightedPool(
            adaptivePoolFactory.create(
                AdaptiveWeightedPoolFactory.CreationParams({
                    name: "Adaptive Weighted Pool",
                    symbol: "AWP",
                    tokens: tokensConfig,
                    normalizedWeights: weights,
                    virtualBalances: virtualBalances,
                    roleAccounts: roleAccounts,
                    swapFeePercentage: DEFAULT_SWAP_FEE_PERCENTAGE,
                    poolHooksContract: address(0),
                    enableDonation: false,
                    disableUnbalancedLiquidity: false,
                    managedPool: address(managedPool),
                    salt: bytes32(0)
                })
            )
        );

        vm.prank(address(poolController));
        managedPool.initialize(address(adaptiveWeightedPool));

        uint256[] memory exactAmountsIn = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            exactAmountsIn[i] = 1000e18;
            ERC20TestToken(address(poolTokens[i])).mint(address(poolController), exactAmountsIn[i]);

            vm.startPrank(address(poolController));
            ERC20TestToken(address(poolTokens[i])).approve(address(permit2), type(uint256).max);
            permit2.approve(address(poolTokens[i]), address(router), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }

        vm.prank(address(poolController));
        uint256 bptOut = router.initialize(
            address(adaptiveWeightedPool),
            poolTokens,
            exactAmountsIn,
            0,
            false,
            bytes("")
        );
        managedPool.mint(address(poolController), bptOut);
    }

    function testRemoveToken() public {
        uint256 startChangingTime = block.timestamp + 1 days;
        uint256 endChangingTime = block.timestamp + 2 days;

        uint256[] memory newWeights = new uint256[](tokenCount);
        newWeights[0] = 0;
        newWeights[1] = 333333333333333334;
        newWeights[2] = 333333333333333333;
        newWeights[3] = 333333333333333333;

        vm.prank(alice);
        poolController.removeToken(poolTokens[0], startChangingTime, endChangingTime);

        {
            vm.warp(block.timestamp + 30 minutes);
            (
                uint256 _startChangingTime,
                uint256 _endChangingTime,
                uint256[] memory _initialWeights,
                uint256[] memory _targetWeights
            ) = adaptiveWeightedPool.getChangingWeightsInfo();
            assertEq(_startChangingTime, startChangingTime, "startChangingTime mismatch (after 30 mins)");
            assertEq(_endChangingTime, endChangingTime, "endChangingTime mismatch (after 30 mins)");
            assertEq(_initialWeights, initialWeights, "initialWeights mismatch (after 30 mins)");
            assertEq(_targetWeights, newWeights, "targetWeights mismatch (after 30 mins)");
        }

        uint256 halfTime = startChangingTime + (endChangingTime - startChangingTime) / 2;
        vm.warp(halfTime);
        {
            (
                uint256 _startChangingTime,
                uint256 _endChangingTime,
                uint256[] memory _initialWeights,
                uint256[] memory _targetWeights
            ) = adaptiveWeightedPool.getChangingWeightsInfo();
            assertEq(_startChangingTime, startChangingTime, "startChangingTime mismatch (after mid time)");
            assertEq(_endChangingTime, endChangingTime, "endChangingTime mismatch (after mid time)");
            assertEq(_initialWeights, initialWeights, "initialWeights mismatch (after mid time)");
            assertEq(_targetWeights, newWeights, "targetWeights mismatch (after mid time)");
        }

        uint256[] memory currentWeights = adaptiveWeightedPool.getNormalizedWeights();
        for (uint256 i = 0; i < tokenCount; i++) {
            int256 differencePerTime = ((int256(newWeights[i]) - int256(initialWeights[i])) *
                int256(block.timestamp - startChangingTime)) / int256(endChangingTime - startChangingTime);

            assertEq(
                currentWeights[i],
                uint256(int256(initialWeights[i]) + differencePerTime),
                "current weight mismatch (after mid time)"
            );
        }

        vm.warp(endChangingTime + 1);
        {
            (
                uint256 _startChangingTime,
                uint256 _endChangingTime,
                uint256[] memory _initialWeights,
                uint256[] memory _targetWeights
            ) = adaptiveWeightedPool.getChangingWeightsInfo();
            assertEq(_startChangingTime, startChangingTime, "startChangingTime mismatch (after endTime)");
            assertEq(_endChangingTime, endChangingTime, "endChangingTime mismatch (after endTime)");
            assertEq(_initialWeights, initialWeights, "initialWeights mismatch (after endTime)");
            assertEq(_targetWeights, newWeights, "targetWeights mismatch (after endTime)");
        }

        currentWeights = adaptiveWeightedPool.getNormalizedWeights();
        for (uint256 i = 0; i < tokenCount; i++) {
            assertEq(currentWeights[i], newWeights[i], "current weight mismatch (after endTime)");
        }
    }

    function testAddTokenIfTokenExists() public {
        uint256 startChangingTime = block.timestamp + 1 days;
        uint256 endChangingTime = startChangingTime + 3 days;

        vm.prank(alice);
        poolController.removeToken(poolTokens[0], startChangingTime, endChangingTime);

        vm.warp(endChangingTime + 1);

        TokenConfig memory tokenConfig = TokenConfig({
            token: poolTokens[0],
            tokenType: TokenType.STANDARD,
            rateProvider: IRateProvider(address(0)),
            paysYieldFees: false
        });
        uint256 weight = 0.25e18;
        uint256 initialVirtualBalance = 1000e18;

        vm.prank(alice);
        poolController.addToken(tokenConfig, weight, initialVirtualBalance);

        uint256[] memory expectedVirtualBalances = new uint256[](tokenCount);
        expectedVirtualBalances[0] = initialVirtualBalance;
        uint256[] memory expectedWeights = new uint256[](tokenCount);
        expectedWeights[0] = 250000000000000002;
        expectedWeights[1] = 250000000000000000;
        expectedWeights[2] = 249999999999999999;
        expectedWeights[3] = 249999999999999999;

        uint256[] memory currentWeights = adaptiveWeightedPool.getNormalizedWeights();
        uint256[] memory virtualBalances = adaptiveWeightedPool.getVirtualBalances();

        for (uint256 i = 0; i < tokenCount; i++) {
            assertEq(currentWeights[i], expectedWeights[i], "weight mismatch");
            assertEq(virtualBalances[i], expectedVirtualBalances[i], "virtual balance mismatch");
        }
    }

    function testAddTokenA() public {
        ERC20TestToken newToken = new ERC20TestToken("New Test Token", "NTK", 18);

        TokenConfig memory tokenConfig = TokenConfig({
            token: IERC20(address(newToken)),
            tokenType: TokenType.STANDARD,
            rateProvider: IRateProvider(address(0)),
            paysYieldFees: false
        });
        uint256 weight = 0.25e18;
        uint256 initialVirtualBalance = 1000e18;

        uint256 newTokensCount = tokenCount + 1;
        IERC20[] memory newTokens = new IERC20[](newTokensCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            newTokens[i] = poolTokens[i];
        }
        newTokens[tokenCount] = newToken;
        newTokens = InputHelpers.sortTokens(newTokens);

        vm.prank(alice);
        poolController.addToken(tokenConfig, weight, initialVirtualBalance);

        uint256[] memory expectedVirtualBalances = new uint256[](newTokensCount);
        expectedVirtualBalances[0] = initialVirtualBalance;

        uint256[] memory expectedWeights = new uint256[](newTokensCount);
        expectedWeights[0] = 250000000000000002;
        expectedWeights[1] = 250000000000000000;
        expectedWeights[2] = 249999999999999999;
        expectedWeights[3] = 249999999999999999;
        expectedWeights[4] = 249999999999999999;

        uint256[] memory currentWeights = adaptiveWeightedPool.getNormalizedWeights();
        uint256[] memory virtualBalances = adaptiveWeightedPool.getVirtualBalances();

        for (uint256 i = 0; i < newTokensCount; i++) {
            assertEq(currentWeights[i], expectedWeights[i], "weight mismatch");
            assertEq(virtualBalances[i], expectedVirtualBalances[i], "virtual balance mismatch");
        }
    }
}
