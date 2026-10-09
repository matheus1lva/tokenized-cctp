// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IAggregatorV3} from "../interfaces/oracles/IAggregatorV3.sol";

/// @notice Helpers to read AggregatorV3-style feeds with staleness checks.
library OracleLib {
    /// @notice Read a positive, non-stale price.
    /// @dev Reverts with "BadPrice" or "StalePrice".
    function readPrice(
        IAggregatorV3 _oracle,
        uint256 _maxStaleness
    ) internal view returns (uint256 price, uint256 updatedAt) {
        int256 answer;
        (, answer, , updatedAt, ) = _oracle.latestRoundData();
        require(answer > 0, "BadPrice");
        require(isFresh(updatedAt, _maxStaleness), "StalePrice");
        price = uint256(answer);
    }

    /// @notice Same as readPrice but never reverts.
    function tryReadPrice(
        IAggregatorV3 _oracle,
        uint256 _maxStaleness
    ) internal view returns (bool ok, uint256 price, uint256 updatedAt) {
        try _oracle.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256 _updatedAt,
            uint80
        ) {
            if (answer > 0 && isFresh(_updatedAt, _maxStaleness)) {
                return (true, uint256(answer), _updatedAt);
            }
        } catch {}
    }

    function isFresh(
        uint256 _updatedAt,
        uint256 _maxStaleness
    ) internal view returns (bool) {
        if (_updatedAt == 0) return false;
        // Some push oracles can stamp a timestamp equal to (or a few
        // seconds ahead of) the current block. Treat that as fresh.
        if (_updatedAt >= block.timestamp) return true;
        return block.timestamp - _updatedAt <= _maxStaleness;
    }
}
