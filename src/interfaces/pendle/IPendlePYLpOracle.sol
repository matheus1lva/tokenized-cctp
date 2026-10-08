// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/// @notice Subset of Pendle's PendlePYLpOracle.
interface IPendlePYLpOracle {
    /// @return Rate of 1 PT to the SY accounting asset, 1e18 precision (TWAP).
    function getPtToAssetRate(
        address market,
        uint32 duration
    ) external view returns (uint256);

    function getOracleState(
        address market,
        uint32 duration
    )
        external
        view
        returns (
            bool increaseCardinalityRequired,
            uint16 cardinalityRequired,
            bool oldestObservationSatisfied
        );
}
