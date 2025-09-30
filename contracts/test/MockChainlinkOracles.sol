// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "../OracleWrapper.sol";

contract MockChainlinkOracle is OracleWrapper {
    int216 private fixedReply;
    uint private immutable delay;
    uint40 public oracleTimestamp;
    bool throwOnUpdate;

    constructor(int216 _fixedReply, uint _delay) {
        fixedReply = _fixedReply;
        delay = _delay;
        oracleTimestamp = uint40(block.timestamp);
        throwOnUpdate = false;
    }

    function setThrowOnUpdate(bool _throwOnUpdate) public {
        throwOnUpdate = _throwOnUpdate;
    }

    function updateData(int216 _fixedReply, uint40 _timestamp) public {
        fixedReply = _fixedReply;
        oracleTimestamp = _timestamp;
    }

    function _getData() internal view override returns (int216 data, uint40 timestamp) {
        if (throwOnUpdate) {
            revert("MockChainlinkOracle: throwOnUpdate");
        }
        data = fixedReply;
        timestamp = uint40(block.timestamp - delay);
    }
}
