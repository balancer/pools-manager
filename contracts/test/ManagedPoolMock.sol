// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { ManagedPool } from "../ManagedPool.sol";
import { PoolController } from "../PoolController.sol";

contract ManagedPoolMock is ManagedPool {
    constructor(PoolController poolController) ManagedPool(poolController) {}

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }
}
