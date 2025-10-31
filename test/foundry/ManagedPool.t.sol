// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.24;

import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ManagedPoolMock } from "../../contracts/test/ManagedPoolMock.sol";
import { PoolController } from "../../contracts/PoolController.sol";

contract ManagedPoolTest is BaseVaultTest {
    using FixedPoint for uint256;

    address internal fakePoolController = makeAddr("fakePoolController");
    ManagedPoolMock internal managedPool;

    function testCoefficients() public {
        uint256 coefficient = 2.05e18;
        managedPool = new ManagedPoolMock(PoolController(fakePoolController));

        uint256 aliceBalance = 3.3e18;
        uint256 bobBalance = 5.5e18;
        managedPool.mint(alice, aliceBalance);
        managedPool.mint(bob, bobBalance);

        vm.prank(fakePoolController);
        managedPool.migratePool(makeAddr("newFakeBptToken"), coefficient);

        assertEq(managedPool.balanceOf(alice), aliceBalance.mulDown(coefficient));
        assertEq(managedPool.balanceOf(bob), bobBalance.mulDown(coefficient));
    }
}
