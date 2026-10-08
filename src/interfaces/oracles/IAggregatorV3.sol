// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/// @notice Minimal Chainlink AggregatorV3-style interface.
/// @dev RedStone push feeds on Base expose the same interface.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
