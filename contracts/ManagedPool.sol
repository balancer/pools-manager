// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { IAdaptiveWeightedPool } from "./interfaces/IAdaptiveWeightedPool.sol";
import { IManagedPool } from "./interfaces/IManagedPool.sol";

contract ManagedPool is IManagedPool {
    using FixedPoint for uint256;

    uint256 internal _lastUpdateIndex;

    mapping(address account => uint256) internal _balances;
    mapping(address => uint256) internal _lastAppliedIndex;
    mapping(uint256 => uint256) internal _coefficients;

    address internal _PoolController;
    address internal _bptToken;

    modifier onlyPoolController() {
        if (msg.sender != _PoolController) {
            revert SenderNotAllowed();
        }
        _;
    }

    function getBptToken() external view returns (address) {
        return _bptToken;
    }

    function name() external view returns (string memory) {
        return IERC20Metadata(_bptToken).name();
    }

    function symbol() external view returns (string memory) {
        return IERC20Metadata(_bptToken).symbol();
    }

    function decimals() external view returns (uint8) {
        return IERC20Metadata(_bptToken).decimals();
    }

    function totalSupply() public view returns (uint256) {
        return IERC20(_bptToken).totalSupply();
    }

    function balanceOf(address account) external view returns (uint256) {
        return _computeBptBalance(account);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        address owner = msg.sender;
        _updateBalance(owner);
        _updateBalance(to);

        _balances[owner] -= amount;
        _balances[to] += amount;

        emit Transfer(owner, to, amount);
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        revert("Not implemented");
    }

    function approve(address, uint256) external pure returns (bool) {
        revert("Not implemented"); //TOOD: update with balances
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert("Not implemented");
    }

    function migrateToNewManager(address newManager) external onlyPoolController {
        _PoolController = newManager;
    }

    function migratePool(address newBptToken, uint256 coefficient) external onlyPoolController {
        uint256 newIndex = _lastUpdateIndex + 1;
        _coefficients[newIndex] = coefficient;

        _bptToken = newBptToken;
        _lastUpdateIndex = newIndex;
    }

    function updateWeights(
        uint256[] memory newWeights,
        uint256 startChangingTime,
        uint256 endChangingTime
    ) external onlyPoolController {
        IAdaptiveWeightedPool(_bptToken).updateWeights(newWeights, startChangingTime, endChangingTime);
    }

    function _computeBptBalance(address account) internal view returns (uint256) {
        uint256 bptBalance = _balances[account];
        uint256 lastAccountAppliedIndex = _lastAppliedIndex[account];

        if (_lastUpdateIndex == lastAccountAppliedIndex) {
            return bptBalance;
        }

        uint256 currentBPTBalance = bptBalance;
        for (uint256 i = lastAccountAppliedIndex + 1; i <= _lastUpdateIndex; i++) {
            currentBPTBalance = currentBPTBalance.mulDown(_coefficients[i]);
        }

        return currentBPTBalance;
    }

    function _updateBalance(address account) internal returns (uint256) {
        uint256 balance = _computeBptBalance(account);
        _lastAppliedIndex[account] = _lastUpdateIndex;
        _balances[account] = balance;
        return balance;
    }

    // TODO: add ERC20Permit functions
}
